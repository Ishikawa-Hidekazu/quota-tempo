import Foundation

public enum SafeDiagnostics {
  public static func report(
    scenario: FixtureScenario,
    productVersion: String,
    operatingSystem: String
  ) -> String {
    let plans = QuotaPlanner.evaluateUnique(scenario.snapshots, now: scenario.now)
    var lines = [
      "QuotaTempo diagnostics",
      "Version: \(productVersion)",
      "Operating system: \(operatingSystem)",
      "Enabled providers: \(plans.map(\.provider.displayName).joined(separator: ", "))",
    ]

    for plan in plans {
      lines.append("")
      lines.append("[\(plan.provider.displayName)]")
      lines.append("Observation: \(plan.capturedAt == nil ? "unavailable" : "available")")
      lines.append("Source: \(plan.source.rawValue)")
      if let executableSource = plan.codexExecutableSource {
        lines.append("Codex executable source: \(executableSource.rawValue)")
      }
      if let executableVersion = plan.codexExecutableVersion {
        lines.append("Codex executable version: \(executableVersion)")
      }
      lines.append("Freshness: \(plan.freshness.rawValue)")
      lines.append("Source state: \(plan.sourceState?.rawValue ?? "notRecorded")")
      lines.append("Refresh error: \(plan.errorCode?.rawValue ?? "none")")
    }

    return lines.joined(separator: "\n")
  }
}
