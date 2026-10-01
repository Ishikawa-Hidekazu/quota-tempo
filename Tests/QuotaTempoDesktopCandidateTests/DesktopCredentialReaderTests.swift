import CommonCrypto
import Foundation
import SQLite3
import Security
import Testing

@testable import QuotaTempoDesktopCandidate

private let readerNow = Date(timeIntervalSince1970: 1_900_000_000)
private let readerAccount = "11111111-1111-4111-8111-111111111111"
private let readerOrganization = "22222222-2222-4222-8222-222222222222"

private final class ReaderFixture {
  let directory: URL
  let key: Data

  init() throws {
    directory = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("QuotaTempo-Synthetic-\(UUID().uuidString)")
    key = try DesktopSafeStorage.deriveKey(password: Data("synthetic-only-password".utf8))
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var db: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK else {
      throw DesktopCredentialError.invalidStore
    }
    defer { sqlite3_close(db) }
    let sql = """
      CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, value TEXT, encrypted_value BLOB,
        expires_utc INTEGER, has_expires INTEGER, is_persistent INTEGER);
      INSERT INTO cookies VALUES ('.claude.ai', 'lastActiveOrg', '/', '\(readerOrganization)', X'',
        15000000000000000, 1, 1);
      """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw DesktopCredentialError.invalidStore
    }
    try write()
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func write(
    token: String = "synthetic-reader-token", account: String = readerAccount, nullV2: Bool = false,
    extra: Bool = false
  ) throws {
    let cache = [
      "acct:\(account)|9d1c250a-e61b-44d9-88ed-5944d1962f5e:\(readerOrganization):https://api.anthropic.com:user:profile user:inference":
        ["token": token, "expiresAt": 1_900_003_600_000] as [String: Any]
    ]
    let data = try JSONSerialization.data(withJSONObject: cache)
    let encrypted = try encrypt(data).base64EncodedString()
    var config: [String: Any] = [
      "lastKnownAccountUuid": account, "oauth:tokenCacheV2": nullV2 ? NSNull() : encrypted,
      "oauth:tokenCache": encrypted,
    ]
    if extra { config["nonSecretPreference"] = true }
    try JSONSerialization.data(withJSONObject: config, options: .sortedKeys).write(
      to: directory.appendingPathComponent("config.json"), options: .atomic)
  }

  private func encrypt(_ input: Data) throws -> Data {
    let iv = Data(repeating: 32, count: 16)
    var output = Data(count: input.count + 16)
    let capacity = output.count
    var length = 0
    let status = output.withUnsafeMutableBytes { output in
      input.withUnsafeBytes { input in
        key.withUnsafeBytes { key in
          iv.withUnsafeBytes { iv in
            CCCrypt(
              CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding),
              key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
              output.baseAddress, capacity, &length)
          }
        }
      }
    }
    guard status == kCCSuccess else { throw DesktopCredentialError.invalidStore }
    output.count = length
    return Data("v10".utf8) + output
  }

  func reader() -> DesktopCredentialReader {
    let key = key
    return DesktopCredentialReader(directory: directory, keyReader: { key })
  }
}

private final class ReaderCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class ReaderClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = readerNow

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    instant = instant.addingTimeInterval(interval)
  }
}

private final class SyntheticReaderKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var state = DesktopKeychainReadGate.State.unlocked
  private var denied = false
  private var queryStatus = errSecSuccess
  private var stateAfterQuery: DesktopKeychainReadGate.State?
  private var queries = 0

  func set(
    _ state: DesktopKeychainReadGate.State, denied: Bool = false,
    queryStatus: OSStatus = errSecSuccess, stateAfterQuery: DesktopKeychainReadGate.State? = nil
  ) {
    lock.lock()
    defer { lock.unlock() }
    self.state = state
    self.denied = denied
    self.queryStatus = queryStatus
    self.stateAfterQuery = stateAfterQuery
  }

  func read(_ key: Data) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    return try DesktopKeychainReadGate.read(
      findTarget: { "synthetic-item" }, state: { _ in self.state },
      query: { _ in
        self.queries += 1
        if let stateAfterQuery = self.stateAfterQuery { self.state = stateAfterQuery }
        if self.denied { throw DesktopCredentialError.permissionRequired }
        return (self.queryStatus, key)
      })
  }

  var queryCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return queries
  }
}

