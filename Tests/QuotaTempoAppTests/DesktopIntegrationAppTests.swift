#if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
  import Foundation
  import Testing
  import AppKit
  import SwiftUI
  @testable import QuotaTempoDesktopCandidate
  @testable import QuotaTempoApp
  @testable import QuotaTempoCore

  @Suite("Desktop integration presentation")
  struct DesktopIntegrationAppTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Agree dismisses consent and shows progress synchronously, without duplicate actions")
    @MainActor
    func consentTransitionsBeforeAsyncWork() async throws {
      let interaction = DesktopConnectionInteraction()
      interaction.confirmation = .connection
      let gate = AsyncStream<Void>.makeStream()
      var calls = 0
      let submitted = interaction.perform(
        .connection, allowed: { true },
        action: {
          calls += 1
          for await _ in gate.stream { break }
        })
      let task = try #require(submitted)
      #expect(interaction.confirmation == nil)
      #expect(interaction.pending == .connection)
      let duplicate = interaction.perform(.connection, allowed: { true }, action: { calls += 1 })
      #expect(duplicate == nil)
      await Task.yield()
      gate.continuation.finish()
      await task.value
      #expect(calls == 1)
      #expect(interaction.pending == nil && interaction.confirmation == nil)
    }

    @Test("A queued action rechecks the current source and clears progress when invalidated")
    @MainActor
    func queuedActionChecksEligibility() async throws {
      let interaction = DesktopConnectionInteraction()
      interaction.confirmation = .connection
      var revision = 0
      var calls = 0
      let submitted = interaction.perform(
        .connection, allowed: { revision == 0 },
        action: {
          calls += 1
        })
      let task = try #require(submitted)
      revision += 1
      await task.value
      #expect(calls == 0)
      #expect(interaction.pending == nil && interaction.confirmation == nil)
    }

    @Test("Scheduled acquisition explains first values without claiming a successful fetch")
    @MainActor
    func waitingForFirstValues() async {
      let deadline = now.addingTimeInterval(300)
      let controller = DesktopConnectionController(
        makeService: {
          IntegrationResultStub(
            result: DesktopUsageCandidateResult(
              disposition: .replaceDisplay, state: .waitingForNextRefresh,
              observation: nil, credentialError: nil, nextAllowedAt: deadline))
        },
        repairStore: { _ in .notNeeded })
      await controller.connect(localExperimentAuthorized: true)
      let view = DesktopIntegrationControls(connection: controller, allowsConnection: { true })
      #expect(controller.snapshot?.weekly == nil)
      #expect(controller.status == .waitingForNextRefresh)
      #expect(view.showsScheduledTime && controller.nextAllowedAt == deadline)
      #expect(view.statusText.contains("after a successful check"))
      #expect(!view.statusText.contains("is current"))
      await controller.disconnect()
    }

    @Test("Permission failure does not promise values at an old scheduling deadline")
    @MainActor
    func permissionDoesNotClaimConnected() async {
      let controller = DesktopConnectionController(
        makeService: {
          IntegrationResultStub(
            result: DesktopUsageCandidateResult(
              disposition: .replaceDisplay, state: .permissionDenied,
              observation: nil, credentialError: .permissionRequired,
              nextAllowedAt: now.addingTimeInterval(-60)))
        }, repairStore: { _ in .notNeeded })
      await controller.connect(localExperimentAuthorized: true)
      let view = DesktopIntegrationControls(connection: controller, allowsConnection: { true })
      #expect(controller.canRequestKeychainAccess)
      #expect(!view.showsScheduledTime)
      #expect(view.statusText.contains("permission is needed"))
      #expect(!view.statusText.contains("Connection is ready"))
      await controller.disconnect()
    }

    @Test(
      "Inline consent and progress fit both languages without a modal", arguments: ["en", "ja"])
    @MainActor
    func renderConsentAndProgress(language: String) async throws {
      let unused = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let controller = DesktopConnectionController(directory: unused)
      let interaction = DesktopConnectionInteraction()
      interaction.confirmation = .connection
      for stage in ["consent", "progress"] {
        var task: Task<Void, Never>?
        let gate = AsyncStream<Void>.makeStream()
        if stage == "progress" {
          task = interaction.perform(
            .connection, allowed: { true },
            action: {
              for await _ in gate.stream { break }
            })
        }
        for width in [336.0, 544.0] {
          let view = DesktopIntegrationControls(
            connection: controller, allowsConnection: { true }, interaction: interaction
          )
          .environment(\.locale, Locale(identifier: language))
          .frame(width: width).padding(18).background(Color.white)
          let renderer = ImageRenderer(content: view)
          let rendered = try #require(renderer.nsImage)
          #expect(abs(rendered.size.width - (width + 36)) < 0.01)
          #expect(rendered.size.height < 650)
          if let directory = ProcessInfo.processInfo.environment["QUOTATEMPO_QA_RENDER_DIRECTORY"] {
            let tiff = try #require(rendered.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
              to: URL(fileURLWithPath: directory).appendingPathComponent(
                "desktop-\(stage)-\(language)-\(Int(width)).png"))
          }
        }
        gate.continuation.finish()
        await task?.value
      }
      #expect(!FileManager.default.fileExists(atPath: unused.path))
    }

    @Test(
      "Permission copy distinguishes ongoing macOS access from one-time Allow",
      arguments: ["en", "ja"])
    func permissionCopyExplainsContinuingAccess(language: String) {
      let copy = DesktopIntegrationConsentCopy(languageCode: language)
      #expect(copy.keychainAccess.contains(language == "ja" ? "常に許可" : "Always Allow"))
      #expect(copy.keychainAccess.contains(language == "ja" ? "1回限り" : "only once"))
      #expect(copy.keychainAccess.contains(language == "ja" ? "再度許可" : "permission again"))
      #expect(copy.consent.contains("Claude Safe Storage"))
      #expect(copy.consent.contains(language == "ja" ? "継続的なアクセス" : "ongoing access"))
      #expect(
        copy.consent.contains(
          language == "ja"
            ? "取得と自動接続を停止" : "stops acquisition and automatic reconnection"))
      #expect(copy.consent.contains(language == "ja" ? "取り消しません" : "does not revoke macOS"))
      #expect(
        copy.consent.contains(
          language == "ja"
            ? "提供元の変更により、取得できなくなる場合があります。"
            : "Provider changes may prevent QuotaTempo from retrieving usage data."))
      #expect(!copy.consent.contains("Beta"))
      #expect(!copy.consent.contains(language == "ja" ? "非公式" : "unofficial"))
      #expect(!copy.consent.contains(language == "ja" ? "許諾は未確認" : "permission is unconfirmed"))
      #if !DESKTOP_INTEGRATION_PREVIEW
        #expect(copy.consent.contains(language == "ja" ? "別の取得元へ切り替えません" : "never switch"))
      #endif
    }

    @Test("Restart does not hide memory-only Desktop because only Codex has a saved observation")
    @MainActor
    func savedCodexDoesNotDisableDesktopOnRestart() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let name = "QuotaTempo-Desktop-Restart-Synthetic-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: name)!
      defer { defaults.removePersistentDomain(forName: name) }
      let preferences = ProviderSelectionPreferences(defaults: defaults)
      let sources = ClaudeSourcePreferences(defaults: defaults)
      sources.save(.desktop)
      let store = NormalizedSnapshotStore(directory: directory)
      try store.save(
        ProviderSnapshot(
          provider: .codex, source: .codexAppServer, capturedAt: now,
          weekly: QuotaWindow(
            remainingPercent: 55, durationSeconds: 604_800,
            resetAt: now.addingTimeInterval(400_000)), sourceState: .observationSucceeded))
      let model = LiveQuotaModel(
        store: store, acquisitionEnabled: false, preferences: preferences,
        now: { now }, sourcePreferences: sources)
      #expect(model.claudeSource == .desktop && !model.allowsLocalClaude)
      #expect(model.enabledProviders == Set(ProviderID.allCases))
      #expect(preferences.load() == nil)
      preferences.save(ProviderSelection(enabled: [.codex]))
      let disabled = LiveQuotaModel(
        store: store, acquisitionEnabled: false, preferences: preferences,
        now: { now }, sourcePreferences: sources)
      #expect(disabled.enabledProviders == [.codex])
    }

    @Test("Real preview retains the helper schedule; a custom directory disables acquisition")
    func configurationCannotResetProviderBackoff() {
      let support = URL(fileURLWithPath: "/synthetic/support", isDirectory: true)
      let real = DesktopIntegrationConfiguration(arguments: [], supportDirectory: support)
      #expect(!real.providerDisabled)
      #expect(
        real.appDirectory.lastPathComponent
          == (QuotaTempoRuntimePolicy.isDesktopPreview
            ? "QuotaTempoIntegrationPreview" : "QuotaTempo"))
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

    @Test("OS permission controls render without requesting access", arguments: ["en", "ja"])
    @MainActor
    func renderPermissionControls(language: String) async throws {
      let controller = DesktopConnectionController(
        makeService: { IntegrationPermissionStub() }, repairStore: { _ in .notNeeded },
        authorizeKeychainAccess: {
          Issue.record("Rendering must not request OS access")
          return false
        })
      await controller.connect(localExperimentAuthorized: true)
      #expect(controller.canRequestKeychainAccess)
      let view = DesktopIntegrationControls(connection: controller, allowsConnection: { true })
        .environment(\.locale, Locale(identifier: language))
        .frame(width: 544).padding(18).background(Color.white)
      let renderer = ImageRenderer(content: view)
      let rendered = try #require(renderer.nsImage)
      #expect(rendered.size.width == 580 && rendered.size.height < 450)
      if let directory = ProcessInfo.processInfo.environment["QUOTATEMPO_QA_RENDER_DIRECTORY"] {
        let tiff = try #require(rendered.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(
          to: URL(fileURLWithPath: directory)
            .appendingPathComponent("desktop-permission-\(language).png"))
      }
      await controller.disconnect()
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
      let result = DesktopIntegrationPresentation.scenario(
        base: base, desktop: nil, enabled: true, now: now)
      #expect(result.snapshots.first == codex)
      #expect(result.snapshots.last?.source == .claudeDesktopDirect)
      #expect(result.snapshots.last?.weekly == nil)
      #expect(result.snapshots.last?.capturedAt == nil)
      #expect(
        DesktopIntegrationPresentation.scenario(
          base: base, desktop: nil, enabled: true, now: now, source: .automatic
        ).snapshots
          == base.snapshots)
      #expect(QuotaPlanner.evaluate(result.snapshots.last!, now: now).targetNow == nil)
      #expect(
        DesktopIntegrationPresentation.scenario(base: base, desktop: old, enabled: false, now: now)
          .snapshots
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
        base: base, desktop: desktop, enabled: true, now: now)
      #expect(result.snapshots == [desktop])
      let plan = QuotaPlanner.evaluate(desktop, now: now)
      #expect(plan.targetNow == 50)
      #expect(plan.vsTarget == 30)
      #expect(!plan.targetIsEstimated)
    }

    @Test("A Desktop capture newer than the Codex model clock remains visible immediately")
    func desktopRefreshDoesNotUseOlderBaseClock() throws {
      let capturedAt = now.addingTimeInterval(10)
      let desktop = ProviderSnapshot(
        provider: .claude, source: .claudeDesktopDirect, capturedAt: capturedAt,
        weekly: QuotaWindow(
          remainingPercent: 80, durationSeconds: 604_800,
          resetAt: now.addingTimeInterval(302_400)), sourceState: .observationSucceeded)
      let result = DesktopIntegrationPresentation.scenario(
        base: FixtureScenario(id: "old-clock", now: now, snapshots: []),
        desktop: desktop, enabled: true, now: now.addingTimeInterval(11))
      let plan = QuotaPlanner.evaluate(try #require(result.snapshots.first), now: result.now)
      #expect(plan.weeklyRemaining == 80)
      #expect(plan.targetNow != nil && plan.vsTarget != nil)
    }
  }

  private actor IntegrationPermissionStub: DesktopConnectionServing {
    func setApproval(_ approval: DesktopAccessApproval) {}
    func prepareForOfflineRepair() -> Bool { true }
    func recheckConnection() -> DesktopUsageCandidateResult { refresh() }
    func refresh() -> DesktopUsageCandidateResult {
      DesktopUsageCandidateResult(
        disposition: .replaceDisplay, state: .permissionDenied,
        observation: nil, credentialError: .permissionRequired, nextAllowedAt: nil)
    }
  }

  private actor IntegrationResultStub: DesktopConnectionServing {
    let result: DesktopUsageCandidateResult
    init(result: DesktopUsageCandidateResult) { self.result = result }
    func setApproval(_ approval: DesktopAccessApproval) {}
    func prepareForOfflineRepair() -> Bool { true }
    func recheckConnection() -> DesktopUsageCandidateResult { result }
    func refresh() -> DesktopUsageCandidateResult { result }
  }
#endif
