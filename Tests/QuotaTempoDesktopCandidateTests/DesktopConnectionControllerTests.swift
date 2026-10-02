import Foundation
import QuotaTempoCore
import Testing

@testable import QuotaTempoDesktopCandidate

private let connectionNow = Date(timeIntervalSince1970: 1_900_000_000)

private func connectionResult(
  state: DesktopUsageState = .current,
  error: DesktopCredentialError? = nil,
  disposition: DesktopUsageCandidateResult.Disposition = .replaceDisplay,
  resetAfter: TimeInterval = 400_000,
  nextAllowedAt: Date? = connectionNow.addingTimeInterval(300)
) -> DesktopUsageCandidateResult {
  DesktopUsageCandidateResult(
    disposition: disposition, state: state,
    observation: DesktopUsageObservation(
      owner: DesktopUsageOwner(
        accountFingerprint: String(repeating: "a", count: 64),
        organizationFingerprint: String(repeating: "b", count: 64)),
      capturedAt: connectionNow,
      values: DesktopUsageValues(
        weekly: QuotaWindow(
          remainingPercent: 81, durationSeconds: 604_800,
          resetAt: connectionNow.addingTimeInterval(resetAfter)), fiveHour: nil)),
    credentialError: error, nextAllowedAt: nextAllowedAt)
}

private final class ConnectionClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = connectionNow

  func now() -> Date { lock.withLock { instant } }
  func advance(by interval: TimeInterval) {
    lock.withLock { instant = instant.addingTimeInterval(interval) }
  }
}

private actor ConnectionGate {
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var blocked: CheckedContinuation<Void, Never>?

  func pause() async {
    entered = true
    waiter?.resume()
    waiter = nil
    await withCheckedContinuation { blocked = $0 }
  }

  func waitForEntry() async {
    if !entered { await withCheckedContinuation { waiter = $0 } }
  }

  func release() {
    blocked?.resume()
    blocked = nil
  }
}

private actor ConnectionServiceStub: DesktopConnectionServing {
  private(set) var approvals: [DesktopAccessApproval] = []
  private(set) var refreshes = 0
  private(set) var rechecks = 0
  private(set) var refreshWasCancelled = false
  private var replies: [DesktopUsageCandidateResult]
  private var refreshGate: ConnectionGate?
  private var approvalGate: ConnectionGate?
  private var revocationGate: ConnectionGate?

  init(
    replies: [DesktopUsageCandidateResult] = [connectionResult()],
    approvalGate: ConnectionGate? = nil
  ) {
    self.replies = replies
    self.approvalGate = approvalGate
  }

  func blockRefresh(_ gate: ConnectionGate) { refreshGate = gate }
  func blockRevocation(_ gate: ConnectionGate) { revocationGate = gate }
  func prepareForOfflineRepair() -> Bool { approvals.last?.allowsAccess == false }

  func setApproval(_ approval: DesktopAccessApproval) async {
    approvals.append(approval)
    if approval.allowsAccess, let gate = approvalGate {
      approvalGate = nil
      await gate.pause()
    } else if !approval.allowsAccess, let gate = revocationGate {
      revocationGate = nil
      await gate.pause()
    }
  }

  func refresh() async -> DesktopUsageCandidateResult {
    refreshes += 1
    return await reply()
  }

  func recheckConnection() async -> DesktopUsageCandidateResult {
    rechecks += 1
    return await reply()
  }

  private func reply() async -> DesktopUsageCandidateResult {
    if let gate = refreshGate {
      refreshGate = nil
      await gate.pause()
    }
    refreshWasCancelled = Task.isCancelled
    return replies.count > 1 ? replies.removeFirst() : replies[0]
  }
}

