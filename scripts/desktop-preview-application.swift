import AppKit
import Combine
import Foundation
import QuotaTempoCore
import SwiftUI

@testable import QuotaTempoDesktopCandidate

@MainActor
final class DesktopPreviewApplication: NSObject, NSApplicationDelegate {
  private let model: DesktopPreviewModel
  private let preferences = DesktopPreviewPreferences()
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
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
    // No activation, initial window, login item, persistent settings or app replacement.
    app.run()
    withExtendedLifetime(delegate) {}
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.button?.target = self
    // The bounded acceptance run permits only start/timer-driven acquisitions.
    item.button?.action = qa ? nil : #selector(togglePopover)
    item.button?.toolTip = "QuotaTempo Desktop Preview"
    popover.behavior = .transient
    popover.animates = false
    let content = DesktopPreviewContent(
      model: model, preferences: preferences, onQuit: { [weak self] in self?.quit() })
    popover.contentViewController = NSHostingController(rootView: content)
    model.$scenario.combineLatest(preferences.$displayMode).sink { [weak self] scenario, mode in
      let title = MenuBarTitleFormatter.title(scenario: scenario, mode: mode) ?? "Claude"
      self?.statusItem?.button?.title = "QT Desktop | \(title)"
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

  @objc private func togglePopover() {
    guard !qa else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = statusItem?.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      Task { await model.refresh() }
    }
  }

  private func quit() {
    finish(code: 0)
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
    popover.performClose(nil)
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

  // Synthetic, offscreen views only. This path never constructs a service or
  // accesses Desktop, Keychain, browser state, or a network transport.
  static func renderFixtures() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      .appendingPathComponent("preview-qa", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for language in ["en", "ja"] {
      for failed in [false, true] {
        let snapshot = ProviderSnapshot(
          provider: .claude, source: .claudeDesktopDirect,
          capturedAt: failed ? nil : now,
          weekly: failed
            ? nil
            : QuotaWindow(
              remainingPercent: 81, durationSeconds: 604_800,
              resetAt: now.addingTimeInterval(400_000)),
          sourceState: failed ? .attemptFailed : .observationSucceeded,
          errorCode: failed ? .authenticationRequired : nil)
        let view = QuotaMenuView(
          scenario: FixtureScenario(
            id: "synthetic-desktop-preview", now: now, snapshots: [snapshot]),
          languageCode: language, timeZone: TimeZone(secondsFromGMT: 0)!,
          maximumViewportHeight: QuotaMenuLayout.menuPopoverMaximumHeight,
          productVersion: "Desktop Preview (local)", enabledProviders: [.claude],
          loginItemState: .unavailable, onRefresh: {}, onQuit: {}
        )
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)),
            pixelsHigh: Int(ceil(size.height * 2)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)
        else { throw PreviewRenderError.bitmapUnavailable }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
          throw PreviewRenderError.bitmapUnavailable
        }
        try png.write(
          to: output.appendingPathComponent("\(language)-\(failed ? "unavailable" : "current").png")
        )
      }
    }
    print("{\"syntheticPreviewsRendered\":4,\"protectedAccess\":false}")
  }
}

private enum PreviewRenderError: Error { case bitmapUnavailable }

@MainActor
private final class DesktopPreviewPreferences: ObservableObject {
  @Published var displayMode = MenuBarDisplayMode.full
}

private struct DesktopPreviewContent: View {
  @ObservedObject var model: DesktopPreviewModel
  @ObservedObject var preferences: DesktopPreviewPreferences
  let onQuit: () -> Void

  var body: some View {
    QuotaMenuView(
      scenario: model.scenario, languageCode: "en", timeZone: .current,
      availableHeight: NSScreen.main?.visibleFrame.height,
      maximumViewportHeight: QuotaMenuLayout.menuPopoverMaximumHeight,
      menuBarDisplayMode: $preferences.displayMode,
      refreshInFlight: model.refreshing, productVersion: "Desktop Preview (local)",
      enabledProviders: [.claude], loginItemState: .unavailable,
      onRefresh: { Task { await model.refresh() } }, onQuit: onQuit)
  }
}
