import Foundation
import Testing

@testable import QuotaTempoApp
@testable import QuotaTempoCore

// Exercise the model only: no application, window, updater, browser or real provider is started.
@Suite("Claude browser application integration", .serialized)
@MainActor
struct ClaudeBrowserAppTests {
  @Test("Saved Desktop source is loaded before any local launch acquisition")
  func savedDesktopSkipsLocalStartup() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let previous = fixture.localSnapshot(remaining: 88)
    try fixture.store.save(previous)
    try fixture.ingest(remaining: 73, offset: -1)
    ClaudeSourcePreferences(defaults: fixture.defaults).save(.desktop)
    let model = fixture.model(liveProbes: true)
    #expect(model.claudeSource == .desktop)
    #expect(!model.allowsLocalClaude)
    #expect(model.scenario.snapshots.isEmpty)
    model.menuOpened()
    model.clockAdvanced()
    model.scheduledRefresh()
    model.systemDidWake()
    model.explicitRefresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.scenario.snapshots.isEmpty)
    #expect(try fixture.store.load(.claude) == previous)
    #expect(fixture.io.readCount == 0 && fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test(
    "Desktop selection cancels queued local and browser acquisition before connection",
    arguments: [false, true])
  func sourceSwitchCancelsQueuedAcquisition(browserConnected: Bool) async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let previous = fixture.localSnapshot(
      remaining: 41, attemptedAt: fixture.now.addingTimeInterval(-3_600))
    try fixture.store.save(previous)
    if browserConnected { try fixture.ingest(remaining: 73, offset: -1) }
    let queue = DispatchQueue(label: "ClaudeSource.Queued.\(UUID().uuidString)")
    let barrier = BrowserAppReadBarrier()
    defer { barrier.release() }
    queue.async { barrier.pause() }
    try await barrier.waitUntilEntered()
    let model = fixture.model(liveProbes: true, providerQueue: queue)
    #expect(model.refreshInFlight)
    model.explicitRefresh()
    model.setClaudeSource(.desktop)
    #expect(!model.allowsLocalClaude && model.scenario.snapshots.isEmpty)
    #expect(ClaudeSourcePreferences(defaults: fixture.defaults).load() == .desktop)
    barrier.release()
    try await waitFor(model) { model.scenario.snapshots.isEmpty }
    #expect(try fixture.store.load(.claude) == previous)
    #expect(fixture.io.readCount == 0 && fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test("Desktop switch rejects a late local result and discards the pending live request")
  func sourceSwitchRejectsLateLocalResult() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let previous = fixture.localSnapshot(remaining: 41)
    try fixture.store.save(previous)
    let model = fixture.model(liveProbes: true)
    try await waitFor(model) { true }
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    model.clockAdvanced()
    try await read.waitUntilEntered()
    model.explicitRefresh()
    model.setClaudeSource(.desktop)
    read.release()
    try await waitFor(model) { model.scenario.snapshots.isEmpty }
    #expect(try fixture.store.load(.claude) == previous)
    #expect(fixture.historyReadCount == 1 && fixture.io.resolverCount == 0)
    model.explicitRefresh()
    model.systemDidWake()
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.claudeSource == .desktop && model.scenario.snapshots.isEmpty)
    #expect(fixture.historyReadCount == 1 && fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test("Switching back permits exactly one fresh automatic generation")
  func sourceSwitchBackRefreshesOnce() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let previous = fixture.localSnapshot(remaining: 41)
    try fixture.store.save(previous)
    let model = fixture.model(liveProbes: true)
    try await waitFor(model) { true }
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let first = fixture.pauseNextHistoryRead()
    defer { first.release() }
    model.clockAdvanced()
    try await first.waitUntilEntered()
    model.explicitRefresh()
    model.setClaudeSource(.desktop)
    model.setClaudeSource(.automatic)
    model.setClaudeSource(.automatic)
    let second = fixture.pauseNextHistoryRead()
    defer { second.release() }
    first.release()
    try await second.waitUntilEntered()
    #expect(try fixture.store.load(.claude) == previous)
    try fixture.setHistory(remaining: 22, capturedAt: fixture.now.addingTimeInterval(-1))
    second.release()
    try await waitFor(model) {
      model.scenario.snapshots.first?.weekly?.remainingPercent == 22
    }
    #expect(fixture.historyReadCount == 2 && fixture.io.resolverCount == 1)
    #expect(ClaudeSourcePreferences(defaults: fixture.defaults).load() == .automatic)
    fixture.expectIsolated()
  }

  @Test("Exclusive Desktop integration never starts a CLI or imports browser values")
  func exclusiveDesktopSuppressesOtherAcquisition() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(remaining: 73, offset: -1)
    let model = fixture.model(liveProbes: true, localClaudeAcquisitionEnabled: false)
    model.menuOpened()
    model.clockAdvanced()
    model.scheduledRefresh()
    model.systemDidWake()
    model.explicitRefresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.probeCount == 0)
    #expect(fixture.io.resolverCount == 0)
    #expect(try fixture.store.load(.claude) == nil)
    #expect(!model.refreshInFlight)
  }

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

  @Test(
    "Silent browser expiry clears UI and persisted quotas without probing another account",
    arguments: ["ok", "unavailable", "rateLimited"])
  func silentBrowserExpiresInModel(status: String) async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let clock = BrowserAppClock(fixture.now)
    try fixture.ingest(remaining: 57, offset: -60)
    if status != "ok" { try fixture.ingest(status: status, offset: -1) }
    let bridgeBytes = try Data(contentsOf: fixture.browser.url)
    // A different local observation must not be consulted just because the browser goes silent.
    try fixture.setHistory(remaining: 99, capturedAt: fixture.now)
    let model = fixture.model(liveProbes: true, now: { clock.now })
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 57 }
    let captured = try #require(model.scenario.snapshots.first)

    clock.set(fixture.now.addingTimeInterval(840))
    model.clockAdvanced()
    try await self.waitFor(model) { model.scenario.now == clock.now }
    #expect(model.scenario.snapshots.first == captured)

    clock.set(fixture.now.addingTimeInterval(841))
    model.clockAdvanced()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly == nil }
    let expired = try #require(model.scenario.snapshots.first)
    #expect(expired.source == .claudeBrowser)
    #expect(expired.fiveHour == nil)
    #expect(expired.capturedAt == nil)
    #expect(expired.lastAttemptAt == captured.lastAttemptAt)
    #expect(expired.claudeAccountFingerprint == nil)
    #expect(expired.claudeOrganizationFingerprint == nil)
    #expect(expired.sourceState == .attemptFailed)
    #expect(expired.errorCode == (status == "rateLimited" ? .temporaryFailure : .sourceUnavailable))
    #expect(QuotaPlanner.evaluate(expired, now: clock.now).targetNow == nil)
    #expect(
      MenuBarTitleFormatter.title(scenario: model.scenario, mode: .full)?.contains("W57") != true)
    #expect(try fixture.store.load(.claude) == expired)

    // Manual force, wake, and restart cannot bypass a saved rate-limit/backoff state.
    model.explicitRefresh()
    try await self.waitFor(model) { true }
    model.systemDidWake()
    try await self.waitFor(model) { true }
    model.menuOpened()
    try await self.waitFor(model) { true }
    clock.set(fixture.now.addingTimeInterval(7_200))
    model.scheduledRefresh()
    try await self.waitFor(model) { model.scenario.now == clock.now }
    let restarted = fixture.model(liveProbes: true, now: { clock.now })
    try await self.waitFor(restarted) { restarted.scenario.snapshots.first?.weekly == nil }
    #expect(restarted.scenario.snapshots.first == expired)
    #expect(try Data(contentsOf: fixture.browser.url) == bridgeBytes)
    #expect(try fixture.browser.load()?.enabled == true)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()

    try fixture.ingest(remaining: 31, offset: 7_200, receivedAt: clock.now)
    restarted.clockAdvanced()
    try await self.waitFor(restarted) {
      restarted.scenario.snapshots.first?.weekly?.remainingPercent == 31
    }
    let recovered = try #require(restarted.scenario.snapshots.first)
    #expect(recovered.source == .claudeBrowser)
    #expect(recovered.capturedAt == clock.now)
    #expect(recovered.errorCode == nil)
    #expect(recovered.claudeAccountFingerprint == captured.claudeAccountFingerprint)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
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

  @Test("App disconnect works after silent extension removal and only reads local metadata")
  func appDisconnectAfterExtensionRemoval() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(remaining: 57, offset: -120)
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let model = fixture.model(liveProbes: true, now: { fixture.now })
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }
    await model.disconnectClaudeBrowser()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 37 }
    #expect(!model.browserDisconnectInFlight)
    #expect(!model.browserDisconnectFailed)
    #expect(try fixture.browser.load()?.enabled == false)
    let local = try #require(try fixture.store.load(.claude))
    #expect(local.source == .claudeDesktopHistory)
    #expect(local.weekly?.resetAt == nil)
    #expect(local.claudeAccountFingerprint == nil)
    #expect(local.claudeOrganizationFingerprint != String(repeating: "b", count: 64))
    #expect(local.fiveHour == nil)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
    let restarted = fixture.model(liveProbes: false)
    try await self.waitFor(restarted) {
      restarted.scenario.snapshots.first?.source != .claudeBrowser
    }
    #expect(restarted.scenario.snapshots.first?.weekly?.resetAt == nil)
  }

  @Test("A failed app disconnect reports failure without clearing the connected observation")
  func appDisconnectFailureIsVisible() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }
    let prior = model.scenario.snapshots.first
    let bytes = try Data(contentsOf: fixture.browser.url)
    let lock = fixture.browser.url.deletingLastPathComponent().appendingPathComponent("host.lock")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
    await model.disconnectClaudeBrowser()
    #expect(model.browserDisconnectFailed)
    #expect(!model.browserDisconnectInFlight)
    #expect(model.scenario.snapshots.first == prior)
    #expect(try Data(contentsOf: fixture.browser.url) == bytes)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test(
    "Disconnect invalidates an old in-flight refresh and drains only a local observation",
    arguments: [false, true])
  func disconnectInvalidatesPendingRefresh(live: Bool) async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    if live { model.explicitRefresh() } else { model.clockAdvanced() }
    try await read.waitUntilEntered()
    model.explicitRefresh()
    try fixture.ingest(remaining: 63, offset: -1)
    await model.disconnectClaudeBrowser()
    #expect(model.scenario.snapshots.first?.weekly == nil)
    read.release()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 37 }
    #expect(try fixture.browser.load()?.enabled == false)
    #expect(model.scenario.snapshots.first?.weekly?.resetAt == nil)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test("Disconnect cancels a live request queued before browser selection")
  func disconnectCancelsQueuedLiveRefresh() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let queue = DispatchQueue(label: "QuotaTempo.synthetic-blocked-provider")
    let model = fixture.model(liveProbes: true, providerQueue: queue)
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }
    let barrier = BrowserAppReadBarrier()
    defer { barrier.release() }
    queue.async { barrier.pause() }
    try await barrier.waitUntilEntered()
    model.explicitRefresh()
    await Task.yield()
    await model.disconnectClaudeBrowser()
    #expect(try fixture.browser.load()?.enabled == false)
    barrier.release()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 37 }
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test(
    "Revocation hides old persisted browser values after cleanup failure and an acquisition-disabled restart"
  )
  func disconnectCleanupFailureCannotResurrectAfterRestart() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    let old = try #require(fixture.browser.selectedSnapshot(now: fixture.now))
    try fixture.store.save(old)
    let failing = NormalizedSnapshotStore(
      directory: fixture.store.directory, writer: BrowserCleanupFailingWriter())
    let model = fixture.model(liveProbes: true, storeOverride: failing)
    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }
    await model.disconnectClaudeBrowser()
    try await self.waitFor(model) { model.browserDisconnectCleanupFailed }
    #expect(!model.browserDisconnectFailed)
    #expect(try fixture.browser.load()?.enabled == false)
    #expect(try fixture.store.load(.claude) == old)
    #expect(model.scenario.snapshots.first?.weekly == nil)
    let restarted = fixture.model(acquisitionEnabled: false, storeOverride: failing)
    #expect(restarted.scenario.snapshots.first?.weekly == nil)
    #expect(restarted.scenario.snapshots.first?.claudeAccountFingerprint == nil)
    #expect(restarted.scenario.snapshots.first?.source != .claudeBrowser)
    restarted.clockAdvanced()
    try await self.waitFor(restarted) { restarted.scenario.snapshots.first?.weekly == nil }
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test("Validating browser presentation does not hide a normalized write failure")
  func browserPresentationKeepsStorageFailure() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.ingest(offset: -60)
    let failing = NormalizedSnapshotStore(
      directory: fixture.store.directory, writer: BrowserCleanupFailingWriter())
    let model = fixture.model(storeOverride: failing)
    try await self.waitFor(model) {
      model.scenario.snapshots.first?.errorCode == .atomicWriteFailed
    }
    #expect(model.scenario.snapshots.first?.source == .claudeBrowser)
    #expect(model.scenario.snapshots.first?.weekly?.remainingPercent == 73)
    #expect(fixture.io.readCount == 0)
    fixture.expectIsolated()
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

  @Test("Minute ticks import Desktop history without CLI calls or postponing the live refresh")
  func minuteClockImportsLocalObservation() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 41 }
    let due = fixture.localSnapshot(
      remaining: 41, attemptedAt: fixture.now.addingTimeInterval(-3_600))
    try fixture.store.save(due)
    let capturedAt = fixture.now.addingTimeInterval(-10)
    try fixture.setHistory(remaining: 37, capturedAt: capturedAt)
    model.clockAdvanced()
    try await self.waitFor(model) {
      model.scenario.snapshots.first?.weekly?.remainingPercent == 37
    }
    let imported = try #require(try fixture.store.load(.claude))
    #expect(imported.capturedAt == capturedAt)
    #expect(imported.lastAttemptAt == due.lastAttemptAt)
    #expect(imported.weekly?.resetAt == nil)
    #expect(fixture.io.readCount > 0)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.probeCount == 0)
    #expect(fixture.io.resolverCount == 0)
    model.clockAdvanced()
    try await self.waitFor(model) { model.scenario.snapshots.first?.capturedAt == capturedAt }
    #expect(try fixture.store.load(.claude) == imported)
    model.scheduledRefresh()
    try await self.waitFor(model) { fixture.io.resolverCount == 1 }
    #expect(fixture.io.readPaths.allSatisfy { $0.hasPrefix(fixture.root.path + "/") })
  }

  @Test("New balance without a reset does not erase a prior live authentication failure")
  func minuteClockPreservesLiveFailure() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let failed = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopHistory,
      capturedAt: fixture.now.addingTimeInterval(-60),
      weekly: QuotaWindow(remainingPercent: 41, durationSeconds: 604_800, resetAt: nil),
      lastAttemptAt: fixture.now, sourceState: .attemptFailed, errorCode: .authenticationRequired)
    try fixture.store.save(failed)
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 41 }
    try fixture.setHistory(remaining: 36, capturedAt: fixture.now.addingTimeInterval(-10))
    model.clockAdvanced()
    try await self.waitFor(model) { model.scenario.snapshots.first?.weekly?.remainingPercent == 36 }
    let updated = try #require(try fixture.store.load(.claude))
    #expect(updated.lastAttemptAt == failed.lastAttemptAt)
    #expect(updated.sourceState == .attemptFailed)
    #expect(updated.errorCode == .authenticationRequired)
    #expect(updated.weekly?.resetAt == nil)
    #expect(fixture.io.processCount == 0)
    #expect(fixture.io.probeCount == 0)
    #expect(fixture.io.resolverCount == 0)
  }

  @Test(
    "Live requests behind a local read coalesce, and force cannot be downgraded",
    arguments: [false, true], [false, true])
  func localReadCoalescesLiveRefreshes(force: Bool, hasLocalChange: Bool) async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    let previous = fixture.localSnapshot(
      remaining: 41, attemptedAt: fixture.now.addingTimeInterval(force ? -60 : -3_600))
    try fixture.store.save(previous)
    let capturedAt = fixture.now.addingTimeInterval(-10)
    if hasLocalChange {
      try fixture.setHistory(remaining: 37, capturedAt: capturedAt)
    }
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    model.clockAdvanced()
    try await read.waitUntilEntered()

    model.scheduledRefresh()
    model.menuOpened()
    model.systemDidWake()
    if force {
      model.explicitRefresh()
      model.explicitRefresh()
    }
    model.scheduledRefresh()
    model.clockAdvanced()
    #expect(fixture.io.resolverCount == 0)
    read.release()

    try await self.waitFor(model) { fixture.io.resolverCount == 1 }
    let result = try #require(try fixture.store.load(.claude))
    #expect(result.weekly?.remainingPercent == (hasLocalChange ? 37 : 41))
    #expect(result.capturedAt == (hasLocalChange ? capturedAt : previous.capturedAt))
    #expect(result.sourceState == (hasLocalChange ? .observationSucceeded : .attemptFailed))
    #expect(try #require(result.lastAttemptAt) > #require(previous.lastAttemptAt))
    #expect(fixture.historyReadCount == 2)
    fixture.expectIsolated()
  }

  @Test("Draining a scheduled request still respects the live attempt interval")
  func pendingScheduledRefreshRespectsThrottle() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    let previous = fixture.localSnapshot(remaining: 41)
    try fixture.store.save(previous)
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    model.clockAdvanced()
    try await read.waitUntilEntered()
    model.scheduledRefresh()
    read.release()

    try await self.waitFor(model) { true }
    #expect(try fixture.store.load(.claude)?.lastAttemptAt == previous.lastAttemptAt)
    #expect(fixture.historyReadCount == 1)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test("Minute ticks and ordinary live triggers do not queue behind an active live attempt")
  func liveRefreshDropsMinuteTicks() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.store.save(
      fixture.localSnapshot(remaining: 41, attemptedAt: fixture.now.addingTimeInterval(-3_600)))
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    model.scheduledRefresh()
    try await read.waitUntilEntered()
    for _ in 0..<3 {
      model.clockAdvanced()
      model.scheduledRefresh()
      model.menuOpened()
      model.systemDidWake()
    }
    read.release()

    try await self.waitFor(model) { fixture.io.resolverCount == 1 }
    #expect(fixture.historyReadCount == 1)
    #expect(try fixture.store.load(.claude)?.sourceState == .attemptFailed)
    fixture.expectIsolated()
  }

  @Test("Manual force upgrades an active ordinary live attempt only once, even after failure")
  func manualForceUpgradesActiveLiveRefresh() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.store.save(
      fixture.localSnapshot(remaining: 41, attemptedAt: fixture.now.addingTimeInterval(-3_600)))
    let first = fixture.pauseNextHistoryRead()
    defer { first.release() }
    model.scheduledRefresh()
    try await first.waitUntilEntered()
    model.explicitRefresh()
    model.explicitRefresh()
    model.scheduledRefresh()
    let forced = fixture.pauseNextHistoryRead()
    defer { forced.release() }
    first.release()
    try await forced.waitUntilEntered()
    #expect(model.refreshInFlight)
    #expect(fixture.io.resolverCount == 1)
    for _ in 0..<3 {
      model.explicitRefresh()
      model.scheduledRefresh()
      model.clockAdvanced()
    }
    forced.release()

    try await self.waitFor(model) { fixture.io.resolverCount == 2 }
    #expect(fixture.historyReadCount == 2)
    #expect(try fixture.store.load(.claude)?.sourceState == .attemptFailed)
    fixture.expectIsolated()
  }

  @Test("A pending live request is discarded when Claude is disabled before drain")
  func pendingRefreshRechecksProviderSelection() async throws {
    let fixture = try BrowserAppFixture(enabled: [.claude, .codex])
    defer { fixture.cleanup() }
    // Keep the non-injected Codex adapter behind its recent-attempt guard.
    let codex = ProviderSnapshot(
      provider: .codex, source: .codexAppServer, capturedAt: fixture.now,
      weekly: QuotaWindow(
        remainingPercent: 90, durationSeconds: 604_800,
        resetAt: fixture.now.addingTimeInterval(259_200)),
      lastAttemptAt: fixture.now, sourceState: .observationSucceeded)
    try fixture.store.save(codex)
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.store.save(
      fixture.localSnapshot(remaining: 41, attemptedAt: fixture.now.addingTimeInterval(-3_600)))
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    model.clockAdvanced()
    try await read.waitUntilEntered()
    model.scheduledRefresh()
    model.setProviderEnabled(.claude, enabled: false)
    read.release()

    try await self.waitFor(model) { model.scenario.snapshots.map(\.provider) == [.codex] }
    #expect(model.enabledProviders == [.codex])
    #expect(try fixture.store.load(.codex) == codex)
    #expect(fixture.historyReadCount == 1)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test("A browser connection arriving before drain remains exclusive over a forced request")
  func pendingRefreshRechecksBrowserSource() async throws {
    let fixture = try BrowserAppFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(fixture.localSnapshot(remaining: 41))
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    model.clockAdvanced()
    try await read.waitUntilEntered()
    model.explicitRefresh()
    try fixture.ingest(remaining: 63, offset: -1)
    read.release()

    try await self.waitFor(model) { model.scenario.snapshots.first?.source == .claudeBrowser }
    #expect(try fixture.store.load(.claude)?.weekly?.remainingPercent == 63)
    #expect(fixture.historyReadCount == 1)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test(
    "Turning Claude off cancels queued work before any source is acquired",
    arguments: [false, true])
  func disabledQueuedRefreshDoesNotAcquire(browserConnected: Bool) async throws {
    let fixture = try BrowserAppFixture(enabled: [.claude, .codex])
    defer { fixture.cleanup() }
    try fixture.saveRecentCodex()
    let previous = fixture.localSnapshot(
      remaining: 41, attemptedAt: fixture.now.addingTimeInterval(-3_600))
    try fixture.store.save(previous)
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    if browserConnected { try fixture.ingest(remaining: 63, offset: -1) }
    let queue = DispatchQueue(label: "ClaudeBrowserAppTests.queued.\(UUID().uuidString)")
    let barrier = BrowserAppReadBarrier()
    defer { barrier.release() }
    queue.async { barrier.pause() }
    try await barrier.waitUntilEntered()
    let model = fixture.model(liveProbes: true, providerQueue: queue)
    #expect(model.refreshInFlight)
    model.setProviderEnabled(.claude, enabled: false)
    barrier.release()

    try await self.waitFor(model) { model.scenario.snapshots.map(\.provider) == [.codex] }
    #expect(try fixture.store.load(.claude) == previous)
    #expect(fixture.io.readCount == 0)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test("Turning Claude off rejects a completed local read and clears its pending request")
  func disabledInFlightRefreshDoesNotPersist() async throws {
    let fixture = try BrowserAppFixture(enabled: [.claude, .codex])
    defer { fixture.cleanup() }
    try fixture.saveRecentCodex()
    let previous = fixture.localSnapshot(remaining: 41)
    try fixture.store.save(previous)
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let read = fixture.pauseNextHistoryRead()
    defer { read.release() }
    model.clockAdvanced()
    try await read.waitUntilEntered()
    model.scheduledRefresh()
    model.setProviderEnabled(.claude, enabled: false)
    read.release()

    try await self.waitFor(model) { model.scenario.snapshots.map(\.provider) == [.codex] }
    #expect(try fixture.store.load(.claude) == previous)
    #expect(fixture.historyReadCount == 1)
    #expect(fixture.io.resolverCount == 0)
    fixture.expectIsolated()
  }

  @Test(
    "Off/on rejects the old result but permits exactly one newly authorized refresh",
    arguments: [false, true])
  func reenabledClaudeDoesNotAcceptCancelledResult(forcedLive: Bool) async throws {
    let fixture = try BrowserAppFixture(enabled: [.claude, .codex])
    defer { fixture.cleanup() }
    try fixture.saveRecentCodex()
    let previous = fixture.localSnapshot(remaining: 41)
    try fixture.store.save(previous)
    let model = fixture.model(liveProbes: true)
    try await self.waitFor(model) { true }
    try fixture.setHistory(remaining: 37, capturedAt: fixture.now.addingTimeInterval(-10))
    let first = fixture.pauseNextHistoryRead()
    defer { first.release() }
    if forcedLive {
      model.setProviderEnabled(.claude, enabled: false)
      model.setProviderEnabled(.claude, enabled: true)
    } else {
      model.clockAdvanced()
    }
    try await first.waitUntilEntered()
    model.setProviderEnabled(.claude, enabled: false)
    model.setProviderEnabled(.claude, enabled: true)
    let second = fixture.pauseNextHistoryRead()
    defer { second.release() }
    first.release()
    try await second.waitUntilEntered()
    #expect(try fixture.store.load(.claude) == previous)

    try fixture.setHistory(remaining: 22, capturedAt: fixture.now.addingTimeInterval(-1))
    second.release()
    try await self.waitFor(model) {
      model.scenario.snapshots.first(where: { $0.provider == .claude })?.weekly?.remainingPercent
        == 22
    }
    #expect(try fixture.store.load(.claude)?.weekly?.remainingPercent == 22)
    #expect(fixture.historyReadCount == 2)
    #expect(fixture.io.resolverCount == 1)
    fixture.expectIsolated()
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

  func model(
    acquisitionEnabled: Bool = true, liveProbes: Bool = false,
    now: @escaping @Sendable () -> Date = { Date() },
    storeOverride: NormalizedSnapshotStore? = nil, providerQueue: DispatchQueue? = nil,
    localClaudeAcquisitionEnabled: Bool = true
  ) -> LiveQuotaModel {
    let io = self.io
    return LiveQuotaModel(
      store: storeOverride ?? self.store, acquisitionEnabled: acquisitionEnabled,
      preferences: self.preferences,
      claudeAdapter: ClaudeAutomaticAdapter(
        reader: io, runner: io, cliExecutable: nil, resolveCLIOnRefresh: liveProbes,
        cliResolver: { io.resolve() },
        historyURL: self.root.appendingPathComponent("synthetic-history.json"),
        cacheURL: self.root.appendingPathComponent("synthetic-cache.json"),
        desktopConfigURL: self.root.appendingPathComponent("synthetic-config.json"),
        cliFallbackEnabled: liveProbes, ptyProbeEnabled: liveProbes, ptyProbe: io,
        probeDirectory: self.root.appendingPathComponent("synthetic-probe")), now: now,
      providerQueue: providerQueue, localClaudeAcquisitionEnabled: localClaudeAcquisitionEnabled,
      sourcePreferences: ClaudeSourcePreferences(defaults: defaults))
  }

  func setHistory(remaining: Double, capturedAt: Date) throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(capturedAt.timeIntervalSince1970 * 1_000),
          "org": "synthetic-org", "u": ["sd": 100 - remaining],
        ]
      ]
    ])
    self.io.setData(data, for: self.root.appendingPathComponent("synthetic-history.json"))
  }

  func saveRecentCodex() throws {
    try store.save(
      ProviderSnapshot(
        provider: .codex, source: .codexAppServer, capturedAt: now,
        weekly: QuotaWindow(
          remainingPercent: 90, durationSeconds: 604_800,
          resetAt: now.addingTimeInterval(259_200)),
        lastAttemptAt: now, sourceState: .observationSucceeded))
  }

  var historyReadCount: Int {
    self.io.readPaths.filter {
      $0 == self.root.appendingPathComponent("synthetic-history.json").path
    }
    .count
  }

  func pauseNextHistoryRead() -> BrowserAppReadBarrier {
    self.io.pauseNextRead(from: self.root.appendingPathComponent("synthetic-history.json"))
  }

  func expectIsolated() {
    #expect(self.io.readPaths.allSatisfy { $0.hasPrefix(self.root.path + "/") })
    #expect(self.io.processCount == 0)
    #expect(self.io.probeCount == 0)
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
    offset: TimeInterval, accountFingerprint: String = String(repeating: "a", count: 64),
    receivedAt: Date? = nil
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
        "resetAt": formatter.string(from: (receivedAt ?? self.now).addingTimeInterval(3_600)),
      ]
    }
    try self.browser.ingest(
      JSONSerialization.data(withJSONObject: object), now: receivedAt ?? self.now)
  }
}