private actor ConnectionSyntheticReader: DesktopCredentialReading {
  private let lease: DesktopCredentialLease
  private var approval = DesktopAccessApproval()
  private(set) var loads = 0

  init() throws {
    lease = try DesktopCredentialLease(
      context: DesktopUsageContext(
        owner: DesktopUsageOwner(
          accountFingerprint: String(repeating: "a", count: 64),
          organizationFingerprint: String(repeating: "b", count: 64)),
        generation: UUID(), expiresAt: connectionNow.addingTimeInterval(86_400),
        hasProfileScope: true), token: Data("synthetic-controller-token".utf8))
  }

  func setApproval(_ approval: DesktopAccessApproval) { self.approval = approval }
  func load(now: Date) throws -> DesktopCredentialLease {
    try approval.requireAccess()
    loads += 1
    return lease
  }
  func currentContext(for lease: DesktopCredentialLease, now: Date) -> DesktopUsageContext? {
    approval.allowsAccess ? lease.context : nil
  }
}

private actor ConnectionFetchCounter {
  private(set) var calls = 0
  func increment() { calls += 1 }
}

private final class ConnectionWriteControl: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  private var failingFrom: Int? = 3

  var writes: Int { lock.withLock { attempts } }
  func allowWrites() { lock.withLock { failingFrom = nil } }
  func admit() throws {
    try lock.withLock {
      attempts += 1
      if let failingFrom, attempts >= failingFrom { throw DesktopThrottleStoreError.ioFailure }
    }
  }
}

private final class ConnectionFailingFileStore: DesktopThrottleStoring {
  private let backing: DesktopThrottleFileStore
  private let control: ConnectionWriteControl

  init(backing: DesktopThrottleFileStore, control: ConnectionWriteControl) {
    self.backing = backing
    self.control = control
  }
  func load() throws -> DesktopThrottleRecord? { try backing.load() }
  func save(_ record: DesktopThrottleRecord) throws {
    try control.admit()
    try backing.save(record)
  }
}

