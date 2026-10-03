import Foundation

@MainActor
protocol DesktopConnectionConsentStoring {
  func isAccepted() throws -> Bool
  func setAccepted(_ accepted: Bool) throws
}

enum DesktopConnectionConsentError: Error { case persistenceFailed }

// This is an application preference, never a credential or account identifier.
// A changed scope needs a new revision and explicit consent, not a migration.
@MainActor
final class DesktopConnectionConsentPreferences: DesktopConnectionConsentStoring {
  static let key = "desktopConnection.consentRevision"
  static let revision = "desktop-local-usage-persistent-v1"
  private let defaults: UserDefaults
  private let synchronize: () -> Bool

  init(defaults: UserDefaults, synchronize: (() -> Bool)? = nil) {
    self.defaults = defaults
    self.synchronize = synchronize ?? { defaults.synchronize() }
  }

  func isAccepted() throws -> Bool {
    guard synchronize() else { throw DesktopConnectionConsentError.persistenceFailed }
    return defaults.object(forKey: Self.key) as? String == Self.revision
  }

  func setAccepted(_ accepted: Bool) throws {
    if accepted {
      defaults.set(Self.revision, forKey: Self.key)
    } else {
      defaults.removeObject(forKey: Self.key)
    }
    guard synchronize(),
      (defaults.object(forKey: Self.key) as? String == Self.revision) == accepted
    else { throw DesktopConnectionConsentError.persistenceFailed }
  }
}
