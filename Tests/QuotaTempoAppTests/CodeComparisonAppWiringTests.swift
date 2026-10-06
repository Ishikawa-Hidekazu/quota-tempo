import Foundation
import Testing

@testable import QuotaTempoApp
@testable import QuotaTempoCore
@testable import QuotaTempoDesktopCandidate

@Suite("Code comparison app wiring")
@MainActor
struct CodeComparisonAppWiringTests {
  @Test("App provider controls synchronously revoke comparison without changing the Claude source")
  func providerToggle() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("quotatempo-code-wiring-\(UUID().uuidString)", isDirectory: true)
    let suite = "QuotaTempo.CodeWiring.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suite)
    }
    let comparison = CodeUsageComparisonController()
    let model = LiveQuotaModel(
      store: NormalizedSnapshotStore(directory: directory.appendingPathComponent("snapshots")),
      acquisitionEnabled: false, claudeSource: .automatic)
    let desktop = DesktopConnectionController(
      makeService: { throw CodeComparisonFileError.unavailable }, repairStore: { _ in .notNeeded },
      consentStore: DesktopConnectionConsentPreferences(defaults: defaults))
    let root = QuotaTempoApplicationContent(
      model: model,
      settings: QuotaTempoSettingsModel(loginItemService: UnavailableLoginItemService()),
      presentation: QuotaTempoPresentationModel(defaults: defaults),
      codeComparison: comparison, desktopConnection: desktop,
      appDelegate: QuotaTempoApplicationDelegate(), productVersion: "synthetic",
      updater: QuotaTempoUpdater(enabled: false), maximumViewportHeight: nil,
      providerDisabled: false, onRefresh: {}, onQuit: {})
    let before = model.scenario
    await comparison.prepare()
    let command = try #require(comparison.command)
    let parts = command.split(separator: " ")
    #expect(parts.count == 3 && parts[2].count == 64)
    let grant = URL(fileURLWithPath: String(parts[1]))
      .appendingPathComponent("probe-grant.json")
    #expect(model.scenario.snapshots == before.snapshots)
    #expect(model.claudeSource == .automatic)
    #expect(FileManager.default.fileExists(atPath: grant.path))
    root.setProviderEnabled(.claude, enabled: false)
    #expect(!FileManager.default.fileExists(atPath: grant.path))
    #expect(comparison.command == nil && comparison.view.weekly == nil)
    #expect(model.claudeSource == .automatic)
    root.setProviderEnabled(.claude, enabled: true)
    await comparison.refresh()
    #expect(comparison.command == nil && comparison.view.weekly == nil)
    await comparison.disconnect()
  }
}
