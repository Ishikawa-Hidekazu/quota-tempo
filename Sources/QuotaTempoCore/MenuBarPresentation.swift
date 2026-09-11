import Foundation

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
  case full
  case compact
  case iconOnly

  public var id: String { self.rawValue }
}

public struct MenuBarProviderPart: Identifiable, Equatable, Sendable {
  public let provider: ProviderID
  public let value: String

  public init(provider: ProviderID, value: String) {
    self.provider = provider
    self.value = value
  }

  public var id: ProviderID { self.provider }
}

public enum MenuBarTitleFormatter {
  public static func renderIdentity(
    scenario: FixtureScenario,
    mode: MenuBarDisplayMode
  ) -> String {
    "\(mode.rawValue):\(self.title(scenario: scenario, mode: mode) ?? "icon-only")"
  }

  public static func title(
    scenario: FixtureScenario,
    mode: MenuBarDisplayMode
  ) -> String? {
    let parts = self.parts(scenario: scenario, mode: mode)
    guard !parts.isEmpty else { return nil }
    return parts.map { part in
      "\(self.abbreviation(part.provider)) \(part.value)"
    }.joined(separator: " · ")
  }

  public static func parts(
    scenario: FixtureScenario,
    mode: MenuBarDisplayMode
  ) -> [MenuBarProviderPart] {
    guard mode != .iconOnly else { return [] }
    let plans = QuotaPlanner.evaluateUnique(scenario.snapshots, now: scenario.now)
    var byProvider: [ProviderID: PlannedProvider] = [:]
    for plan in plans where byProvider[plan.provider] == nil {
      byProvider[plan.provider] = plan
    }
    return ProviderID.allCases.compactMap { provider in
      guard let plan = byProvider[provider] else { return nil }
      return MenuBarProviderPart(
        provider: provider,
        value: self.value(plan: plan, mode: mode)
      )
    }
  }

  private static func value(
    plan: PlannedProvider?,
    mode: MenuBarDisplayMode
  ) -> String {
    guard let plan, let weekly = plan.weeklyRemaining else { return "—" }
    let weeklyRounded = QuotaPlanner.roundedPercent(weekly)
    let staleMarker = plan.freshness == .stale ? "?" : ""

    switch mode {
    case .full:
      guard let target = plan.targetNow else {
        return "W\(weeklyRounded)\(staleMarker)/P— —"
      }
      let targetRounded = QuotaPlanner.roundedPercent(target)
      let estimateMarker = plan.targetIsEstimated ? "≈" : ""
      guard plan.vsTarget != nil else {
        return "W\(weeklyRounded)\(staleMarker)/P\(estimateMarker)\(targetRounded) —"
      }
      let displayedDifference = QuotaPlanner.displayedDifference(
        weeklyRemaining: weekly,
        targetNow: target
      )!
      return
        "W\(weeklyRounded)/P\(estimateMarker)\(targetRounded) \(self.difference(displayedDifference))"
    case .compact:
      guard let target = plan.targetNow, plan.vsTarget != nil else {
        return "\(weeklyRounded)\(staleMarker) —"
      }
      let displayedDifference = QuotaPlanner.displayedDifference(
        weeklyRemaining: weekly,
        targetNow: target
      )!
      let estimateMarker = plan.targetIsEstimated ? " P≈" : ""
      return "\(weeklyRounded)\(self.difference(displayedDifference))\(estimateMarker)"
    case .iconOnly:
      return ""
    }
  }

  private static func abbreviation(_ provider: ProviderID) -> String {
    provider == .codex ? "Cx" : "Cl"
  }

  private static func difference(_ value: Int) -> String {
    if value > 0 { return "↑\(value)" }
    if value < 0 { return "↓\(abs(value))" }
    return "=0"
  }
}
