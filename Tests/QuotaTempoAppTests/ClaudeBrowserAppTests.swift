import Foundation
import Testing

@testable import QuotaTempoApp
@testable import QuotaTempoCore

// Exercise the model only: no application, window, updater, browser or real provider is started.
@Suite("Claude browser application integration", .serialized)
@MainActor
struct ClaudeBrowserAppTests {
  @Test("Minute clock imports newly ingested browser W/P without waiting for CLI refresh")
  func minuteClockUpdatesBrowserPlan() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 88))
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 88 }
    #expect(fixture.io.readCount == 0)
    let initialTitle = MenuBarTitleFormatter.title(scenario: model.scenario, mode: .full)

    try fixture.ingest(remaining: 63, resetAfter: 3 * 86_400, offset: -2)
    model.clockAdvanced()
    try await self.waitFor(model) {
      model.scenario.snapshots.first?.source == .claudeBrowser
        && model.scenario.snapshots.first?.weekly?.remainingPercent == 63
    }
    let first = try #require(model.scenario.snapshots.first)
    let firstPlan = QuotaPlanner.evaluate(first, now: model.scenario.now)
    #expect(firstPlan.weeklyRemaining == 63)
    #expect(abs(try #require(firstPlan.targetNow) - 300.0 / 7) < 0.05)
    #expect(!firstPlan.targetIsEstimated)
    #expect(first.capturedAt == fixture.now.addingTimeInterval(-2))
    #expect(try fixture.store.load(.claude)?.source == .claudeBrowser)
    #expect(
      MenuBarTitleFormatter.title(scenario: model.scenario, mode: .full)?.contains("W63/P43")
        == true)
    #expect(MenuBarTitleFormatter.title(scenario: model.scenario, mode: .full) != initialTitle)

    try fixture.ingest(remaining: 32, resetAfter: 2 * 86_400, offset: -1)
    model.clockAdvanced()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 32 }
    let second = try #require(model.scenario.snapshots.first)
    let secondPlan = QuotaPlanner.evaluate(second, now: model.scenario.now)
    #expect(secondPlan.weeklyRemaining == 32)
    #expect(abs(try #require(secondPlan.targetNow) - 200.0 / 7) < 0.05)
    #expect(second.weekly?.resetAt == fixture.now.addingTimeInterval(2 * 86_400))
    #expect(
      MenuBarTitleFormatter.title(scenario: model.scenario, mode: .full)?.contains("W32/P29")
        == true)
    #expect(try fixture.store.load(.claude)?.weekly?.remainingPercent == 32)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.probeCount == 0)
    #expect(fixture.io.resolverCount == 0)
  }

  @Test("Transient browser errors update attempts while preserving actual capture time and W/P")
  func transientErrorsReachModel() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(remaining: 57, offset: -120)
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 57 }
    let successful = try #require(model.scenario.snapshots.first)

    for (status, offset) in [("unavailable", -60.0), ("rateLimited", -1.0)] {
      try fixture.ingest(status: status, offset: offset)
      model.clockAdvanced()
      try await self.waitFor(model) {
        model.scenario.snapshots.first?.lastAttemptAt == fixture.now.addingTimeInterval(offset)
      }
      let failed = try #require(model.scenario.snapshots.first)
      #expect(failed.source == .claudeBrowser)
      #expect(failed.capturedAt == successful.capturedAt)
      #expect(failed.weekly == successful.weekly)
      #expect(failed.fiveHour == successful.fiveHour)
      #expect(failed.sourceState == .attemptFailed)
      #expect(
        failed.errorCode == (status == "rateLimited" ? .temporaryFailure : .sourceUnavailable))
      #expect(QuotaPlanner.evaluate(failed, now: model.scenario.now).targetNow != nil)
    }
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
  }

  @Test("Signout clears displayed and persisted browser quotas without local-source fallback")
  func signoutClearsModel() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }

    try fixture.ingest(status: "signedOut", offset: -1)
    model.clockAdvanced()
    try await self.waitFor(model) {
      model.scenario.snapshots.first?.errorCode == .authenticationRequired
        && model.scenario.snapshots.first?.weekly == nil
    }
    let cleared = try #require(model.scenario.snapshots.first)
    #expect(cleared.source == .claudeBrowser)
    #expect(cleared.capturedAt == nil)
    #expect(cleared.fiveHour == nil)
    #expect(QuotaPlanner.evaluate(cleared, now: model.scenario.now).targetNow == nil)
    #expect(try fixture.store.load(.claude)?.weekly == nil)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
  }

  @Test("Rejected ownership changes propagate persisted revocation to the next minute tick")
  func ownershipRevocationReachesModel() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }
    #expect(throws: ClaudeBrowserBridgeError.accountMismatch) {
      try fixture.ingest(offset: -1, accountFingerprint: String(repeating: "d", count: 64))
    }
    model.clockAdvanced()
    try await self.waitFor(model) {
      model.scenario.snapshots.first?.sourceState == .attemptFailed
        && model.scenario.snapshots.first?.weekly == nil
    }
    let revoked = try #require(model.scenario.snapshots.first)
    #expect(revoked.source == .claudeBrowser)
    #expect(revoked.capturedAt == nil)
    #expect(revoked.fiveHour == nil)
    #expect(revoked.claudeAccountFingerprint == nil)
    #expect(QuotaPlanner.evaluate(revoked, now: model.scenario.now).targetNow == nil)
    #expect(try fixture.store.load(.claude)?.weekly == nil)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
  }

  @Test("Disconnect removes browser W/P and never passes its account data to local fallback")
  func disconnectClearsModel() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }

    try fixture.ingest(status: "disconnected", offset: -1)
    model.clockAdvanced()
    try await self.waitFor(model) {
      model.scenario.snapshots.first?.source != .claudeBrowser
        && model.scenario.snapshots.first?.weekly == nil
    }
    let cleared = try #require(model.scenario.snapshots.first)
    #expect(cleared.capturedAt == nil)
    #expect(cleared.fiveHour == nil)
    #expect(cleared.claudeAccountFingerprint == nil)
    #expect(cleared.claudeOrganizationFingerprint == nil)
    #expect(QuotaPlanner.evaluate(cleared, now: model.scenario.now).targetNow == nil)
    #expect(try fixture.store.load(.claude)?.weekly == nil)
    #expect(fixture.browser.selectedSnapshot(now: Date()) == nil)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.probeCount == 0)
    #expect(fixture.io.resolverCount == 0)
    #expect(fixture.io.readPaths.allSatisfy { $0.hasPrefix(fixture.root.path + "/") })
  }

  @Test("A malformed browser store clears previous browser W/P instead of falling through")
  func corruptStoreFailsClosedInModel() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }

    try Data("{broken".utf8).write(to: fixture.browser.url)
    model.clockAdvanced()
    try await self.waitFor(model) { model.scenario.snapshots.first?.errorCode == .invalidResponse }
    let failed = try #require(model.scenario.snapshots.first)
    #expect(failed.source == .claudeBrowser)
    #expect(failed.capturedAt == nil)
    #expect(failed.weekly == nil)
    #expect(failed.fiveHour == nil)
    #expect(QuotaPlanner.evaluate(failed, now: model.scenario.now).targetNow == nil)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
  }

  @Test("Without a browser record, minute ticks never acquire a due local Claude source")
  func minuteClockDoesNotAcquireLocalProvider() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 41 }
    let due = fixture.localSnapshot(
      remaining: 41, attemptedAt: fixture.now.addingTimeInterval(-3_600))
    try fixture.store.save(due)
    model.clockAdvanced()
    try await self.waitFor(model) {
      model.scenario.snapshots.first?.lastAttemptAt == due.lastAttemptAt
    }
    #expect(try fixture.store.load(.claude) == due)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.resolverCount == 0)
  }

  @Test("Disabled Claude is not ingested by minute ticks even when browser data is available")
  func disabledClaudeIsNotAcquired() async throws {
    let fixture = try BrowserAppFixture(enabled: [.codex])
    defer { fixture.cleanup() }
    // A recent synthetic Codex attempt prevents its non-injected adapter from running at launch.
    let codex = ProviderSnapshot(
      provider: .codex, source: .codexAppServer, capturedAt: fixture.now,
      weekly: QuotaWindow(
        remainingPercent: 90, durationSeconds: 604_800,
        resetAt: fixture.now.addingTimeInterval(259_200)),
      lastAttemptAt: fixture.now, sourceState: .observationSucceeded)
    try fixture.store.save(codex)
    let local = fixture.localSnapshot(remaining: 41)
    try fixture.store.save(local)
    try fixture.ingest(remaining: 63, offset: -2)
    let model = fixture.model()
    try await self.waitFor(model) { model.scenario.snapshots.map(\.provider) == [.codex] }
    try fixture.ingest(remaining: 22, offset: -1)
    model.clockAdvanced()
    try await self.waitFor(model) { model.scenario.snapshots.map(\.provider) == [.codex] }
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.enabledProviders == [.codex])
    #expect(model.scenario.snapshots == [codex])
    #expect(try fixture.store.load(.claude) == local)
    #expect(try fixture.store.load(.codex) == codex)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.resolverCount == 0)
  }

  @Test("The acquisition gate blocks browser imports for launch, ticks and all refresh triggers")
  func acquisitionDisabledIsRespected() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let local = fixture.localSnapshot(remaining: 41)
    try fixture.store.save(local)
    try fixture.ingest(remaining: 63, offset: -2)
    let model = fixture.model(acquisitionEnabled: false)
    #expect(!model.refreshInFlight)
    try fixture.ingest(remaining: 22, offset: -1)
    model.clockAdvanced()
    model.menuOpened()
    model.scheduledRefresh()
    model.systemDidWake()
    model.explicitRefresh()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!model.refreshInFlight)
    #expect(model.scenario.snapshots == [local])
    #expect(try fixture.store.load(.claude) == local)
    #expect(try fixture.browser.load()?.snapshot.weekly?.remainingPercent == 22)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.probeCount == 0)
    #expect(fixture.io.resolverCount == 0)
  }

  private func waitFor(_ model: LiveQuotaModel, condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if !model.refreshInFlight && condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.refreshInFlight, "Synthetic provider refresh did not finish")
    #expect(condition(), "Expected model state did not arrive within three seconds")
  }
}

