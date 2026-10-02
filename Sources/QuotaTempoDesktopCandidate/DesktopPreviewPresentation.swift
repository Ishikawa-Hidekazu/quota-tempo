import Foundation
import QuotaTempoCore

// Stateless presentation for the local preview only. The service owns account and
// credential-context validation; neither those identities nor acquisition enter UI state.
enum DesktopPreviewPresentation {
  static func schedulingNotice(_ state: DesktopUsageState) -> String? {
    switch state {
    case .serviceWaitUnavailable: "Provider wait unsupported; automatic requests stopped."
    case .persistenceUnavailable: "Local scheduling state could not be saved or verified."
    case .waitingForNextRefresh: "Waiting for the next scheduled update."
    case .waitingForProvider: "Provider requested a wait; requests remain paused."
    case .waitingForDesktopRenewal: "Previous sign-in refused; renew or recheck connection."
    default: nil
    }
  }
  static func snapshot(_ result: DesktopUsageCandidateResult, now: Date) -> ProviderSnapshot? {
    guard result.disposition == .replaceDisplay else { return nil }

    let observation = currentObservation(result, now: now)
    let error =
      validDate(now)
      ? failure(result)
        ?? (observation == nil && result.state != .waitingForNextRefresh ? .sourceUnavailable : nil)
      : .invalidResponse
    let state: SourceState
    switch error {
    case nil: state = .observationSucceeded
    case .timeout: state = .attemptTimedOut
    case .usageRestricted: state = .accessRestricted
    default: state = .attemptFailed
    }
    let fiveHour = observation.flatMap { observation in
      observation.values.fiveHour.flatMap { window in
        validWindow(
          window, capturedAt: observation.capturedAt, now: now,
          duration: 18_000, maximumFuture: 21_600) ? window : nil
      }
    }
    return ProviderSnapshot(
      provider: .claude,
      source: .claudeDesktopDirect,
      capturedAt: observation?.capturedAt,
      weekly: observation?.values.weekly,
      fiveHour: fiveHour,
      // The result does not carry the actual attempt time. A display/backoff read
      // must not manufacture one from now or nextAllowedAt.
      sourceState: result.state == .waitingForNextRefresh ? .neverObserved : state,
      errorCode: error
    )
  }

  private static func currentObservation(
    _ result: DesktopUsageCandidateResult, now: Date
  ) -> DesktopUsageObservation? {
    guard result.credentialError == nil, validDate(now) else { return nil }
    switch result.state {
    case .current, .contextChanged, .waitingForNextRefresh, .waitingForProvider, .requesting,
      .rateLimited,
      .temporaryFailure, .timedOut,
      .invalidResponse:
      break
    default:
      return nil
    }
    guard let observation = result.observation,
      validDate(observation.capturedAt), observation.capturedAt <= now,
      now.timeIntervalSince(observation.capturedAt) < DesktopUsageCoordinator.observationMaximumAge,
      validWindow(
        observation.values.weekly, capturedAt: observation.capturedAt, now: now,
        duration: 604_800, maximumFuture: 691_200)
    else { return nil }
    return observation
  }

  private static func validWindow(
    _ window: QuotaWindow, capturedAt: Date, now: Date,
    duration: TimeInterval, maximumFuture: TimeInterval
  ) -> Bool {
    guard window.remainingPercent.isFinite, (0...100).contains(window.remainingPercent),
      window.durationSeconds == duration, !window.isResetEstimated,
      let resetAt = window.resetAt, validDate(resetAt), resetAt > now
    else { return false }
    return resetAt.timeIntervalSince(capturedAt) <= maximumFuture
  }

  private static func validDate(_ date: Date) -> Bool {
    date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0
  }

  private static func failure(_ result: DesktopUsageCandidateResult) -> AcquisitionErrorCode? {
    if let error = result.credentialError {
      switch error {
      case .expired: return .authenticationRequired
      case .missingScope: return .usageRestricted
      case .unsafePath: return .unsafePath
      case .inputTooLarge: return .inputTooLarge
      case .invalidStore: return .invalidResponse
      case .keychainLocked: return .temporaryFailure
      case .consentRequired, .providerApprovalRequired, .permissionRequired, .unavailable,
        .identityUnavailable, .ambiguousIdentity, .changedDuringRead:
        return .sourceUnavailable
      }
    }
    switch result.state {
    case .credentialExpired, .waitingForDesktopRenewal: return .authenticationRequired
    case .missingScope, .accessDenied: return .usageRestricted
    case .serviceWaitUnavailable: return .invalidResponse
    case .persistenceUnavailable: return .atomicWriteFailed
    case .rateLimited, .waitingForProvider, .temporaryFailure: return .temporaryFailure
    case .timedOut: return .timeout
    case .invalidResponse, .identityMismatch, .invalidClock: return .invalidResponse
    case .consentRequired, .permissionDenied, .identityUnavailable, .contextChanged, .ready, .stale,
      .resetElapsed:
      return .sourceUnavailable
    case .current, .requesting, .waitingForNextRefresh: return nil
    }
  }
}
