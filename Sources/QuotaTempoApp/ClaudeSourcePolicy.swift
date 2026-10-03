import Foundation

enum ClaudeSource: String, CaseIterable, Sendable {
  case automatic
  case desktop
}

struct ClaudeSourcePreferences {
  static let key = "claudeAcquisition.source.v1"
  let defaults: UserDefaults

  func load() -> ClaudeSource {
    defaults.string(forKey: Self.key).flatMap(ClaudeSource.init(rawValue:)) ?? .automatic
  }

  func save(_ source: ClaudeSource) {
    defaults.set(source.rawValue, forKey: Self.key)
  }
}

enum QuotaTempoRuntimePolicy {
  static var isDesktopPreview: Bool {
    #if DESKTOP_INTEGRATION_PREVIEW
      return true
    #else
      return false
    #endif
  }

  static func providersDisabled(arguments: [String]) -> Bool {
    arguments.contains("--provider-disabled") || arguments.contains("--storage-directory")
  }

  static func systemIntegrationsEnabled(providerDisabled: Bool) -> Bool {
    !providerDisabled && !isDesktopPreview
  }
}