@MainActor
private struct BrowserAppFixture {
  let root: URL
  let suiteName: String
  let defaults: UserDefaults
  let now: Date
  let store: NormalizedSnapshotStore
  let browser: ClaudeBrowserStore
  let preferences: ProviderSelectionPreferences
  let io = BrowserAppIsolationStub()

  init(enabled: Set<ProviderID> = [.claude]) throws {
    self.root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClaudeBrowserAppTests.\(UUID().uuidString)")
    self.suiteName = "ClaudeBrowserAppTests.\(UUID().uuidString)"
    self.defaults = try #require(UserDefaults(suiteName: self.suiteName))
    self.now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    self.store = NormalizedSnapshotStore(directory: self.root.appendingPathComponent("normalized"))
    self.browser = ClaudeBrowserStore(
      directory: self.store.directory.appendingPathComponent("BrowserBridge"))
    self.preferences = ProviderSelectionPreferences(defaults: self.defaults)
    self.preferences.save(ProviderSelection(enabled: enabled))
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: self.root)
    self.defaults.removePersistentDomain(forName: self.suiteName)
  }

  func model(acquisitionEnabled: Bool = true) -> LiveQuotaModel {
    let io = self.io
    return LiveQuotaModel(
      store: self.store, acquisitionEnabled: acquisitionEnabled, preferences: self.preferences,
      claudeAdapter: ClaudeAutomaticAdapter(
        reader: io, runner: io, cliExecutable: nil, resolveCLIOnRefresh: false,
        cliResolver: { io.resolve() },
        historyURL: self.root.appendingPathComponent("synthetic-history.json"),
        cacheURL: self.root.appendingPathComponent("synthetic-cache.json"),
        desktopConfigURL: self.root.appendingPathComponent("synthetic-config.json"),
        cliFallbackEnabled: false, ptyProbeEnabled: false, ptyProbe: io,
        probeDirectory: self.root.appendingPathComponent("synthetic-probe")))
  }

  func localSnapshot(remaining: Double, attemptedAt: Date? = nil) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .claude, source: .claudeDesktopHistory,
      capturedAt: self.now.addingTimeInterval(-60),
      weekly: QuotaWindow(remainingPercent: remaining, durationSeconds: 604_800, resetAt: nil),
      lastAttemptAt: attemptedAt ?? self.now, sourceState: .observationSucceeded)
  }

  func ingest(
    status: String = "ok", remaining: Double = 73, resetAfter: TimeInterval = 259_200,
    offset: TimeInterval, accountFingerprint: String = String(repeating: "a", count: 64)
  ) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var object: [String: Any] = [
      "schemaVersion": 1, "profileID": "10000000-0000-4000-8000-000000000001",
      "connectionID": "30000000-0000-4000-8000-000000000003",
      "sequence": Int(offset) + 301,
      "observedAt": formatter.string(from: self.now.addingTimeInterval(offset)), "status": status,
    ]
    if try self.browser.load() == nil {
      var handshake = object
      handshake["status"] = "connected"
      handshake["sequence"] = 0
      handshake["observedAt"] = formatter.string(from: self.now.addingTimeInterval(-300))
      try self.browser.ingest(JSONSerialization.data(withJSONObject: handshake), now: self.now)
    }
    if status == "ok" {
      object["accountFingerprint"] = accountFingerprint
      object["organizationFingerprint"] = String(repeating: "b", count: 64)
      object["principalFingerprint"] = String(repeating: "c", count: 64)
      object["weekly"] = [
        "remainingPercent": remaining,
        "resetAt": formatter.string(from: self.now.addingTimeInterval(resetAfter)),
      ]
      object["fiveHour"] = [
        "remainingPercent": 40,
        "resetAt": formatter.string(from: self.now.addingTimeInterval(3_600)),
      ]
    }
    try self.browser.ingest(JSONSerialization.data(withJSONObject: object), now: self.now)
  }
}

