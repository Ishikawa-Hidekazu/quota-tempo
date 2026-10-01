import AppKit
import Combine
import Foundation
import QuotaTempoCore

@testable import QuotaTempoDesktopCandidate

@MainActor
final class DesktopPreviewApplication: NSObject, NSApplicationDelegate {
  private let model: DesktopPreviewModel
  private var statusItem: NSStatusItem?
  private var previewMenu: DesktopPreviewMenu?
  private var subscriptions = Set<AnyCancellable>()
  private var wakeObserver: NSObjectProtocol?
  private var observedDates = Set<Date>()
  private let qa: Bool
  private var finishing = false

  init(
    service: any DesktopPreviewServing,
    qa: Bool,
    onResult: @escaping @MainActor @Sendable (DesktopUsageCandidateResult, FixtureScenario) -> Void
  ) {
    self.qa = qa
    model = DesktopPreviewModel(service: service, onResult: onResult)
    super.init()
  }

  static func run(
    service: any DesktopPreviewServing,
    qa: Bool,
    onResult: @escaping @MainActor @Sendable (DesktopUsageCandidateResult, FixtureScenario) -> Void
  ) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = DesktopPreviewApplication(service: service, qa: qa, onResult: onResult)
    app.delegate = delegate
    // Called from synchronous main. No activation, window or app replacement.
    app.run()
    withExtendedLifetime(delegate) {}
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.button?.toolTip = "QuotaTempo Desktop Preview"
    // The bounded acquisition QA permits only start/timer-driven refreshes.
    if !qa {
      let menu = DesktopPreviewMenu(
        onRefresh: { [weak self] in Task { await self?.model.refresh() } },
        onQuit: { [weak self] in self?.finish(code: 0) })
      previewMenu = menu
      item.menu = menu.menu
    }
    model.$scenario.combineLatest(model.$refreshing).sink { [weak self] scenario, refreshing in
      let title = MenuBarTitleFormatter.title(scenario: scenario, mode: .full) ?? "Claude"
      self?.statusItem?.button?.title = "QT Desktop | \(title)"
      self?.previewMenu?.update(scenario: scenario, refreshing: refreshing)
      self?.checkAutomaticUpdate(scenario)
    }.store(in: &subscriptions)
    if !qa {
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.model.refresh() }
      }
    }
    Task { await model.start() }
  }

  private func checkAutomaticUpdate(_ scenario: FixtureScenario) {
    guard qa, let snapshot = scenario.snapshots.first,
      snapshot.sourceState == .observationSucceeded,
      let capturedAt = snapshot.capturedAt,
      QuotaPlanner.evaluate(snapshot, now: scenario.now).vsTarget != nil
    else { return }
    observedDates.insert(capturedAt)
    guard observedDates.count >= 2, let first = observedDates.min(),
      let last = observedDates.max(), last.timeIntervalSince(first) >= 300
    else { return }
    print("{\"previewQA\":\"automatic_update_passed\",\"distinctObservations\":2}")
    finish(code: 0)
  }

  private func finish(code: Int32) {
    guard !finishing else { return }
    finishing = true
    previewMenu?.dismiss()
    // A synchronous system Keychain call cannot be cancelled by a Swift task.
    // Do not let an unresponsive reader prevent process termination.
    Task.detached {
      try? await Task.sleep(for: .seconds(3))
      print("{\"previewQA\":\"cleanup_deadline_exceeded\"}")
      exit(2)
    }
    Task {
      await model.stop()
      if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
      if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
      exit(code)
    }
  }
}
