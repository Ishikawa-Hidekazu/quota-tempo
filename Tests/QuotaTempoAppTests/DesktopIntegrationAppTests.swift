#if DESKTOP_INTEGRATION_PREVIEW
  import Foundation
  import Testing
  import AppKit
  import SwiftUI
  import QuotaTempoDesktopCandidate
  @testable import QuotaTempoApp
  @testable import QuotaTempoCore

  @Suite("Desktop integration presentation")
  struct DesktopIntegrationAppTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Real preview retains the helper schedule; a custom directory disables acquisition")
    func configurationCannotResetProviderBackoff() {
      let support = URL(fileURLWithPath: "/synthetic/support", isDirectory: true)
      let real = DesktopIntegrationConfiguration(arguments: [], supportDirectory: support)
      #expect(!real.providerDisabled)
      #expect(real.appDirectory.lastPathComponent == "QuotaTempoIntegrationPreview")
      #expect(
        real.schedulingDirectory
          == support.appendingPathComponent("QuotaTempoDesktopPreview", isDirectory: true))
      for arguments in [
        ["--provider-disabled"], ["--storage-directory", "/synthetic/override"],
        ["--storage-directory"],
      ] {
        let synthetic = DesktopIntegrationConfiguration(
          arguments: arguments, supportDirectory: support)
        #expect(synthetic.providerDisabled)
        #expect(synthetic.schedulingDirectory != real.schedulingDirectory)
      }
    }

    @Test(
      "Disconnected connection controls render without opening an application",
      arguments: ["en", "ja"])
    @MainActor
    func renderControls(language: String) throws {
      let unused = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let controller = DesktopConnectionController(directory: unused)
      let view = DesktopIntegrationControls(connection: controller, allowsConnection: { true })
        .environment(\.locale, Locale(identifier: language))
        .frame(width: 544)
        .padding(18)
        .background(Color.white)
      let renderer = ImageRenderer(content: view)
      let rendered = try #require(renderer.nsImage)
      #expect(rendered.size.width == 580)
      #expect(rendered.size.height > 100)
      #expect(rendered.size.height < 350)
      #expect(!FileManager.default.fileExists(atPath: unused.path))
      if let directory = ProcessInfo.processInfo.environment["QUOTATEMPO_QA_RENDER_DIRECTORY"] {
        let tiff = try #require(rendered.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(
            "desktop-controls-\(language).png"))
      }
    }

    @Test("Disconnect or unavailable Desktop never reveals another source's quota")
    func noImplicitFallback() {
      let old = ProviderSnapshot(
        provider: .claude, source: .claudeBrowser, capturedAt: now,
        weekly: QuotaWindow(
          remainingPercent: 90, durationSeconds: 604_800,
          resetAt: now.addingTimeInterval(604_800)))
      let codex = ProviderSnapshot(
        provider: .codex, source: .codexAppServer, capturedAt: now, weekly: nil)
      let base = FixtureScenario(id: "synthetic", now: now, snapshots: [codex, old])
      let result = DesktopIntegrationPresentation.scenario(base: base, desktop: nil, enabled: true)
      #expect(result.snapshots.first == codex)
      #expect(result.snapshots.last?.source == .claudeDesktopDirect)
      #expect(result.snapshots.last?.weekly == nil)
      #expect(result.snapshots.last?.capturedAt == nil)
      #expect(QuotaPlanner.evaluate(result.snapshots.last!, now: now).targetNow == nil)
      #expect(
        DesktopIntegrationPresentation.scenario(base: base, desktop: old, enabled: false).snapshots
          == [codex])
    }

    @Test("Desktop reset alone drives the displayed plan")
    func exactDesktopPlan() {
      let desktop = ProviderSnapshot(
        provider: .claude, source: .claudeDesktopDirect, capturedAt: now,
        weekly: QuotaWindow(
          remainingPercent: 80, durationSeconds: 604_800,
          resetAt: now.addingTimeInterval(302_400)), sourceState: .observationSucceeded)
      let base = FixtureScenario(id: "synthetic", now: now, snapshots: [])
      let result = DesktopIntegrationPresentation.scenario(
        base: base, desktop: desktop, enabled: true)
      #expect(result.snapshots == [desktop])
      let plan = QuotaPlanner.evaluate(desktop, now: now)
      #expect(plan.targetNow == 50)
      #expect(plan.vsTarget == 30)
      #expect(!plan.targetIsEstimated)
    }
  }
#endif