private final class BrowserAppIsolationStub: BoundedLocalDataReading, BoundedProcessRunning,
  ClaudeUsageProbing, @unchecked Sendable
{
  private let lock = NSLock()
  private var paths: [String] = []
  private var processes = 0
  private var probes = 0
  private var resolutions = 0

  var readPaths: [String] { self.lock.withLock { self.paths } }
  var readCount: Int { self.lock.withLock { self.paths.count } }
  var processCount: Int { self.lock.withLock { self.processes } }
  var probeCount: Int { self.lock.withLock { self.probes } }
  var resolverCount: Int { self.lock.withLock { self.resolutions } }

  func read(from url: URL, limit: Int) throws -> Data {
    self.lock.withLock { self.paths.append(url.path) }
    throw ClaudeAutomaticAdapterError.sourceUnavailable
  }

  func run(executable: URL, arguments: [String], stdin: Data, currentDirectory: URL?) throws
    -> BoundedProcessResult
  {
    self.lock.withLock { self.processes += 1 }
    throw BoundedProcessError.launchFailed
  }

  func capture(executable: URL, workingDirectory: URL) throws -> Data {
    self.lock.withLock { self.probes += 1 }
    throw ClaudeAutomaticAdapterError.sourceUnavailable
  }

  func resolve() -> URL? {
    self.lock.withLock { self.resolutions += 1 }
    return nil
  }
}
