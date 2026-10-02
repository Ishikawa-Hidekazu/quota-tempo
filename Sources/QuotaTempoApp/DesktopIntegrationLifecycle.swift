#if DESKTOP_INTEGRATION_PREVIEW
  import Foundation
  import QuotaTempoCore
  import QuotaTempoDesktopCandidate

  @MainActor
  protocol DesktopLifecycleConnecting: AnyObject {
    func resumeIfConsented(acquisitionAllowed: Bool) async
    func updateDisplay()
    func refresh(recheck: Bool) async
    func revokeConsent()
  }

  extension DesktopConnectionController: DesktopLifecycleConnecting {}

  @MainActor
  struct DesktopIntegrationLifecycle {
    static let schedulingInterval: TimeInterval = 30

    let connection: any DesktopLifecycleConnecting
    let acquisitionAllowed: @MainActor () -> Bool

    func start() async {
      guard !Task.isCancelled else { return }
      await connection.resumeIfConsented(acquisitionAllowed: acquisitionAllowed())
    }

    // Timer, wake and manual refresh all use normal admission, never recheck.
    func refresh() async {
      connection.updateDisplay()
      guard !Task.isCancelled, acquisitionAllowed() else { return }
      await connection.refresh(recheck: false)
    }

    func providersChanged(_ providers: Set<ProviderID>) {
      if !providers.contains(.claude) {
        connection.revokeConsent()
      }
    }
  }
#endif
