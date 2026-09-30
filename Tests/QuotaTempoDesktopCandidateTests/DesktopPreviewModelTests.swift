import Foundation
import QuotaTempoCore
import Testing

@testable import QuotaTempoDesktopCandidate

private let previewNow = Date(timeIntervalSince1970: 1_900_000_000)

private func previewResult(
  _ remaining: Double = 81, resetAt: Date = previewNow.addingTimeInterval(400_000)
) -> DesktopUsageCandidateResult {
  DesktopUsageCandidateResult(
    disposition: .replaceDisplay, state: .current,
    observation: DesktopUsageObservation(
      owner: DesktopUsageOwner(
        accountFingerprint: String(repeating: "a", count: 64),
        organizationFingerprint: String(repeating: "b", count: 64)),
      capturedAt: previewNow,
      values: DesktopUsageValues(
        weekly: QuotaWindow(
          remainingPercent: remaining, durationSeconds: 604_800,
          resetAt: resetAt), fiveHour: nil)),
    credentialError: nil, nextAllowedAt: nil)
}

private final class PreviewClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = previewNow

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

private actor PreviewServiceStub: DesktopPreviewServing {
  private(set) var approvals: [DesktopAccessApproval] = []
  private(set) var calls = 0
  private var replies: [DesktopUsageCandidateResult]
  private var blocked: Bool
  private var continuation: CheckedContinuation<Void, Never>?

  init(replies: [DesktopUsageCandidateResult] = [previewResult()], blocked: Bool = false) {
    self.replies = replies
    self.blocked = blocked
  }
  func setApproval(_ approval: DesktopAccessApproval) { approvals.append(approval) }
  func refresh() async -> DesktopUsageCandidateResult {
    calls += 1
    if blocked { await withCheckedContinuation { continuation = $0 } }
    return replies.count > 1 ? replies.removeFirst() : replies[0]
  }
  func block() { blocked = true }
  func release() {
    blocked = false
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
  for _ in 0..<200 {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Preview did not reach the expected state within one second")
}

@Suite("Desktop local preview model")
@MainActor
struct DesktopPreviewModelTests {
  @Test func initializationAndRefreshBeforeStartAreInert() async {
    let service = PreviewServiceStub()
    let model = DesktopPreviewModel(service: service, clock: { previewNow })
    await model.refresh()
    #expect(await service.calls == 0)
    #expect(await service.approvals.isEmpty)
    #expect(model.scenario.snapshots.first?.weekly == nil)
  }

  @Test func timerPublishesWithoutOpeningAMenuAndStartIsIdempotent() async throws {
    let service = PreviewServiceStub(replies: [previewResult(81), previewResult(80)])
    let model = DesktopPreviewModel(
      service: service, clock: { previewNow }, interval: .milliseconds(10))
    await model.start()
    await model.start()
    try await eventually { model.scenario.snapshots.first?.weekly?.remainingPercent == 80 }
    #expect(await service.calls >= 2)
    #expect(await service.approvals.count == 1)
    #expect(await service.approvals.first?.localExperimentAuthorized == true)
    #expect(await service.approvals.first?.providerApproved == false)
    let snapshot = try #require(model.scenario.snapshots.first)
    let plan = QuotaPlanner.evaluate(snapshot, now: previewNow)
    #expect(plan.targetNow != nil)
    #expect(plan.vsTarget != nil)
    #expect(snapshot.source == .claudeDesktopDirect)
    await model.stop()
  }

  @Test func concurrentRefreshesDoNotOverlap() async throws {
    let service = PreviewServiceStub(blocked: true)
    let model = DesktopPreviewModel(service: service, clock: { previewNow })
    await model.start()
    try await eventually { await service.calls == 1 }
    await model.refresh()
    await model.refresh()
    #expect(await service.calls == 1)
    await service.release()
    try await eventually { !model.refreshing }
    await model.stop()
  }

  @Test func stopRevokesConsentAndDiscardsLateResults() async throws {
    let service = PreviewServiceStub(blocked: true)
    let model = DesktopPreviewModel(service: service, clock: { previewNow })
    await model.start()
    try await eventually { await service.calls == 1 }
    await model.stop()
    await service.release()
    try await Task.sleep(for: .milliseconds(30))
    #expect(!model.isRunning)
    #expect(!model.refreshing)
    #expect(model.scenario.snapshots.first?.weekly == nil)
    #expect(await service.approvals.last?.allowsAccess == false)
    await model.refresh()
    #expect(await service.calls == 1)
  }

  @Test func stopCancelsTheAutomaticLoop() async throws {
    let service = PreviewServiceStub()
    let model = DesktopPreviewModel(
      service: service, clock: { previewNow }, interval: .milliseconds(10))
    await model.start()
    try await eventually { await service.calls >= 2 }
    await model.stop()
    let calls = await service.calls
    try await Task.sleep(for: .milliseconds(40))
    #expect(await service.calls == calls)
    #expect(model.scenario.snapshots.first?.weekly == nil)
  }

  @Test func unchangedInFlightDoesNotEraseTheDisplay() async throws {
    let unchanged = DesktopUsageCandidateResult(
      disposition: .unchangedInFlight, state: .requesting, observation: nil,
      credentialError: nil, nextAllowedAt: nil)
    let service = PreviewServiceStub(replies: [previewResult(), unchanged])
    let model = DesktopPreviewModel(service: service, clock: { previewNow })
    await model.start()
    try await eventually { model.scenario.snapshots.first?.weekly != nil }
    await model.refresh()
    #expect(model.scenario.snapshots.first?.weekly?.remainingPercent == 81)
    #expect(!model.refreshing)
    await model.stop()
  }

  @Test func terminalFailureClearsPreviouslyVisibleValues() async throws {
    let refused = DesktopUsageCandidateResult(
      disposition: .replaceDisplay, state: .waitingForDesktopRenewal, observation: nil,
      credentialError: nil, nextAllowedAt: nil)
    let service = PreviewServiceStub(replies: [previewResult(), refused])
    let model = DesktopPreviewModel(service: service, clock: { previewNow })
    await model.start()
    try await eventually { model.scenario.snapshots.first?.weekly != nil }
    await model.refresh()
    #expect(model.scenario.snapshots.first?.weekly == nil)
    #expect(model.scenario.snapshots.first?.errorCode == .authenticationRequired)
    await model.stop()
  }

  @Test func displayTickAdvancesWithoutAcquisitionOrResultNotification() async throws {
    let clock = PreviewClock()
    let service = PreviewServiceStub()
    var resultCount = 0
    let model = DesktopPreviewModel(
      service: service, clock: { clock.now() }, interval: .seconds(3600),
      displayInterval: .milliseconds(10), onResult: { _, _ in resultCount += 1 })
    await model.start()
    await model.start()
    try await eventually { resultCount == 1 }
    clock.advance(by: 60)
    try await eventually { model.scenario.now == previewNow.addingTimeInterval(60) }
    #expect(model.scenario.snapshots.first?.capturedAt == previewNow)
    #expect(model.scenario.snapshots.first?.weekly?.remainingPercent == 81)
    #expect(
      model.scenario.snapshots.first?.weekly?.resetAt == previewNow.addingTimeInterval(400_000))
    #expect(model.state == .current)
    #expect(!model.refreshing)
    #expect(await service.calls == 1)
    #expect(await service.approvals.count == 1)
    #expect(resultCount == 1)
    await model.stop()
  }

  @Test(arguments: [false, true])
  func displayTickExpiresValuesWhileRefreshIsBlocked(resetExpires: Bool) async throws {
    let clock = PreviewClock()
    let resetAt = previewNow.addingTimeInterval(resetExpires ? 60 : 400_000)
    let service = PreviewServiceStub(replies: [previewResult(resetAt: resetAt)])
    var resultCount = 0
    let model = DesktopPreviewModel(
      service: service, clock: { clock.now() }, interval: .seconds(3600),
      displayInterval: .milliseconds(10), onResult: { _, _ in resultCount += 1 })
    await model.start()
    try await eventually { resultCount == 1 }
    await service.block()
    let pending = Task { await model.refresh() }
    try await eventually { await service.calls == 2 }
    #expect(model.refreshing)
    clock.advance(by: resetExpires ? 60 : 900)
    try await eventually { model.scenario.snapshots.first?.weekly == nil }
    #expect(model.scenario.now == clock.now())
    #expect(model.scenario.snapshots.first?.capturedAt == nil)
    #expect(model.scenario.snapshots.first?.fiveHour == nil)
    #expect(model.refreshing)
    #expect(await service.calls == 2)
    #expect(resultCount == 1)
    await model.refresh()
    #expect(await service.calls == 2)
    await service.release()
    await pending.value
    #expect(!model.refreshing)
    #expect(model.scenario.snapshots.first?.weekly == nil)
    await model.stop()
  }

  @Test func stopCancelsDisplayTicksAndRejectsPendingResults() async throws {
    let clock = PreviewClock()
    let service = PreviewServiceStub()
    var resultCount = 0
    let model = DesktopPreviewModel(
      service: service, clock: { clock.now() }, interval: .seconds(3600),
      displayInterval: .milliseconds(10), onResult: { _, _ in resultCount += 1 })
    await model.start()
    try await eventually { resultCount == 1 }
    await service.block()
    let pending = Task { await model.refresh() }
    try await eventually { await service.calls == 2 }
    await model.stop()
    let stopped = model.scenario
    clock.advance(by: 60)
    await service.release()
    await pending.value
    try await Task.sleep(for: .milliseconds(40))
    #expect(model.scenario == stopped)
    #expect(model.scenario.snapshots.first?.weekly == nil)
    #expect(!model.isRunning)
    #expect(!model.refreshing)
    #expect(model.state == .consentRequired)
    #expect(await service.calls == 2)
    #expect(await service.approvals.last?.allowsAccess == false)
    #expect(resultCount == 1)
  }
}
