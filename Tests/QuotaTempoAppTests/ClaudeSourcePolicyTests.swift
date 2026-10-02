import Foundation
import Testing

@testable import QuotaTempoApp

@Suite("Claude source and public integration policy")
struct ClaudeSourcePolicyTests {
  @Test("Missing, legacy consent and unknown preferences never opt in to Desktop")
  func explicitSourceOnly() throws {
    let suite = "QuotaTempo.SourcePolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ClaudeSourcePreferences(defaults: defaults)
    #expect(preferences.load() == .automatic)
    defaults.set(1, forKey: "desktopConnection.consentRevision")
    #expect(preferences.load() == .automatic)
    defaults.set("unknown", forKey: ClaudeSourcePreferences.key)
    #expect(preferences.load() == .automatic)
    preferences.save(.desktop)
    #expect(ClaudeSourcePreferences(defaults: defaults).load() == .desktop)
    preferences.save(.automatic)
    #expect(ClaudeSourcePreferences(defaults: defaults).load() == .automatic)
  }

  @Test("Storage overrides disable both providers, including incomplete overrides")
  func isolatedStorage() {
    for arguments in [
      ["--provider-disabled"], ["--storage-directory"], ["--storage-directory", "/synthetic"],
    ] {
      #expect(QuotaTempoRuntimePolicy.providersDisabled(arguments: arguments))
    }
    #expect(!QuotaTempoRuntimePolicy.providersDisabled(arguments: []))
  }

  @Test(
    "Public updater and login policies do not depend on the Claude source",
    arguments: ClaudeSource.allCases)
  @MainActor
  func publicSystemIntegrations(source: ClaudeSource) throws {
    let suite = "QuotaTempo.SystemPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    ClaudeSourcePreferences(defaults: defaults).save(source)
    #expect(!QuotaTempoRuntimePolicy.systemIntegrationsEnabled(providerDisabled: true))
    #if DESKTOP_INTEGRATION_PREVIEW
      #expect(!QuotaTempoRuntimePolicy.systemIntegrationsEnabled(providerDisabled: false))
    #else
      #expect(QuotaTempoRuntimePolicy.systemIntegrationsEnabled(providerDisabled: false))
    #endif
  }
}
