import AppKit
import SwiftUI
import Testing

@testable import QuotaTempoCore

@Suite("Feedback offscreen UI", .serialized)
@MainActor
struct FeedbackUITests {
  @Test(
    "Localized ready and failure controls fit narrow layouts without opening mail",
    arguments: ["en", "ja"], [false, true])
  func controls(_ language: String, _ failed: Bool) async throws {
    var calls = 0
    let controller = FeedbackDraftController(
      draft: FeedbackDraft(languageCode: language, publicAppVersion: "0.1.12"),
      open: { _ in
        calls += 1
        return false
      })
    if failed { controller.openDraft() }
    let view = FeedbackControls(languageCode: language, controller: controller)
      .padding(12).frame(width: 320, alignment: .leading).background(Color.white)
      .environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
    let window = self.hiddenWindow(host)
    defer { window.close() }
    self.layout(host)
    host.layoutSubtreeIfNeeded()
    for _ in 0..<5 { await Task.yield() }
    let size = host.fittingSize
    #expect(size.width == 320 && size.height > 40 && size.height < 300)
    host.setFrameSize(size)
    host.layoutSubtreeIfNeeded()
    #expect(calls == (failed ? 1 : 0))
    #expect(controller.openingFailed == failed)
    try self.render(host, name: "feedback-\(language)-\(failed ? "failed" : "ready")")
  }

  @Test(
    "Localized menus retain their capped viewport and scroll to the final actions in all states",
    arguments: ["en", "ja"], ["onboarding", "baseline", "waiting", "failure"])
  func menu(_ language: String, _ state: String) async throws {
    let baseline = try FixtureLoader.load("baseline")
    let scenario =
      state == "waiting" || state == "failure"
      ? FixtureScenario(
        id: state, now: baseline.now,
        snapshots: ProviderID.allCases.map { provider in
          ProviderSnapshot(
            provider: provider, source: .fixture, capturedAt: nil, weekly: nil,
            lastAttemptAt: state == "failure" ? baseline.now : nil,
            sourceState: state == "failure" ? .attemptFailed : .neverObserved,
            errorCode: state == "failure" ? .sourceUnavailable : nil)
        }) : baseline
    let view = QuotaMenuView(
      scenario: scenario, languageCode: language, locale: Locale(identifier: "en_US"),
      availableHeight: 600, maximumViewportHeight: QuotaMenuLayout.menuPopoverMaximumHeight,
      onboardingPresented: .constant(state == "onboarding"), refreshInFlight: state == "waiting",
      productVersion: "0.1.12", privacyURL: URL(string: "https://example.invalid/privacy"),
      supportURL: URL(string: "mailto:h@ishikawa.co"), onRefresh: {}, onCheckForUpdates: {},
      onCopyDiagnostics: { true }, onOpenWindow: {}, onQuit: {}
    )
    .environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = self.hiddenWindow(host)
    defer { window.close() }
    self.layout(host)
    host.layoutSubtreeIfNeeded()
    for _ in 0..<5 { await Task.yield() }
    #expect(host.fittingSize.width == QuotaMenuLayout.width)
    #expect(host.fittingSize.height <= 556)
    let scrollViews = self.scrollViews(host)
    #expect(!scrollViews.isEmpty)
    for scroll in scrollViews {
      guard let document = scroll.documentView else { continue }
      let y =
        document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
      scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
      #expect(document.bounds.height > scroll.contentView.bounds.height)
      #expect(abs(scroll.contentView.bounds.origin.y - y) < 1)
    }
    host.layoutSubtreeIfNeeded()
    for _ in 0..<5 { await Task.yield() }
    try self.render(host, name: "menu-\(language)-\(state)")
  }

  private func scrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { self.scrollViews($0) }
  }

  private func hiddenWindow(_ host: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    #expect(!window.isVisible)
    return window
  }

  private func layout(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    host.layoutSubtreeIfNeeded()
  }

  private func render(_ host: NSView, name: String) throws {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 2_000)
    let hasInk = stride(from: 8, to: bitmap.pixelsWide - 8, by: 4).contains { x in
      stride(from: 8, to: bitmap.pixelsHigh - 8, by: 4).contains { y in
        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          return false
        }
        return pixel.alphaComponent > 0.5 && pixel.redComponent < 0.8
      }
    }
    #expect(hasInk)
    if let directory = ProcessInfo.processInfo.environment["QUOTATEMPO_FEEDBACK_RENDER_DIR"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try png.write(to: url.appendingPathComponent("\(name).png"))
    }
  }
}
