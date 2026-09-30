import CommonCrypto
import Foundation
import SQLite3
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

@Suite("Desktop protected reader synthetic integration")
struct DesktopCredentialReaderTests {
  @Test func repeatedReadReusesLeaseAndActualRenewalChangesGeneration() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = try await reader.load(now: readerNow)
    let second = try await reader.load(now: readerNow)
    #expect(first === second)
    try fixture.write(token: "synthetic-renewed-token")
    let renewed = try await reader.load(now: readerNow)
    #expect(renewed.context.generation != first.context.generation)
    #expect(await reader.currentContext(for: first, now: readerNow) == nil)
    #expect(await reader.currentContext(for: renewed, now: readerNow) == renewed.context)
  }

  @Test func unrelatedWriteRejectsInFlightButDoesNotBypassAuthenticationBlock() async throws {
    let fixture = try ReaderFixture()
    let reader = fixture.reader()
    await reader.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = try await reader.load(now: readerNow)
    try fixture.write(extra: true)
    let changed = try await reader.load(now: readerNow)
    #expect(changed !== first)
    #expect(changed.context.generation == first.context.generation)
    #expect(await reader.currentContext(for: first, now: readerNow) == nil)
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
    try fixture.write()
    let restored = try await reader.load(now: readerNow)
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
    let alternate = try await reader.load(now: readerNow)
    try fixture.write()
    let returned = try await reader.load(now: readerNow)
    #expect(first.context.owner != alternate.context.owner)
    #expect(first.context.owner == returned.context.owner)
    #expect(
      Set([first.context.generation, alternate.context.generation, returned.context.generation])
        .count == 3)
  }
}
