import Foundation

public enum ProviderAcquisitionTrigger: Sendable {
  case launch
  case menuOpen
  case scheduledRefresh
  case systemWake
  case explicitRefresh
}

public enum ProviderRefreshSchedule {
  /// Codex acquisition remains low-frequency. Each adapter retains its own
  /// last-attempt guard; Claude also checks local observations on minute ticks.
  public static let interval: TimeInterval = 15 * 60
}

public struct ProviderAcquisitionGate: Sendable {
  public let enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }

  public func performIfAllowed(
    _ trigger: ProviderAcquisitionTrigger,
    operation: () -> Void
  ) -> Bool {
    guard self.enabled else { return false }
    operation()
    return true
  }
}