private final class ConnectionDirectory {
  let url: URL
  init() throws {
    url = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("QuotaTempo-Controller-Synthetic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("Public Desktop connection controller")
@MainActor
struct DesktopConnectionControllerTests {
  private func controller(_ service: ConnectionServiceStub) -> DesktopConnectionController {
    DesktopConnectionController(
      clock: { connectionNow }, displayInterval: .seconds(3600),
      makeService: { service }, repairStore: { _ in .notNeeded })
  }

  @Test func disconnectedInitializationAndUnapprovedActionsAreInert() async {
    var creations = 0
    var repairs = 0
    let service = ConnectionServiceStub()
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        creations += 1
        return service
      },
      repairStore: { _ in
        repairs += 1
        return .notNeeded
      })
    #expect(model.status == .disconnected)
    #expect(model.statusText == model.status.text)
    #expect(!model.isConnected && !model.isRefreshing)
    await model.refresh()
    await model.refresh(recheck: true)
    model.updateDisplay()
    await model.disconnect()
    await model.connect(localExperimentAuthorized: false)
    #expect(creations == 0 && repairs == 0)
    #expect(await service.approvals.isEmpty)
    #expect(await service.refreshes == 0)
    #expect(await service.rechecks == 0)
    #expect(model.snapshot == nil && model.nextAllowedAt == nil)
    #expect(model.status == .consentRequired)
  }

  @Test func publicInitializerDoesNotOpenTheDirectoryWithoutConsent() async throws {
    let fixture = try ConnectionDirectory()
    let model = DesktopConnectionController(directory: fixture.url, clock: { connectionNow })
    await model.connect(localExperimentAuthorized: false)
    await model.refresh(recheck: true)
    model.updateDisplay()
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
    #expect(model.snapshot == nil)
  }

  @Test func explicitOfflineRepairNeedsNoConnectionOrService() async {
    var creations = 0
    var repairs = 0
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        creations += 1
        return ConnectionServiceStub()
      },
      repairStore: { now in
        #expect(now == connectionNow)
        repairs += 1
        return .notNeeded
      })
    #expect(await model.repair() == .notNeeded)
    #expect(creations == 0 && repairs == 1)
    #expect(!model.isConnected && !model.isRefreshing && !model.isRepairing)
    await model.refresh(recheck: true)
    model.updateDisplay()
    #expect(model.snapshot == nil && creations == 0)
    await model.connect(localExperimentAuthorized: true)
    #expect(creations == 1 && model.isConnected)
    await model.disconnect()
  }

  @Test func offlineRepairOfANeverCreatedDirectoryIsANoOp() async throws {
    let fixture = try ConnectionDirectory()
    let unused = fixture.url.appendingPathComponent("unused/DesktopConnection", isDirectory: true)
    let model = DesktopConnectionController(directory: unused, clock: { connectionNow })
    #expect(await model.repair() == .notNeeded)
    #expect(!model.isConnected && !model.isRepairing)
    #expect(model.snapshot == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
  }

  @Test func explicitConnectionLazilyCreatesTheManagedStoreWithSyntheticAcquisition() async throws {
    let fixture = try ConnectionDirectory()
    let directory = fixture.url.appendingPathComponent(
      "preview/DesktopConnection", isDirectory: true)
    let reader = try ConnectionSyntheticReader()
    let counter = ConnectionFetchCounter()
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        DesktopUsageCandidateService(
          reader: reader, clock: { connectionNow },
          throttleStore: try DesktopThrottleFileStore.prepared(directory: directory)
        ) { _, _ in
          await counter.increment()
          return .networkFailure
        }
      }, repairStore: { _ in .notNeeded })
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
    await model.connect(localExperimentAuthorized: false)
    await model.refresh()
    model.updateDisplay()
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
    #expect(await reader.loads == 0)
    #expect(await counter.calls == 0)
    await model.connect(localExperimentAuthorized: true)
    #expect(model.isConnected && model.status == .temporaryFailure)
    #expect(await reader.loads == 1)
    #expect(await counter.calls == 1)
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        == ["desktop-throttle.json", "desktop-throttle.lock"])
    await model.disconnect()
  }

  @Test func explicitConnectionPublishesOnlyNormalizedDesktopValues() async throws {
    let service = ConnectionServiceStub()
    let model = controller(service)
    await model.connect(localExperimentAuthorized: true)
    await model.connect(localExperimentAuthorized: true)
    #expect(model.isConnected && !model.isRefreshing)
    #expect(model.status == .current)
    #expect(model.nextAllowedAt == connectionNow.addingTimeInterval(300))
    let snapshot = try #require(model.snapshot)
    #expect(snapshot.provider == .claude && snapshot.source == .claudeDesktopDirect)
    #expect(snapshot.weekly?.remainingPercent == 81)
    #expect(snapshot.claudeAccountFingerprint == nil)
    #expect(snapshot.claudeOrganizationFingerprint == nil)
    #expect(snapshot.codexExecutableSource == nil)
    #expect(await service.refreshes == 1)
    #expect(await service.approvals.count == 1)
    #expect(await service.approvals.first?.userConsented == true)
    #expect(await service.approvals.first?.localExperimentAuthorized == true)
    #expect(await service.approvals.first?.providerApproved == false)
    await model.refresh(recheck: true)
    #expect(await service.rechecks == 1)
    await model.disconnect()
  }

  @Test func storageFactoryFailureDoesNotFallBackOrExposeDiagnostics() async {
    struct SensitiveFailure: Error, CustomStringConvertible {
      var description: String { "synthetic-private-path-and-identity" }
    }
    var creations = 0
    let model = DesktopConnectionController(
      makeService: {
        creations += 1
        throw SensitiveFailure()
      }, repairStore: { _ in .notNeeded })
    await model.connect(localExperimentAuthorized: true)
    await model.refresh(recheck: true)
    #expect(creations == 1)
    #expect(model.isConnected)
    #expect(model.status == .storageUnavailable)
    #expect(!model.statusText.contains("synthetic-private"))
    #expect(model.snapshot == nil && !model.isRefreshing)
    await model.disconnect()
  }

  @Test func lockedStoreReportsAnotherOwnerAndRequiresANewExplicitConnection() async {
    var locked = true
    var creations = 0
    let service = ConnectionServiceStub()
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        creations += 1
        if locked { throw DesktopThrottleStoreError.locked }
        return service
      }, repairStore: { _ in .notNeeded })
    await model.connect(localExperimentAuthorized: true)
    #expect(model.status == .storeInUse)
    #expect(
      model.statusText
        == "Another Desktop connection owns scheduling state. Close it before connecting.")
    #expect(!model.isConnected && !model.isRefreshing)
    #expect(model.snapshot == nil)
    #expect(await service.approvals.isEmpty)
    locked = false
    await model.refresh(recheck: true)
    #expect(creations == 1)
    #expect(await service.refreshes == 0)
    await model.connect(localExperimentAuthorized: true)
    #expect(creations == 2 && model.isConnected)
    #expect(await service.refreshes == 1)
    await model.disconnect()
  }

  @Test func concurrentRefreshesAreCoalescedAndRecheckIsExplicit() async {
    let service = ConnectionServiceStub()
    let model = controller(service)
    await model.connect(localExperimentAuthorized: true)
    let gate = ConnectionGate()
    await service.blockRefresh(gate)
    let pending = Task { await model.refresh() }
    await gate.waitForEntry()
    #expect(model.isRefreshing)
    await model.refresh()
    await model.refresh(recheck: true)
    #expect(await service.refreshes == 2)
    #expect(await service.rechecks == 0)
    #expect(await model.repair() == .busy)
    #expect(model.status == .waitingForIdle)
    await gate.release()
    await pending.value
    #expect(!model.isRefreshing)
    await model.disconnect()
  }

  @Test func unchangedDispositionPreservesSnapshotStatusAndDeadline() async {
    let unchanged = connectionResult(
      state: .permissionDenied, error: .permissionRequired,
      disposition: .unchangedInFlight, nextAllowedAt: nil)
    let service = ConnectionServiceStub(replies: [connectionResult(), unchanged])
    let model = controller(service)
    await model.connect(localExperimentAuthorized: true)
    let before = model.snapshot
    let deadline = model.nextAllowedAt
    await model.refresh()
    #expect(model.snapshot == before)
    #expect(model.status == .current)
    #expect(model.nextAllowedAt == deadline)
    #expect(!model.isRefreshing)
    await model.disconnect()
  }

  @Test func terminalFailureClearsValuesAndNeverChangesSource() async {
    let service = ConnectionServiceStub(
      replies: [connectionResult(), connectionResult(state: .waitingForDesktopRenewal)])
    let model = controller(service)
    await model.connect(localExperimentAuthorized: true)
    await model.refresh()
    #expect(model.snapshot?.weekly == nil && model.snapshot?.capturedAt == nil)
    #expect(model.snapshot?.source == .claudeDesktopDirect)
    #expect(model.status == .renewalRequired)
    #expect(!model.statusText.contains("CLI") && !model.statusText.contains("browser"))
    await model.disconnect()
  }

  @Test(arguments: [false, true])
  func displayUpdateExpiresValuesWithoutProtectedReadsOrRequests(resetExpires: Bool) async {
    let clock = ConnectionClock()
    let service = ConnectionServiceStub(
      replies: [connectionResult(resetAfter: resetExpires ? 60 : 400_000)])
    let model = DesktopConnectionController(
      clock: { clock.now() }, displayInterval: .seconds(3600),
      makeService: { service }, repairStore: { _ in .notNeeded })
    await model.connect(localExperimentAuthorized: true)
    let gate = ConnectionGate()
    await service.blockRefresh(gate)
    let pending = Task { await model.refresh() }
    await gate.waitForEntry()
    clock.advance(by: resetExpires ? 60 : 900)
    model.updateDisplay()
    #expect(model.snapshot?.weekly == nil && model.snapshot?.capturedAt == nil)
    #expect(model.status == .stale && model.isRefreshing)
    #expect(await service.refreshes == 2)
    #expect(await service.rechecks == 0)
    #expect(await service.approvals.count == 1)
    await gate.release()
    await pending.value
    await model.disconnect()
    model.updateDisplay()
    #expect(model.snapshot == nil)
  }

  @Test func disconnectClearsBeforeRevocationAndDiscardsLateSuccess() async {
    let service = ConnectionServiceStub()
    let model = controller(service)
    await model.connect(localExperimentAuthorized: true)
    let fetchGate = ConnectionGate()
    let revokeGate = ConnectionGate()
    await service.blockRefresh(fetchGate)
    await service.blockRevocation(revokeGate)
    let refresh = Task { await model.refresh() }
    await fetchGate.waitForEntry()
    let disconnect = Task { await model.disconnect() }
    await revokeGate.waitForEntry()
    #expect(!model.isConnected && !model.isRefreshing)
    #expect(model.snapshot == nil && model.nextAllowedAt == nil)
    #expect(model.status == .disconnected)
    await revokeGate.release()
    await disconnect.value
    await model.connect(localExperimentAuthorized: true)
    #expect(!model.isConnected && model.status == .waitingForIdle)
    await fetchGate.release()
    await refresh.value
    #expect(await service.refreshWasCancelled)
    #expect(await service.approvals.last?.allowsAccess == false)
    #expect(model.snapshot == nil && !model.isRefreshing)
    await model.connect(localExperimentAuthorized: true)
    #expect(model.snapshot?.weekly?.remainingPercent == 81)
    await model.disconnect()
  }

  @Test func disconnectDuringApprovalCannotBeOvertakenByConnect() async {
    let gate = ConnectionGate()
    let service = ConnectionServiceStub(approvalGate: gate)
    let model = controller(service)
    let connect = Task { await model.connect(localExperimentAuthorized: true) }
    await gate.waitForEntry()
    // Begin revocation on this actor before releasing the first approval.
    let disconnect = Task { await model.disconnect() }
    for _ in 0..<100 where model.isConnected { await Task.yield() }
    #expect(!model.isConnected)
    await model.connect(localExperimentAuthorized: true)
    #expect(!model.isConnected)
    #expect(await service.approvals.count == 1)
    await gate.release()
    await connect.value
    await disconnect.value
    #expect(await service.approvals.map(\.allowsAccess) == [true, false])
    #expect(await service.refreshes == 0)
    #expect(model.snapshot == nil && !model.isConnected)
  }

  @Test func falseConsentRevokesAnExistingConnection() async {
    let service = ConnectionServiceStub()
    let model = controller(service)
    await model.connect(localExperimentAuthorized: true)
    await model.connect(localExperimentAuthorized: false)
    await model.refresh(recheck: true)
    #expect(model.snapshot == nil && model.nextAllowedAt == nil)
    #expect(!model.isConnected && !model.isRefreshing)
    #expect(model.status == .consentRequired)
    #expect(await service.approvals.last?.allowsAccess == false)
    #expect(await service.refreshes == 1)
    #expect(await service.rechecks == 0)
  }

  @Test func callerCancellationReachesRefreshWithoutPublishingItsResult() async {
    let service = ConnectionServiceStub(
      replies: [connectionResult(), connectionResult(state: .accessDenied)])
    let model = controller(service)
    await model.connect(localExperimentAuthorized: true)
    let before = model.snapshot
    let gate = ConnectionGate()
    await service.blockRefresh(gate)
    let refresh = Task { await model.refresh() }
    await gate.waitForEntry()
    refresh.cancel()
    await gate.release()
    await refresh.value
    #expect(await service.refreshWasCancelled)
    #expect(model.snapshot == before && model.status == .current)
    #expect(!model.isRefreshing)
    await model.disconnect()
  }

  @Test func repairRefusesAStillRetainedOwnerInsteadOfUnlocking() async {
    let service = ConnectionServiceStub()
    var repairs = 0
    let model = DesktopConnectionController(
      clock: { connectionNow }, makeService: { service },
      repairStore: { _ in
        repairs += 1
        return .repaired
      })
    await model.connect(localExperimentAuthorized: true)
    #expect(await model.repair() == .restartRequired)
    #expect(model.status == .restartRequired && model.snapshot == nil)
    #expect(!model.isConnected && !model.isRepairing)
    #expect(repairs == 0)
    #expect(await service.approvals.last?.allowsAccess == false)
    await model.refresh(recheck: true)
    #expect(await service.rechecks == 0)
    await model.disconnect()
  }

  @Test func disconnectDuringRepairRevocationPreventsRecoveryAndRecreation() async {
    let service = ConnectionServiceStub()
    var repairs = 0
    var creations = 0
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        creations += 1
        return service
      },
      repairStore: { _ in
        repairs += 1
        return .repaired
      })
    await model.connect(localExperimentAuthorized: true)
    let gate = ConnectionGate()
    await service.blockRevocation(gate)
    let repair = Task { await model.repair() }
    await gate.waitForEntry()
    #expect(model.isRepairing && !model.isConnected)
    let disconnect = Task { await model.disconnect() }
    for _ in 0..<100 where model.status != .disconnected { await Task.yield() }
    #expect(!model.isConnected)
    await gate.release()
    #expect(await repair.value == .cancelled)
    await disconnect.value
    #expect(repairs == 0 && creations == 1)
    #expect(model.snapshot == nil && !model.isConnected)
    #expect(await service.approvals.last?.allowsAccess == false)
  }

  @Test func repairReleasesLockAndRequiresNewConsentWhilePreservingProviderDeadline() async throws {
    let fixture = try ConnectionDirectory()
    let reader = try ConnectionSyntheticReader()
    let counter = ConnectionFetchCounter()
    let deadline = connectionNow.addingTimeInterval(7200)
    var creations = 0
    let model = DesktopConnectionController(
      clock: { connectionNow }, displayInterval: .seconds(3600),
      makeService: {
        creations += 1
        return DesktopUsageCandidateService(
          reader: reader, clock: { connectionNow },
          throttleStore: try DesktopThrottleFileStore(directory: fixture.url)
        ) { _, _ in
          await counter.increment()
          return .response(
            status: 429, profileOwner: nil, serverDate: connectionNow, cacheAge: nil,
            retryAfter: deadline, body: Data())
        }
      },
      repairStore: { now in
        try DesktopThrottleFileStore.recover(directory: fixture.url, now: now)
      })
    await model.connect(localExperimentAuthorized: true)
    #expect(model.nextAllowedAt == deadline)
    await model.disconnect()
    await model.connect(localExperimentAuthorized: true)
    #expect(creations == 1)
    #expect(await counter.calls == 1)
    let loads = await reader.loads
    #expect(await model.repair() == .preserved)
    #expect(creations == 1)
    #expect(model.status == .repaired && model.snapshot == nil)
    #expect(!model.isConnected && !model.isRepairing)
    #expect(model.nextAllowedAt == deadline)
    #expect(await reader.loads == loads)
    #expect(await counter.calls == 1)
    await model.refresh(recheck: true)
    #expect(model.nextAllowedAt == deadline)
    #expect(await counter.calls == 1)
    #expect(await reader.loads == loads)
    // An offline second repair can acquire the lifetime lock too.
    #expect(
      try DesktopThrottleFileStore.recover(directory: fixture.url, now: connectionNow)
        == .preserved)
    await model.connect(localExperimentAuthorized: true)
    #expect(creations == 2 && model.isConnected)
    #expect(model.nextAllowedAt == deadline)
    #expect(await counter.calls == 1)
    #expect(throws: DesktopThrottleStoreError.locked) {
      try DesktopThrottleFileStore(directory: fixture.url)
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
    #expect(Set(names) == ["desktop-throttle.json", "desktop-throttle.lock"])
    let data = try Data(contentsOf: fixture.url.appendingPathComponent("desktop-throttle.json"))
    let metadata = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(metadata.keys).isSubset(of: [
        "schemaVersion", "recordedAt", "lastAttemptAt", "localNextAllowedAt",
        "successfulNextAllowedAt", "serviceNotBefore", "unsupportedServiceWait", "failureCount",
        "interruptedUntil", "authRefusal", "authRefusalExpiresAt",
      ]))
    await model.disconnect()
  }

  @Test func failedProviderWaitWriteMustFlushBeforeOfflineRepairCanReleaseTheStore() async throws {
    let fixture = try ConnectionDirectory()
    let reader = try ConnectionSyntheticReader()
    let counter = ConnectionFetchCounter()
    let writes = ConnectionWriteControl()
    let deadline = connectionNow.addingTimeInterval(7200)
    let recordURL = fixture.url.appendingPathComponent("desktop-throttle.json")
    var creations = 0
    var recoveries = 0
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        creations += 1
        let store = ConnectionFailingFileStore(
          backing: try DesktopThrottleFileStore.prepared(directory: fixture.url), control: writes)
        // Seed an older valid checkpoint. The attempt is write 2 and the newly
        // observed 429 deadline is write 3, which fails until explicitly enabled.
        if creations == 1 { try store.save(DesktopThrottleRecord(recordedAt: connectionNow)) }
        return DesktopUsageCandidateService(
          reader: reader, clock: { connectionNow }, throttleStore: store
        ) { _, _ in
          await counter.increment()
          return .response(
            status: 429, profileOwner: nil, serverDate: connectionNow, cacheAge: nil,
            retryAfter: deadline, body: Data())
        }
      },
      repairStore: { now in
        recoveries += 1
        return try DesktopThrottleFileStore.recover(directory: fixture.url, now: now)
      })
    await model.connect(localExperimentAuthorized: true)
    #expect(writes.writes == 3 && model.status == .storageUnavailable)
    #expect(model.nextAllowedAt == deadline)
    let old = try JSONDecoder().decode(
      DesktopThrottleRecord.self, from: Data(contentsOf: recordURL))
    #expect(old.isValid && old.serviceNotBefore == nil)
    #expect(await counter.calls == 1)
    let reads = await reader.loads

    #expect(await model.repair() == .failed)
    #expect(model.status == .storageUnavailable && !model.isConnected)
    #expect(!model.isRepairing && model.snapshot == nil)
    #expect(creations == 1 && recoveries == 0 && writes.writes == 4)
    #expect(throws: DesktopThrottleStoreError.locked) {
      try DesktopThrottleFileStore(directory: fixture.url)
    }
    await model.refresh(recheck: true)
    #expect(await reader.loads == reads)
    #expect(await counter.calls == 1)

    writes.allowWrites()
    #expect(await model.repair() == .preserved)
    #expect(!model.isConnected && model.status == .repaired)
    #expect(creations == 1 && recoveries == 1 && writes.writes == 5)
    let flushed = try JSONDecoder().decode(
      DesktopThrottleRecord.self, from: Data(contentsOf: recordURL))
    #expect(flushed.serviceNotBefore == deadline)
    #expect(await reader.loads == reads)
    #expect(await counter.calls == 1)

    await model.connect(localExperimentAuthorized: true)
    #expect(creations == 2 && model.nextAllowedAt == deadline)
    await model.refresh(recheck: true)
    #expect(await counter.calls == 1)
    await model.disconnect()
  }

  @Test func repairCanRecoverAnInitialStoreFailureWithoutCreatingAService() async {
    var creations = 0
    var repairs = 0
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        creations += 1
        if creations == 1 { throw DesktopThrottleStoreError.missingRecord }
        return ConnectionServiceStub()
      },
      repairStore: { now in
        #expect(now == connectionNow)
        repairs += 1
        return .repaired
      })
    await model.connect(localExperimentAuthorized: true)
    #expect(model.status == .storageUnavailable)
    #expect(await model.repair() == .repaired)
    #expect(creations == 1 && repairs == 1)
    #expect(model.snapshot == nil && model.status == .repaired)
    #expect(!model.isConnected && !model.isRepairing)
    await model.refresh()
    #expect(model.snapshot == nil && creations == 1)
    await model.connect(localExperimentAuthorized: true)
    #expect(creations == 2)
    #expect(model.snapshot?.weekly?.remainingPercent == 81)
    await model.disconnect()
  }

  @Test(arguments: [false, true])
  func unsupportedOrFailedRepairNeverCreatesAnotherService(fails: Bool) async {
    var creations = 0
    let model = DesktopConnectionController(
      clock: { connectionNow },
      makeService: {
        creations += 1
        return ConnectionServiceStub()
      },
      repairStore: { _ in
        if fails { throw DesktopThrottleStoreError.ioFailure }
        return .unsupportedVersion
      })
    await model.connect(localExperimentAuthorized: true)
    #expect(await model.repair() == (fails ? .failed : .unsupportedVersion))
    #expect(model.status == (fails ? .storageUnavailable : .repairUnsupported))
    #expect(!model.isConnected && !model.isRepairing)
    await model.refresh(recheck: true)
    #expect(creations == 1 && model.snapshot == nil)
    await model.disconnect()
  }
}
