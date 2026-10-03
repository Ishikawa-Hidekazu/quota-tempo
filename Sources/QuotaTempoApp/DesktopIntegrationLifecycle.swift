#if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
  import Foundation
  import QuotaTempoCore
  import QuotaTempoDesktopCandidate

  @MainActor
  protocol DesktopLifecycleConnecting: AnyObject {
    var consentPersistenceFailed: Bool { get }
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
      guard !Task.isCancelled, acquisitionAllowed() else { return }
      await connection.resumeIfConsented(acquisitionAllowed: true)
    }

    // Timer, wake and manual refresh all use normal admission, never recheck.
    func refresh() async {
      guard !Task.isCancelled, acquisitionAllowed() else { return }
      connection.updateDisplay()
      await connection.refresh(recheck: false)
    }

    func selectSource(_ source: ClaudeSource, model: LiveQuotaModel) {
      guard source != model.claudeSource else { return }
      // Persist revocation before Desktop selection. A crash between the two
      // writes must never bind an old consent to the newly selected source.
      connection.revokeConsent()
      if source == .desktop && connection.consentPersistenceFailed { return }
      model.setClaudeSource(source)
    }

    func setProviderEnabled(_ provider: ProviderID, enabled: Bool, model: LiveQuotaModel) {
      if provider == .claude && !enabled { connection.revokeConsent() }
      model.setProviderEnabled(provider, enabled: enabled)
    }

    func providersChanged(_ providers: Set<ProviderID>) {
      if !providers.contains(.claude) {
        connection.revokeConsent()
      }
    }
  }
#endif