private struct BrowserCleanupFailingWriter: AtomicDataWriting {
  func write(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteUnknown) }
}

private final class BrowserAppClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

  var now: Date { self.lock.withLock { self.date } }

  func set(_ date: Date) { self.lock.withLock { self.date = date } }
}

private final class BrowserAppIsolationStub: BoundedLocalDataReading, BoundedProcessRunning,
  ClaudeUsageProbing, @unchecked Sendable
{
  private let lock = NSLock()
  private var paths: [String] = []
  private var processes = 0
  private var probes = 0
  private var resolutions = 0
  private var data: [URL: Data] = [:]
  private var readBarriers: [URL: BrowserAppReadBarrier] = [:]

  var readPaths: [String] { self.lock.withLock { self.paths } }
  var readCount: Int { self.lock.withLock { self.paths.count } }
  var processCount: Int { self.lock.withLock { self.processes } }
  var probeCount: Int { self.lock.withLock { self.probes } }
  var resolverCount: Int { self.lock.withLock { self.resolutions } }

  func read(from url: URL, limit: Int) throws -> Data {
    let barrier = self.lock.withLock {
      self.paths.append(url.path)
      return self.readBarriers.removeValue(forKey: url)
    }
    barrier?.pause()
    return try self.lock.withLock {
      guard let value = self.data[url] else { throw ClaudeAutomaticAdapterError.sourceUnavailable }
      return value
    }
  }

  func pauseNextRead(from url: URL) -> BrowserAppReadBarrier {
    let barrier = BrowserAppReadBarrier()
    self.lock.withLock { self.readBarriers[url] = barrier }
    return barrier
  }

  func setData(_ value: Data, for url: URL) {
    self.lock.withLock { self.data[url] = value }
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

private final class BrowserAppReadBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private let signal = DispatchSemaphore(value: 0)
  private var entered = false

  func pause() {
    self.lock.withLock { self.entered = true }
    #expect(self.signal.wait(timeout: .now() + 5) == .success, "Synthetic read was not released")
  }

  func release() {
    self.signal.signal()
  }

  @MainActor
  func waitUntilEntered() async throws {
    for _ in 0..<300 {
      if self.lock.withLock({ self.entered }) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(self.lock.withLock { self.entered }, "Synthetic read did not start")
  }
}