@Suite("Desktop protected reader synthetic integration")
struct DesktopCredentialReaderTests {
  @Test func temporaryKeychainLockRecoversWithoutReapprovalOrGenerationChange() async throws {
    let fixture = try ReaderFixture()
    let key = fixture.key
    let keychain = SyntheticReaderKeychain()
    let reader = DesktopCredentialReader(
      directory: fixture.directory, keyReader: { try keychain.read(key) })
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    var first: DesktopCredentialLease? = try await reader.load(now: readerNow)
    let context = try #require(first).context
    weak var released = first
    first = nil
    keychain.set(.locked)
    for _ in 0..<3 {
      do {
        _ = try await reader.load(now: readerNow)
        Issue.record("Locked keychain unexpectedly read")
      } catch { #expect(error as? DesktopCredentialError == .keychainLocked) }
    }
    #expect(keychain.queryCount == 1)
    #expect(released == nil)
    #expect(await reader.lastFailureStage == .keychain)
    keychain.set(.unlocked)
    let restored = try await reader.load(now: readerNow)
    #expect(restored.context == context)
    #expect(keychain.queryCount == 2)
    #expect(await reader.lastFailureStage == nil)
  }

  @Test func queryTimeKeychainLockRecoversWithoutReapprovalOrGenerationChange() async throws {
    let fixture = try ReaderFixture()
    let key = fixture.key
    let keychain = SyntheticReaderKeychain()
    let reader = DesktopCredentialReader(
      directory: fixture.directory, keyReader: { try keychain.read(key) })
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    var first: DesktopCredentialLease? = try await reader.load(now: readerNow)
    let context = try #require(first).context
    weak var released = first
    first = nil
    keychain.set(.unlocked, queryStatus: errSecInteractionNotAllowed, stateAfterQuery: .locked)
    for _ in 0..<3 {
      do {
        _ = try await reader.load(now: readerNow)
        Issue.record("Query-time keychain lock unexpectedly read")
      } catch { #expect(error as? DesktopCredentialError == .keychainLocked) }
    }
    #expect(keychain.queryCount == 2)
    #expect(released == nil)
    #expect(await reader.lastFailureStage == .keychain)
    keychain.set(.unlocked)
    let restored = try await reader.load(now: readerNow)
    #expect(restored.context == context)
    #expect(keychain.queryCount == 3)
    #expect(await reader.lastFailureStage == nil)
  }

  @Test(arguments: [401, 403], [false, true])
  func unlockCannotClearProviderAuthenticationRefusal(status: Int, racesWithQuery: Bool)
    async throws
  {
    let fixture = try ReaderFixture()
    let key = fixture.key
    let keychain = SyntheticReaderKeychain()
    let reader = DesktopCredentialReader(
      directory: fixture.directory, keyReader: { try keychain.read(key) })
    let clock = ReaderClock()
    let calls = ReaderCounter()
    let service = DesktopUsageCandidateService(
      reader: reader, clock: { clock.now() },
      fetch: { _, _ in
        calls.increment()
        return .response(
          status: status, profileOwner: nil, serverDate: nil, cacheAge: nil, retryAfter: nil,
          body: Data())
      })
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    #expect(await service.refresh().observation == nil)
    if racesWithQuery {
      keychain.set(.unlocked, queryStatus: errSecInteractionNotAllowed, stateAfterQuery: .locked)
    } else {
      keychain.set(.locked)
    }
    clock.advance(by: 61)
    let locked = await service.refresh()
    #expect(locked.credentialError == .keychainLocked)
    #expect(locked.observation == nil)
    #expect(calls.count == 1)
    keychain.set(.unlocked)
    clock.advance(by: 61)
    let restored = await service.refresh()
    #expect(restored.credentialError == nil)
    #expect(restored.observation == nil)
    #expect(restored.state == (status == 401 ? .waitingForDesktopRenewal : .accessDenied))
    #expect(calls.count == 1)
  }

  @Test func actualKeychainDenialIsNotRetriedAfterLockAndUnlock() async throws {
    let fixture = try ReaderFixture()
    let key = fixture.key
    let keychain = SyntheticReaderKeychain()
    keychain.set(.unlocked, denied: true)
    let reader = DesktopCredentialReader(
      directory: fixture.directory, keyReader: { try keychain.read(key) })
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    _ = try? await reader.load(now: readerNow)
    for state: DesktopKeychainReadGate.State in [.locked, .unknown, .unlocked] {
      keychain.set(state)
      do {
        _ = try await reader.load(now: readerNow)
        Issue.record("Refused access unexpectedly retried")
      } catch { #expect(error as? DesktopCredentialError == .permissionRequired) }
    }
    #expect(keychain.queryCount == 1)
  }

  @Test(arguments: [errSecAuthFailed, errSecUserCanceled])
  func queryTimeRefusalStaysLatchedEvenWithConcurrentLock(status: OSStatus) async throws {
    let fixture = try ReaderFixture()
    let key = fixture.key
    let keychain = SyntheticReaderKeychain()
    keychain.set(.unlocked, queryStatus: status, stateAfterQuery: .locked)
    let reader = DesktopCredentialReader(
      directory: fixture.directory, keyReader: { try keychain.read(key) })
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    do {
      _ = try await reader.load(now: readerNow)
      Issue.record("Query-time refusal unexpectedly read")
    } catch { #expect(error as? DesktopCredentialError == .permissionRequired) }
    #expect(await reader.lastFailureStage == .keychain)
    for state: DesktopKeychainReadGate.State in [.locked, .unknown, .unlocked] {
      keychain.set(state)
      do {
        _ = try await reader.load(now: readerNow)
        Issue.record("Query-time refusal unexpectedly retried")
      } catch { #expect(error as? DesktopCredentialError == .permissionRequired) }
    }
    #expect(keychain.queryCount == 1)
  }

  @Test func ambiguousInteractionFailureStaysLatchedWithoutTargetLockEvidence() async throws {
    for observedState: DesktopKeychainReadGate.State in [.unknown, .unlocked] {
      let fixture = try ReaderFixture()
      let key = fixture.key
      let keychain = SyntheticReaderKeychain()
      keychain.set(
        .unlocked, queryStatus: errSecInteractionNotAllowed, stateAfterQuery: observedState)
      let reader = DesktopCredentialReader(
        directory: fixture.directory, keyReader: { try keychain.read(key) })
      await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
      do {
        _ = try await reader.load(now: readerNow)
        Issue.record("Ambiguous interaction failure unexpectedly read")
      } catch { #expect(error as? DesktopCredentialError == .permissionRequired) }
      keychain.set(.unlocked)
      do {
        _ = try await reader.load(now: readerNow)
        Issue.record("Ambiguous refusal unexpectedly retried")
      } catch { #expect(error as? DesktopCredentialError == .permissionRequired) }
      #expect(keychain.queryCount == 1)
    }
  }

  @Test(arguments: [401, 403])
  func approvalChangesDoNotRenewRefusedCredentials(status: Int) async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    let clock = ReaderClock()
    let count = ReaderCounter()
    let approval = DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true)
    let service = DesktopUsageCandidateService(
      reader: reader, clock: { clock.now() },
      fetch: { request, _ in
        count.increment()
        if count.count == 1 {
          return .response(
            status: status, profileOwner: nil, serverDate: nil, cacheAge: nil, retryAfter: nil,
            body: Data())
        }
        let reset = ISO8601DateFormatter().string(
          from: request.startedAt.addingTimeInterval(604_700))
        return .response(
          status: 200, profileOwner: request.context.owner, serverDate: request.startedAt,
          cacheAge: 0, retryAfter: nil,
          body: Data("{\"seven_day\":{\"utilization\":25,\"resets_at\":\"\(reset)\"}}".utf8))
      })
    await service.setApproval(approval)
    let rejected = await service.refresh()
    let expected: DesktopUsageState = status == 401 ? .waitingForDesktopRenewal : .accessDenied
    #expect(rejected.state == expected)
    #expect(rejected.observation == nil)
    let originalGeneration = try await reader.load(now: clock.now()).context.generation

    for withdraw in [false, true] {
      if withdraw {
        await service.setApproval(DesktopAccessApproval())
        let denied = await service.refresh()
        #expect(denied.credentialError == .consentRequired)
        #expect(denied.observation == nil)
        #expect(count.count == 1)
      }
      await service.setApproval(approval)
      clock.advance(by: 61)
      let repeated = await service.refresh()
      #expect(repeated.state == expected)
      #expect(repeated.observation == nil)
      #expect(count.count == 1)
      #expect(try await reader.load(now: clock.now()).context.generation == originalGeneration)
    }

    try fixture.write(token: "synthetic-renewed-after-consent-token")
    clock.advance(by: 61)
    let renewed = await service.refresh()
    #expect(count.count == 2)
    #expect(renewed.state == .current)
    #expect(renewed.observation?.capturedAt == clock.now())
    #expect(try await reader.load(now: clock.now()).context.generation != originalGeneration)
  }

  @Test(arguments: [false, true])
  func withdrawalDiscardsLeaseWithoutLosingRefusalIdentity(userConsent: Bool) async throws {
    let fixture = try ReaderFixture()
    let count = ReaderCounter()
    let key = fixture.key
    let reader = DesktopCredentialReader(
      directory: fixture.directory,
      keyReader: {
        count.increment()
        return key
      })
    let approval = DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true)
    await reader.setApproval(approval)
    var lease: DesktopCredentialLease? = try await reader.load(now: readerNow)
    let generation = try #require(lease).context.generation
    weak var discarded = lease
    lease = nil
    #expect(discarded != nil)

    await reader.setApproval(DesktopAccessApproval(userConsented: userConsent))
    #expect(discarded == nil)
    let readCount = count.count
    do {
      _ = try await reader.load(now: readerNow)
      Issue.record("Credential read without access approval")
    } catch {
      #expect(
        error as? DesktopCredentialError
          == (userConsent ? .providerApprovalRequired : .consentRequired))
    }
    #expect(count.count == readCount)
    await reader.setApproval(approval)
    let reacquired = try await reader.load(now: readerNow)
    #expect(reacquired.context.generation == generation)
    #expect(count.count > readCount)
  }

  @Test func reapprovalRevalidatesContextWithoutReusingAnOldLeaseObject() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    let approval = DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true)
    await reader.setApproval(approval)
    let original = try await reader.load(now: readerNow)
    await reader.setApproval(DesktopAccessApproval())
    #expect(await reader.currentContext(for: original, now: readerNow) == nil)
    await reader.setApproval(approval)
    #expect(await reader.currentContext(for: original, now: readerNow) == original.context)
    let reacquired = try await reader.load(now: readerNow)
    #expect(reacquired !== original)
    #expect(reacquired.context.generation == original.context.generation)
    #expect(await reader.currentContext(for: reacquired, now: readerNow) == reacquired.context)
  }

  @Test func repeatedReadReusesLeaseAndActualRenewalChangesGeneration() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = try await reader.load(now: readerNow)
    let second = try await reader.load(now: readerNow)
    #expect(first === second)
    try fixture.write(token: "synthetic-renewed-token")
    let current = await reader.currentContext(for: first, now: readerNow)
    let renewed = try await reader.load(now: readerNow)
    #expect(renewed.context.generation != first.context.generation)
    #expect(current == renewed.context)
    #expect(current != first.context)
    #expect(await reader.currentContext(for: renewed, now: readerNow) == renewed.context)
  }

