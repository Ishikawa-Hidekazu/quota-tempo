import Foundation

public struct ProviderSelection: Equatable, Sendable {
  public static let all = ProviderSelection(enabled: Set(ProviderID.allCases))

  public let enabled: Set<ProviderID>

  public init(enabled: Set<ProviderID>) {
    self.enabled = enabled.isEmpty ? Set(ProviderID.allCases) : enabled
  }

  public func contains(_ provider: ProviderID) -> Bool {
    self.enabled.contains(provider)
  }

  public func setting(_ provider: ProviderID, enabled: Bool) -> ProviderSelection {
    var next = self.enabled
    if enabled {
      next.insert(provider)
    } else {
      guard next.count > 1 else { return self }
      next.remove(provider)
    }
    return ProviderSelection(enabled: next)
  }

  public func filtering(_ scenario: FixtureScenario) -> FixtureScenario {
    FixtureScenario(
      id: scenario.id,
      now: scenario.now,
      snapshots: scenario.snapshots.filter { self.enabled.contains($0.provider) }
    )
  }

  public static func detected(in snapshots: [ProviderSnapshot]) -> ProviderSelection? {
    let detected = Set(
      snapshots.compactMap { snapshot in
        snapshot.capturedAt != nil || snapshot.weekly != nil || snapshot.fiveHour != nil
          ? snapshot.provider
          : nil
      }
    )
    guard !detected.isEmpty else { return nil }
    return ProviderSelection(enabled: detected)
  }
}

public struct InitialProviderDetectionTracker: Equatable, Sendable {
  private var attempted = Set<ProviderID>()

  public init() {}

  public mutating func record(_ provider: ProviderID) -> Bool {
    self.attempted.insert(provider)
    return self.attempted == Set(ProviderID.allCases)
  }
}

@MainActor
public final class ProviderSelectionPreferences {
  private static let configuredKey = "providerSelection.configured"
  private static let codexKey = "providerSelection.codex.enabled"
  private static let claudeKey = "providerSelection.claude.enabled"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> ProviderSelection? {
    guard self.defaults.bool(forKey: Self.configuredKey) else { return nil }
    var enabled = Set<ProviderID>()
    if self.defaults.bool(forKey: Self.codexKey) { enabled.insert(.codex) }
    if self.defaults.bool(forKey: Self.claudeKey) { enabled.insert(.claude) }
    return ProviderSelection(enabled: enabled)
  }

  public func save(_ selection: ProviderSelection) {
    self.defaults.set(selection.contains(.codex), forKey: Self.codexKey)
    self.defaults.set(selection.contains(.claude), forKey: Self.claudeKey)
    self.defaults.set(true, forKey: Self.configuredKey)
  }
}
