import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuotaTempoApp
@testable import QuotaTempoCore

#if DESKTOP_INTEGRATION_PREVIEW
  @testable import QuotaTempoDesktopCandidate
#endif

private let hostingInstant = Date(timeIntervalSince1970: 1_900_000_000)

@Suite("Retained application content", .serialized)
@MainActor
struct ApplicationContentObservationTests {
  @Test("A retained hosting root reads updated and cleared quota values")
  func retainedRootReadsLiveState() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "QuotaTempo.HostingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: path)
      defaults.removePersistentDomain(forName: suite)
    }
    let store = NormalizedSnapshotStore(directory: path)
    let model = LiveQuotaModel(store: store, acquisitionEnabled: false, now: { hostingInstant })
    let settings = QuotaTempoSettingsModel(loginItemService: UnavailableLoginItemService())
    let presentation = QuotaTempoPresentationModel(defaults: defaults)
    let delegate = QuotaTempoApplicationDelegate()
    let updater = QuotaTempoUpdater(enabled: false)
    #if DESKTOP_INTEGRATION_PREVIEW
      let desktop = DesktopConnectionController(
        clock: { hostingInstant.addingTimeInterval(11) }, makeService: { HostingDesktopStub() },
        repairStore: { _ in .notNeeded },
        consentStore: DesktopConnectionConsentPreferences(defaults: defaults))
      let root = QuotaTempoApplicationContent(
        model: model, settings: settings, presentation: presentation, desktopConnection: desktop,
        appDelegate: delegate, productVersion: "synthetic", updater: updater,
        maximumViewportHeight: nil, providerDisabled: false, onRefresh: {}, onQuit: {},
        renderNow: { hostingInstant.addingTimeInterval(11) })
    #else
      let root = QuotaTempoApplicationContent(
        model: model, settings: settings, presentation: presentation,
        appDelegate: delegate, productVersion: "synthetic", updater: updater,
        maximumViewportHeight: nil, providerDisabled: false, onRefresh: {}, onQuit: {})
    #endif
    // No window, activation, provider I/O, updater or real preference domain.
    let hosting = NSHostingController(rootView: root)
    for remaining: Double? in [73, 21, nil] {
      try store.save(
        ProviderSnapshot(
          provider: .codex, source: .codexAppServer, capturedAt: hostingInstant,
          weekly: remaining.map {
            QuotaWindow(remainingPercent: $0, durationSeconds: 604_800, resetAt: nil)
          }))
      model.clockAdvanced()
      for _ in 0..<100 {
        if model.scenario.snapshots.first(where: { $0.provider == .codex })?.weekly?
          .remainingPercent == remaining
        {
          break
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(
        hosting.rootView.scenario.snapshots.first(where: { $0.provider == .codex })?.weekly?
          .remainingPercent == remaining)
    }
    #if DESKTOP_INTEGRATION_PREVIEW
      let heldControls = hosting.rootView.desktopConnectionControls
      #expect(heldControls.allowsConnection())
      await desktop.connect(localExperimentAuthorized: true)
      #expect(
        hosting.rootView.scenario.snapshots.first(where: { $0.provider == .claude })?.weekly?
          .remainingPercent == 81)
      let current = hosting.rootView.scenario
      let snapshot = try #require(current.snapshots.first(where: { $0.provider == .claude }))
      #expect(model.scenario.now == hostingInstant)
      #expect(snapshot.capturedAt == hostingInstant.addingTimeInterval(10))
      let plan = QuotaPlanner.evaluate(snapshot, now: current.now)
      #expect(plan.weeklyRemaining == 81 && plan.targetNow != nil && plan.vsTarget != nil)
      await desktop.disconnect()
      #expect(
        hosting.rootView.scenario.snapshots.first(where: { $0.provider == .claude })?.weekly == nil)
      await desktop.connect(localExperimentAuthorized: true)
      #expect(try DesktopConnectionConsentPreferences(defaults: defaults).isAccepted())
      hosting.rootView.setProviderEnabled(.claude, enabled: false)
      #expect(!desktop.isConnected && desktop.snapshot == nil)
      #expect(try !DesktopConnectionConsentPreferences(defaults: defaults).isAccepted())
      #expect(!heldControls.allowsConnection())
      #expect(!hosting.rootView.scenario.snapshots.contains(where: { $0.provider == .claude }))
      hosting.rootView.setProviderEnabled(.claude, enabled: true)
      #expect(heldControls.allowsConnection())
      await desktop.resumeIfConsented(acquisitionAllowed: true)
      #expect(!desktop.isConnected)
      await desktop.disconnect()
    #endif
  }
}

#if DESKTOP_INTEGRATION_PREVIEW
  private actor HostingDesktopStub: DesktopConnectionServing {
    func setApproval(_ approval: DesktopAccessApproval) {}
    func prepareForOfflineRepair() -> Bool { true }
    func recheckConnection() -> DesktopUsageCandidateResult { refresh() }
    func refresh() -> DesktopUsageCandidateResult {
      DesktopUsageCandidateResult(
        disposition: .replaceDisplay, state: .current,
        observation: DesktopUsageObservation(
          owner: DesktopUsageOwner(
            accountFingerprint: String(repeating: "a", count: 64),
            organizationFingerprint: String(repeating: "b", count: 64)),
          capturedAt: hostingInstant.addingTimeInterval(10),
          values: DesktopUsageValues(
            weekly: QuotaWindow(
              remainingPercent: 81, durationSeconds: 604_800,
              resetAt: hostingInstant.addingTimeInterval(300_000)), fiveHour: nil)),
        credentialError: nil, nextAllowedAt: hostingInstant.addingTimeInterval(300))
    }
  }
#endif