  @Test func unrelatedWritePreservesCurrentContextAndCredentialGeneration() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = try await reader.load(now: readerNow)
    try fixture.write(extra: true)
    #expect(await reader.currentContext(for: first, now: readerNow) == first.context)
    let changed = try await reader.load(now: readerNow)
    #expect(changed !== first)
    #expect(changed.context.generation == first.context.generation)
    #expect(await reader.currentContext(for: first, now: readerNow) == changed.context)
  }

  @Test func v2DeletionDoesNotResurrectLegacyCredential() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = try await reader.load(now: readerNow)
    try fixture.write(nullV2: true)
    do {
      _ = try await reader.load(now: readerNow)
      Issue.record("Deleted V2 accepted")
    } catch { #expect(error as? DesktopCredentialError == .invalidStore) }
    #expect(await reader.lastFailureStage == .configuration)
    try fixture.write()
    let restored = try await reader.load(now: readerNow)
    #expect(await reader.lastFailureStage == nil)
    // A temporarily deleted identical credential cannot bypass a 401 rejection.
    #expect(restored.context.generation == first.context.generation)
    #expect(restored !== first)
  }

  @Test func transientReadFailureDoesNotRenewRejectedCredential() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = try await reader.load(now: readerNow)
    var coordinator = DesktopUsageCoordinator()
    coordinator.setPermission(.allowed)
    let admission = coordinator.begin(context: first.context, now: readerNow)
    let request = try #require(admission)
    coordinator.complete(
      request,
      reply: .response(
        status: 401, profileOwner: nil, serverDate: nil, cacheAge: nil, retryAfter: nil,
        body: Data()), context: first.context, now: readerNow)
    try Data("{".utf8).write(to: fixture.directory.appendingPathComponent("config.json"))
    #expect(await reader.currentContext(for: first, now: readerNow) == nil)
    try fixture.write()
    let restored = try await reader.load(now: readerNow)
    #expect(restored.context.generation == first.context.generation)
    let retried = coordinator.begin(
      context: restored.context, now: readerNow.addingTimeInterval(61))
    #expect(retried == nil)
    #expect(coordinator.state == .waitingForDesktopRenewal)
  }

  @Test func permissionDenialIsNotRetriedWithoutExplicitApprovalChange() async throws {
    let fixture = try ReaderFixture()
    let count = ReaderCounter()
    let reader = DesktopCredentialReader(
      directory: fixture.directory,
      keyReader: {
        count.increment()
        throw DesktopCredentialError.permissionRequired
      })
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    for _ in 0..<3 {
      do {
        _ = try await reader.load(now: readerNow)
        Issue.record("Unexpected permission")
      } catch { #expect(error as? DesktopCredentialError == .permissionRequired) }
    }
    #expect(count.count == 1)
    #expect(await reader.lastFailureStage == .keychain)
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    _ = try? await reader.load(now: readerNow)
    #expect(count.count == 2)
  }

  @Test func observedAccountSwitchIncludingReturnGetsDistinctGeneration() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = try await reader.load(now: readerNow)
    try fixture.write(account: "33333333-3333-4333-8333-333333333333")
    let current = await reader.currentContext(for: first, now: readerNow)
    let alternate = try await reader.load(now: readerNow)
    #expect(current == alternate.context)
    #expect(current != first.context)
    try fixture.write()
    let returned = try await reader.load(now: readerNow)
    #expect(first.context.owner != alternate.context.owner)
    #expect(first.context.owner == returned.context.owner)
    #expect(
      Set([first.context.generation, alternate.context.generation, returned.context.generation])
        .count == 3)
  }
}
