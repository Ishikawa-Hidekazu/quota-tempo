import Combine
import Foundation
import QuotaTempoCore

protocol DesktopPreviewServing: Sendable {
  func setApproval(_ approval: DesktopAccessApproval) async
  func refresh() async -> DesktopUsageCandidateResult
}

extension DesktopUsageCandidateService: DesktopPreviewServing {}

// Local preview only. A single service owns backoff and credential refusals for
// its entire lifetime; menu openings and manual refresh never replace it.
@MainActor
final class DesktopPreviewModel: ObservableObject {
  @Published private(set) var scenario: FixtureScenario
  @Published private(set) var refreshing = false
  @Published private(set) var state = DesktopUsageState.consentRequired
  private(set) var isRunning = false
  private let service: any DesktopPreviewServing
  private let clock: @Sendable () -> Date
  private let interval: Duration
  private let displayInterval: Duration
  private let onResult: @MainActor (DesktopUsageCandidateResult, FixtureScenario) -> Void
  private var loop: Task<Void, Never>?
  private var displayLoop: Task<Void, Never>?
  private var generation = UUID()
  private var lastResult: DesktopUsageCandidateResult?

  init(
    service: any DesktopPreviewServing = DesktopUsageCandidateService(),
    clock: @escaping @Sendable () -> Date = Date.init,
    interval: Duration = .seconds(30),
    displayInterval: Duration = .seconds(1),
    onResult: @escaping @MainActor (DesktopUsageCandidateResult, FixtureScenario) -> Void = {
      _, _ in
    }
  ) {
    self.service = service
    self.clock = clock
    self.interval = interval
    self.displayInterval = displayInterval
    self.onResult = onResult
    scenario = Self.empty(now: clock())
  }

  func start() async {
    guard !isRunning else { return }
    isRunning = true
    generation = UUID()
    let expected = generation
    await service.setApproval(
      DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true))
    guard isRunning, generation == expected else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard self?.isRunning == true, self?.generation == expected else { return }
        await self?.refresh()
        guard let interval = self?.interval else { return }
        do { try await Task.sleep(for: interval) } catch { return }
      }
    }
    let displayInterval = self.displayInterval
    displayLoop = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: displayInterval) } catch { return }
        guard self?.isRunning == true, self?.generation == expected else { return }
        self?.refreshDisplay()
      }
    }
  }

  func refresh() async {
    guard isRunning, !Task.isCancelled else { return }
    refreshDisplay()
    guard !refreshing else { return }
    let expected = generation
    refreshing = true
    defer { if generation == expected { refreshing = false } }
    let result = await service.refresh()
    guard generation == expected, isRunning, !Task.isCancelled else { return }
    guard result.disposition == .replaceDisplay else { return }
    lastResult = result
    state = result.state
    apply(result)
    onResult(result, scenario)
  }

  func stop() async {
    isRunning = false
    generation = UUID()
    loop?.cancel()
    loop = nil
    displayLoop?.cancel()
    displayLoop = nil
    refreshing = false
    lastResult = nil
    state = .consentRequired
    scenario = Self.empty(now: clock())
    await service.setApproval(DesktopAccessApproval())
  }

  // Display expiry must not wait for credential reads or network completion.
  // A tick is not an acquisition result and must not notify onResult.
  private func refreshDisplay() {
    if let lastResult { apply(lastResult) }
  }

  private func apply(_ result: DesktopUsageCandidateResult) {
    let now = clock()
    guard let snapshot = DesktopPreviewPresentation.snapshot(result, now: now) else { return }
    scenario = FixtureScenario(id: "desktop-local-preview", now: now, snapshots: [snapshot])
  }

  private static func empty(now: Date) -> FixtureScenario {
    FixtureScenario(
      id: "desktop-local-preview", now: now,
      snapshots: [
        ProviderSnapshot(
          provider: .claude, source: .claudeDesktopDirect, capturedAt: nil, weekly: nil,
          sourceState: .neverObserved)
      ])
  }

  deinit {
    loop?.cancel()
    displayLoop?.cancel()
  }
}
