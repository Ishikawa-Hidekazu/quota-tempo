import Foundation

public enum ProviderAcquisitionTrigger: Sendable {
  case launch
  case menuOpen
  case scheduledRefresh
  case systemWake
  case explicitRefresh
}

public enum ProviderRefreshSchedule {
  /// Provider acquisition stays deliberately low-frequency. The adapters retain
  /// their own five-minute last-attempt guard as a second line of protection.
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
