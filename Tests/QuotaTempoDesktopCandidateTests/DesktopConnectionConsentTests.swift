import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

@Suite("Desktop remembered consent")
@MainActor
struct DesktopConnectionConsentTests {
  private func isolatedDefaults() -> (String, UserDefaults) {
    let name = "QuotaTempo-Consent-Synthetic-\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
  }

  @Test func absentOldOrInvalidRevisionNeverGrantsAccess() throws {
    let (name, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = DesktopConnectionConsentPreferences(defaults: defaults)
    #expect(try !store.isAccepted())
    let invalidValues: [Any] = [
      true, 1, "true", "desktop-local-usage-persistent-v0", ["accepted": true],
    ]
    for invalid in invalidValues {
      defaults.set(invalid, forKey: DesktopConnectionConsentPreferences.key)
      #expect(try !store.isAccepted())
    }
  }

  @Test func onlyVersionedConsentIsStoredAndRevocationSurvivesNewInstances() throws {
    let (name, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = DesktopConnectionConsentPreferences(defaults: defaults)
    try store.setAccepted(true)
    let reloaded = DesktopConnectionConsentPreferences(defaults: UserDefaults(suiteName: name)!)
    #expect(try reloaded.isAccepted())
    let record = try #require(defaults.persistentDomain(forName: name))
    #expect(Set(record.keys) == [DesktopConnectionConsentPreferences.key])
    #expect(record.values.first as? String == DesktopConnectionConsentPreferences.revision)
    try reloaded.setAccepted(false)
    #expect(try !store.isAccepted())
    #expect(defaults.object(forKey: DesktopConnectionConsentPreferences.key) == nil)
  }

  @Test func failedSynchronizationIsNotReportedAsSavedConsent() throws {
    let (name, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let store = DesktopConnectionConsentPreferences(defaults: defaults, synchronize: { false })
    #expect(throws: DesktopConnectionConsentError.self) { try store.isAccepted() }
    #expect(throws: DesktopConnectionConsentError.self) { try store.setAccepted(true) }
    #expect(throws: DesktopConnectionConsentError.self) { try store.setAccepted(false) }
  }
}
