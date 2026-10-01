import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

struct DesktopUsageCoordinatorTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let owner = DesktopUsageOwner(
    accountFingerprint: String(repeating: "a", count: 64),
    organizationFingerprint: String(repeating: "b", count: 64))
  private let otherOwner = DesktopUsageOwner(
    accountFingerprint: String(repeating: "c", count: 64),
    organizationFingerprint: String(repeating: "b", count: 64))

  @Test("Restart metadata contains no observation, owner, generation or response")
  func boundedRestartRecord() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(request, reply: try success(), context: context, now: now)
    let record = coordinator.throttleRecord(now: now)
    #expect(record.isValid)
    let bytes = try JSONEncoder().encode(record)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(
      Set(object.keys).isSubset(of: [
        "schemaVersion", "recordedAt", "lastAttemptAt", "localNextAllowedAt",
        "successfulNextAllowedAt", "serviceNotBefore", "unsupportedServiceWait", "failureCount",
        "interruptedUntil", "authRefusal",
      ]))
    var restarted = allowed()
    #expect(restarted.restoreThrottle(record, now: now) == true)
    #expect(restarted.observation == nil)
    #expect(restarted.activeRequest == nil)
    #expect(restarted.lastAttemptAt == now)
    #expect(restarted.begin(context: context, now: now.addingTimeInterval(299)) == nil)
    #expect(restarted.begin(context: context, now: now.addingTimeInterval(300)) != nil)
  }

  @Test("401/403 survive repeated restarts with fresh process generations", arguments: [401, 403])
  func refusalSurvivesRepeatedRestarts(status: Int) throws {
    var first = allowed()
    let initial = context()
    let request = try requireRequest(&first, context: initial, now: now)
    first.complete(request, reply: response(status), context: initial, now: now)
    var record = first.throttleRecord(now: now)
    let refusal: DesktopAuthRefusal = status == 401 ? .waitingForDesktopRenewal : .accessDenied
    #expect(record.authRefusal == refusal)
    for offset in [60.0, 120, 180] {
      let instant = now.addingTimeInterval(offset)
      var restarted = allowed()
      #expect(restarted.restoreThrottle(record, now: instant) == true)
      #expect(restarted.begin(context: context(), now: instant) == nil)
      #expect(restarted.state == refusal.state)
      record = restarted.throttleRecord(now: instant)
      #expect(record.authRefusal == refusal)
    }
  }

  @Test(
    "Restored refusal binds only valid identity and survives reapproval and read loss",
    arguments: [401, 403], ["identity", "expired", "scope"])
  func restoredRefusalRequiresSubsequentValidGeneration(status: Int, invalid: String) throws {
    let refusal: DesktopAuthRefusal = status == 401 ? .waitingForDesktopRenewal : .accessDenied
    var coordinator = allowed()
    #expect(
      coordinator.restoreThrottle(
        DesktopThrottleRecord(recordedAt: now, authRefusal: refusal), now: now) == true)
    let invalidContext = DesktopUsageContext(
      owner: invalid == "identity"
        ? DesktopUsageOwner(accountFingerprint: "invalid", organizationFingerprint: "invalid")
        : owner,
      generation: UUID(), expiresAt: invalid == "expired" ? now : now.addingTimeInterval(7200),
      hasProfileScope: invalid != "scope")
    #expect(coordinator.begin(context: invalidContext, now: now) == nil)
    let initial = context()
    #expect(coordinator.begin(context: initial, now: now) == nil)
    #expect(coordinator.state == refusal.state)
    coordinator.setPermission(.denied)
    #expect(coordinator.begin(context: context(), now: now) == nil)
    coordinator.setPermission(.allowed)
    #expect(coordinator.begin(context: nil, now: now) == nil)
    coordinator.suspendContext(now: now)
    #expect(coordinator.begin(context: initial, now: now) == nil)
    #expect(coordinator.state == refusal.state)
    #expect(coordinator.throttleRecord(now: now).authRefusal == refusal)
    #expect(coordinator.begin(context: invalidContext, now: now) == nil)
    #expect(coordinator.throttleRecord(now: now).authRefusal == refusal)
    let renewed = context()
    let request = try requireRequest(&coordinator, context: renewed, now: now)
    #expect(coordinator.throttleRecord(now: now).authRefusal == nil)
    coordinator.complete(request, reply: .networkFailure, context: renewed, now: now)
    #expect(coordinator.begin(context: initial, now: now.addingTimeInterval(60)) == nil)
    #expect(coordinator.state == refusal.state)
  }

  @Test(
    "Refusal recovery preserves Retry-After and prior rejected generations", arguments: [401, 403])
  func refusalRecoveryPreservesRateLimit(status: Int) throws {
    let refusal: DesktopAuthRefusal = status == 401 ? .waitingForDesktopRenewal : .accessDenied
    let retry = now.addingTimeInterval(7200)
    var coordinator = allowed()
    #expect(
      coordinator.restoreThrottle(
        DesktopThrottleRecord(recordedAt: now, serviceNotBefore: retry, authRefusal: refusal),
        now: now)
        == true)
    let initial = context(expiresAt: retry.addingTimeInterval(3600))
    #expect(coordinator.begin(context: initial, now: now) == nil)
    let renewed = context(expiresAt: retry.addingTimeInterval(3600))
    #expect(coordinator.begin(context: renewed, now: now.addingTimeInterval(60)) == nil)
    #expect(coordinator.throttleRecord(now: now.addingTimeInterval(60)).authRefusal == nil)
    #expect(coordinator.nextAllowedAt == retry)
    #expect(coordinator.begin(context: initial, now: retry) == nil)
    #expect(coordinator.state == refusal.state)
    #expect(coordinator.begin(context: renewed, now: retry) != nil)
  }

  @Test("An already rejected generation cannot clear a later refusal", arguments: [401, 403])
  func rejectedGenerationCannotRecoverRefusal(status: Int) throws {
    var coordinator = allowed()
    let initial = context()
    let first = try requireRequest(&coordinator, context: initial, now: now)
    coordinator.complete(first, reply: response(status), context: initial, now: now)
    let renewed = context()
    let later = now.addingTimeInterval(60)
    let second = try requireRequest(&coordinator, context: renewed, now: later)
    coordinator.complete(second, reply: response(status), context: renewed, now: later)
    #expect(coordinator.begin(context: initial, now: later.addingTimeInterval(60)) == nil)
    #expect(coordinator.throttleRecord(now: later).authRefusal != nil)
  }

  @Test("Restart clock rollback rebases local waits without shortening the service deadline")
  func restartClockRollback() throws {
    var first = allowed()
    let context = context()
    let request = try requireRequest(&first, context: context, now: now)
    let retry = now.addingTimeInterval(7200)
    first.complete(request, reply: response(429, retryAfter: retry), context: context, now: now)
    var restarted = allowed()
    #expect(
      restarted.restoreThrottle(first.throttleRecord(now: now), now: now.addingTimeInterval(-60))
        == true)
    #expect(restarted.begin(context: context, now: now.addingTimeInterval(60)) == nil)
    #expect(restarted.nextAllowedAt == retry)
    #expect(restarted.begin(context: context, now: retry) != nil)
  }

  @Test("An extreme injected deadline cannot create an enormous persisted wait")
  func extremeDeadlineIsExplicitStop() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(
      request, reply: response(429, retryAfter: now.addingTimeInterval(999_999_999_999_999)),
      context: context, now: now)
    #expect(coordinator.state == .serviceWaitUnavailable)
    #expect(coordinator.nextAllowedAt == nil)
    #expect(coordinator.throttleRecord(now: now).unsupportedServiceWait)
    coordinator.setPermission(.denied)
    coordinator.setPermission(.allowed)
    #expect(
      coordinator.begin(context: self.context(owner: otherOwner), now: now.addingTimeInterval(600))
        == nil)
    #expect(coordinator.state == .serviceWaitUnavailable)
  }

  @Test("Post-HTTP checkpoints retain the pre-rollback clock reference")
  func rollbackBeforeContextReadAndRestart() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    let rolledBack = now.addingTimeInterval(-3600)
    coordinator.recordServiceRestriction(request, reply: .networkFailure, now: rolledBack)
    let saved = coordinator.throttleRecord(now: rolledBack)
    #expect(saved.recordedAt == now)
    var restarted = allowed()
    #expect(restarted.restoreThrottle(saved, now: rolledBack) == true)
    #expect(restarted.nextAllowedAt == rolledBack.addingTimeInterval(900))
    #expect(restarted.begin(context: context, now: rolledBack.addingTimeInterval(899)) == nil)
    #expect(restarted.begin(context: context, now: rolledBack.addingTimeInterval(900)) != nil)
  }

  @Test("Invalid or unknown-schema restart records are rejected")
  func invalidRestartRecord() {
    var record = DesktopThrottleRecord(recordedAt: now)
    record.schemaVersion = 2
    var coordinator = allowed()
    #expect(coordinator.restoreThrottle(record, now: now) == false)
    record.schemaVersion = 1
    record.failureCount = -1
    #expect(!record.isValid)
    record.failureCount = 0
    record.recordedAt = Date(timeIntervalSince1970: .nan)
    #expect(!record.isValid)
    record.recordedAt = now
    record.interruptedUntil = now.addingTimeInterval(600)
    #expect(!record.isValid)
  }

  @Test("Default and denied permission never yield an acquisition request")
  func permissionRequired() {
    var coordinator = DesktopUsageCoordinator()
    let context = context()
    #expect(coordinator.begin(context: context, now: now) == nil)
    #expect(coordinator.state == .consentRequired)
    coordinator.setPermission(.denied)
    for offset in [0.0, 60, 3600] {
      #expect(coordinator.begin(context: context, now: now.addingTimeInterval(offset)) == nil)
      #expect(coordinator.state == .permissionDenied)
    }
    #expect(coordinator.lastAttemptAt == nil)
  }

  @Test("Missing, ambiguous, expired, or insufficient authentication metadata fails closed")
  func ineligibleContext() {
    let invalidOwner = DesktopUsageOwner(accountFingerprint: "", organizationFingerprint: "")
    let inputs: [(DesktopUsageContext?, DesktopUsageState)] = [
      (nil, .identityUnavailable),
      (context(owner: invalidOwner), .identityUnavailable),
      (context(expiresAt: now), .credentialExpired),
      (context(expiresAt: Date(timeIntervalSince1970: .infinity)), .credentialExpired),
      (context(hasProfileScope: false), .missingScope),
    ]
    for (input, expected) in inputs {
      var coordinator = allowed()
      #expect(coordinator.begin(context: input, now: now) == nil)
      #expect(coordinator.state == expected)
      #expect(coordinator.lastAttemptAt == nil)
    }
  }

  @Test("An exact server response retains its own source time, never the read time")
  func successfulObservation() throws {
    let context = context()
    var coordinator = allowed()
    let request = try requireRequest(&coordinator, context: context, now: now)
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(1)) == nil)
    coordinator.complete(
      request, reply: try success(), context: context, now: now.addingTimeInterval(2))
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.values.weekly.remainingPercent == 90)
    #expect(coordinator.observation?.values.weekly.isResetEstimated == false)
    #expect(coordinator.observation?.capturedAt == now)
    #expect(coordinator.lastAttemptAt == now)
    let readAt = now.addingTimeInterval(100)
    #expect(coordinator.currentObservation(context: context, now: readAt)?.capturedAt == now)
    #expect(coordinator.begin(context: context, now: readAt) == nil)
    #expect(coordinator.lastAttemptAt == now)
  }

  @Test(
    "An account or organization change revokes the old observation immediately",
    arguments: [false, true])
  func identityChange(organizationOnly: Bool) throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(request, reply: try success(), context: context, now: now)
    let changedOwner =
      organizationOnly
      ? DesktopUsageOwner(
        accountFingerprint: owner.accountFingerprint,
        organizationFingerprint: String(repeating: "d", count: 64)) : otherOwner
    let changed = self.context(owner: changedOwner)
    #expect(coordinator.currentObservation(context: changed, now: now) == nil)
    #expect(coordinator.observation == nil)
    #expect(coordinator.state == .contextChanged)
  }

  @Test("Sign-out, denial, or expired permission context removes all display values")
  func revokeObservation() throws {
    for mode in 0..<3 {
      var coordinator = allowed()
      let context = context(expiresAt: now.addingTimeInterval(10))
      let request = try requireRequest(&coordinator, context: context, now: now)
      coordinator.complete(request, reply: try success(), context: context, now: now)
      if mode == 1 { coordinator.setPermission(.denied) }
      let result = coordinator.currentObservation(
        context: mode == 0 ? nil : context, now: now.addingTimeInterval(10))
      #expect(result == nil)
      #expect(coordinator.observation == nil)
    }
  }

  @Test("Late replies cannot cross an account switch or an A-to-B-to-A generation change")
  func rejectInflightContextChange() throws {
    for differentOwner in [true, false] {
      var coordinator = allowed()
      let initial = context()
      let request = try requireRequest(&coordinator, context: initial, now: now)
      let changed = context(owner: differentOwner ? otherOwner : owner)
      coordinator.complete(request, reply: try success(), context: changed, now: now)
      #expect(coordinator.observation == nil)
      #expect(coordinator.activeRequest == nil)
      #expect(coordinator.state == .contextChanged)
    }
  }

  @Test("Missing or wrong verified server profile cannot authorize usage")
  func profileRequired() throws {
    for profile in [nil, otherOwner] {
      var coordinator = allowed()
      let context = context()
      let request = try requireRequest(&coordinator, context: context, now: now)
      coordinator.complete(
        request,
        reply: .response(
          status: 200, profileOwner: profile, serverDate: now, cacheAge: nil,
          retryAfter: nil, body: try payload()), context: context, now: now)
      #expect(coordinator.state == .identityMismatch)
      #expect(coordinator.observation == nil)
      #expect(coordinator.begin(context: context, now: now.addingTimeInterval(3600)) == nil)
    }
  }

  @Test(
    "401 and 403 wait for Desktop renewal instead of repeating the same authentication",
    arguments: [401, 403])
  func waitsForDesktopRenewal(status: Int) throws {
    var coordinator = allowed()
    let initial = context()
    let request = try requireRequest(&coordinator, context: initial, now: now)
    coordinator.complete(request, reply: response(status), context: initial, now: now)
    #expect(coordinator.state == (status == 401 ? .waitingForDesktopRenewal : .accessDenied))
    #expect(coordinator.begin(context: initial, now: now.addingTimeInterval(10)) == nil)
    #expect(coordinator.begin(context: nil, now: now.addingTimeInterval(20)) == nil)
    #expect(coordinator.begin(context: initial, now: now.addingTimeInterval(30)) == nil)
    let renewed = context()
    #expect(coordinator.begin(context: renewed, now: now.addingTimeInterval(60)) != nil)
  }

  @Test("An expired credential during a request cannot commit a successful response")
  func credentialExpiresInflight() throws {
    var coordinator = allowed()
    let context = context(expiresAt: now.addingTimeInterval(5))
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(
      request, reply: try success(), context: context, now: now.addingTimeInterval(5))
    #expect(coordinator.state == .credentialExpired)
    #expect(coordinator.observation == nil)
  }

  @Test("Duplicate completion cannot change the accepted result or reschedule it")
  func duplicateCompletion() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(request, reply: try success(), context: context, now: now)
    let next = coordinator.nextAllowedAt
    coordinator.complete(request, reply: response(401), context: nil, now: now)
    #expect(coordinator.state == .current)
    #expect(coordinator.observation != nil)
    #expect(coordinator.nextAllowedAt == next)
  }

  @Test("Expired in-flight work cannot overwrite a subsequent credential generation")
  func timeoutAndOutOfOrder() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(30)) == nil)
    #expect(coordinator.state == .timedOut)
    let renewed = self.context()
    let second = try requireRequest(&coordinator, context: renewed, now: now.addingTimeInterval(90))
    coordinator.complete(
      first, reply: response(401), context: nil, now: now.addingTimeInterval(90))
    #expect(coordinator.activeRequest == second)
    #expect(coordinator.state == .requesting)
    coordinator.complete(
      second, reply: try success(serverDate: now.addingTimeInterval(90)),
      context: renewed, now: now.addingTimeInterval(91))
    #expect(coordinator.state == .current)
  }

  @Test("A completion on the deadline is a timeout, not success")
  func completionDeadline() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(
      request, reply: try success(), context: context, now: now.addingTimeInterval(30))
    #expect(coordinator.state == .timedOut)
    #expect(coordinator.observation == nil)
  }

  @Test("Service Retry-After survives permission toggles and owner changes")
  func rateLimitIsGlobal() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    let retryAt = now.addingTimeInterval(7200)
    coordinator.complete(
      request, reply: response(429, retryAfter: retryAt), context: context, now: now)
    #expect(coordinator.nextAllowedAt == retryAt)
    coordinator.setPermission(.denied)
    coordinator.setPermission(.allowed)
    let changed = self.context(owner: otherOwner)
    #expect(coordinator.begin(context: changed, now: now.addingTimeInterval(3600)) == nil)
    #expect(coordinator.begin(context: changed, now: retryAt) != nil)
  }

  @Test("429 during account switching still preserves Retry-After")
  func rateLimitDuringAccountSwitch() throws {
    var coordinator = allowed()
    let request = try requireRequest(&coordinator, context: context(), now: now)
    let changed = context(owner: otherOwner)
    let retryAt = now.addingTimeInterval(7200)
    coordinator.complete(
      request, reply: response(429, retryAfter: retryAt), context: changed, now: now)
    #expect(coordinator.nextAllowedAt == retryAt)
    #expect(coordinator.begin(context: changed, now: now.addingTimeInterval(3600)) == nil)
    #expect(coordinator.observation == nil)
  }

  @Test("A cancelled request's 429 extends backoff without revoking a newer request")
  func cancelledRateLimitCannotBeOverwrittenByNewSuccess() throws {
    var coordinator = allowed()
    let first = try requireRequest(&coordinator, context: context(), now: now)
    let changed = context()
    #expect(coordinator.currentObservation(context: changed, now: now) == nil)
    let later = now.addingTimeInterval(60)
    let second = try requireRequest(&coordinator, context: changed, now: later)
    let retryAt = now.addingTimeInterval(7200)
    coordinator.complete(
      first, reply: response(429, retryAfter: retryAt), context: nil, now: later)
    #expect(coordinator.activeRequest == second)
    #expect(coordinator.state == .requesting)
    coordinator.complete(
      second, reply: try success(serverDate: later), context: changed, now: later)
    #expect(coordinator.state == .current)
    #expect(coordinator.nextAllowedAt == retryAt)
    coordinator.complete(
      first, reply: response(429, retryAfter: now.addingTimeInterval(9000)),
      context: changed, now: later)
    #expect(coordinator.nextAllowedAt == retryAt)
  }

  @Test("Permission revocation during a request ignores later success")
  func revokeInFlight() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.setPermission(.denied)
    coordinator.complete(request, reply: try success(), context: context, now: now)
    #expect(coordinator.state == .permissionDenied)
    #expect(coordinator.observation == nil)
    #expect(coordinator.activeRequest == nil)
  }

  @Test("A-to-B-to-A cannot adopt the first account generation's delayed response")
  func fullRoundTripAccountSwitch() throws {
    var coordinator = allowed()
    let firstA = context()
    let request = try requireRequest(&coordinator, context: firstA, now: now)
    #expect(coordinator.currentObservation(context: context(owner: otherOwner), now: now) == nil)
    let secondA = context()
    #expect(coordinator.currentObservation(context: secondA, now: now) == nil)
    coordinator.complete(request, reply: try success(), context: secondA, now: now)
    #expect(coordinator.observation == nil)
    let nextTime = now.addingTimeInterval(60)
    let next = try requireRequest(&coordinator, context: secondA, now: nextTime)
    coordinator.complete(
      next, reply: try success(serverDate: nextTime), context: secondA, now: nextTime)
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.capturedAt == nextTime)
  }

  @Test("Failures back off finitely without refreshing the last observation")
  func exponentialBackoff() throws {
    var coordinator = allowed()
    let context = context()
    var instant = now
    for delay in [60.0, 120, 240, 480, 900, 900] {
      let request = try requireRequest(&coordinator, context: context, now: instant)
      coordinator.complete(request, reply: .networkFailure, context: context, now: instant)
      #expect(coordinator.nextAllowedAt == instant.addingTimeInterval(delay))
      #expect(coordinator.observation == nil)
      #expect(
        coordinator.begin(context: context, now: instant.addingTimeInterval(delay - 1)) == nil)
      instant = instant.addingTimeInterval(delay)
    }
  }

  @Test("Invalid Retry-After cannot generate a busy retry loop")
  func invalidRetryAfter() throws {
    for retryAt in [nil, now.addingTimeInterval(-1), Date(timeIntervalSince1970: .infinity)] {
      var coordinator = allowed()
      let context = context()
      let request = try requireRequest(&coordinator, context: context, now: now)
      coordinator.complete(
        request, reply: response(429, retryAfter: retryAt), context: context, now: now)
      #expect(coordinator.nextAllowedAt == now.addingTimeInterval(60))
    }
  }

  @Test("Transport errors never advance observation time or lend a reset to another value")
  func retainsBoundedSameOwnerObservation() throws {
    let errors: [DesktopUsageReply] = [
      .networkFailure, .timeout, response(500), response(302),
      response(429, retryAfter: now.addingTimeInterval(7200)),
    ]
    for error in errors {
      var coordinator = allowed()
      let context = context()
      let first = try requireRequest(&coordinator, context: context, now: now)
      coordinator.complete(first, reply: try success(), context: context, now: now)
      let secondAt = now.addingTimeInterval(300)
      let second = try requireRequest(&coordinator, context: context, now: secondAt)
      coordinator.complete(second, reply: error, context: context, now: secondAt)
      #expect(coordinator.observation?.capturedAt == now)
      #expect(coordinator.observation?.values.weekly.remainingPercent == 90)
      #expect(coordinator.observation?.values.weekly.resetAt == now.addingTimeInterval(200_000))
      #expect(coordinator.state != .current)
      #expect(coordinator.currentObservation(context: context, now: secondAt)?.capturedAt == now)
      let failureState = coordinator.state
      let lastAttemptAt = coordinator.lastAttemptAt
      let nextAllowedAt = coordinator.nextAllowedAt
      #expect(
        coordinator.currentObservation(context: context, now: secondAt)?.values.fiveHour == nil)
      #expect(coordinator.state == failureState)
      #expect(coordinator.lastAttemptAt == lastAttemptAt)
      #expect(coordinator.nextAllowedAt == nextAllowedAt)
      #expect(
        coordinator.currentObservation(context: context, now: now.addingTimeInterval(901)) == nil)
      #expect(coordinator.state == failureState)
    }
  }

  @Test("Cached, undated, old, and future responses cannot masquerade as a live observation")
  func rejectsFalseFreshness() throws {
    let inputs: [(Date?, TimeInterval?)] = [
      (nil, nil), (now.addingTimeInterval(-6), nil), (now.addingTimeInterval(6), nil),
      (Date(timeIntervalSince1970: .infinity), nil), (now, 1), (now, -1), (now, .nan),
    ]
    for (date, age) in inputs {
      var coordinator = allowed()
      let context = context()
      let request = try requireRequest(&coordinator, context: context, now: now)
      coordinator.complete(
        request,
        reply: .response(
          status: 200, profileOwner: owner, serverDate: date, cacheAge: age,
          retryAfter: nil, body: try payload()), context: context, now: now)
      #expect(coordinator.state == .invalidResponse)
      #expect(coordinator.observation == nil)
    }
  }

  @Test(
    "Small symmetric clock skew is admitted without future capture times",
    arguments: [-5.0, -1, 0, 1, 5])
  func symmetricClockSkew(offset: TimeInterval) throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    let serverDate = now.addingTimeInterval(offset)
    coordinator.complete(
      request, reply: try success(serverDate: serverDate), context: context, now: now)
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.capturedAt == min(serverDate, now))
    #expect(coordinator.currentObservation(context: context, now: now) != nil)
  }

  @Test("Renewal only removes the success interval, never the attempt floor or provider wait")
  func renewalScheduling() throws {
    var coordinator = allowed()
    let initial = context()
    let first = try requireRequest(&coordinator, context: initial, now: now)
    coordinator.complete(first, reply: try success(), context: initial, now: now)
    let renewed = context()
    #expect(coordinator.begin(context: renewed, now: now.addingTimeInterval(30)) == nil)
    #expect(coordinator.nextAllowedAt == now.addingTimeInterval(60))
    let second = try requireRequest(&coordinator, context: renewed, now: now.addingTimeInterval(60))
    let retryAt = now.addingTimeInterval(7200)
    coordinator.complete(
      second, reply: response(429, retryAfter: retryAt), context: renewed,
      now: now.addingTimeInterval(60))
    #expect(coordinator.begin(context: context(), now: now.addingTimeInterval(300)) == nil)
    #expect(coordinator.nextAllowedAt == retryAt)
  }

  @Test("Renewal never shortens an existing transient failure backoff")
  func renewalPreservesFailureBackoff() throws {
    var coordinator = allowed()
    let initial = context()
    let first = try requireRequest(&coordinator, context: initial, now: now)
    coordinator.complete(first, reply: .networkFailure, context: initial, now: now)
    let second = try requireRequest(&coordinator, context: initial, now: now.addingTimeInterval(60))
    coordinator.complete(
      second, reply: .networkFailure, context: initial, now: now.addingTimeInterval(60))
    #expect(coordinator.begin(context: context(), now: now.addingTimeInterval(121)) == nil)
    #expect(coordinator.nextAllowedAt == now.addingTimeInterval(180))
  }

  @Test("A reset expiring between server Date and receipt is not accepted")
  func expiresInTransit() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(
      request, reply: try success(resetAt: now.addingTimeInterval(1)), context: context,
      now: now.addingTimeInterval(2))
    #expect(coordinator.state == .invalidResponse)
  }

  @Test("A five-hour reset expiring in transit does not discard the weekly result")
  func fiveHourExpiresInTransit() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    let body = try JSONSerialization.data(withJSONObject: [
      "seven_day": [
        "utilization": 10,
        "resets_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(200_000)),
      ],
      "five_hour": [
        "utilization": 20,
        "resets_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(1)),
      ],
    ])
    coordinator.complete(
      request,
      reply: .response(
        status: 200, profileOwner: owner, serverDate: now, cacheAge: 0,
        retryAfter: nil, body: body), context: context, now: now.addingTimeInterval(2))
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.values.weekly.remainingPercent == 90)
    #expect(coordinator.observation?.values.fiveHour == nil)
  }

  @Test(
    "Observation expiry updates state as well as removing obsolete values",
    arguments: [false, true])
  func expiredObservationState(weeklyExpires: Bool) throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(
      request, reply: try success(resetAt: now.addingTimeInterval(weeklyExpires ? 60 : 200_000)),
      context: context, now: now)
    let instant = now.addingTimeInterval(weeklyExpires ? 60 : 901)
    #expect(coordinator.currentObservation(context: context, now: instant) == nil)
    #expect(coordinator.observation == nil)
    #expect(coordinator.state == (weeklyExpires ? .resetElapsed : .stale))
  }

  @Test("An early provider reset replaces the old deadline without cadence projection")
  func earlyReset() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(first, reply: try success(), context: context, now: now)
    let later = now.addingTimeInterval(300)
    let second = try requireRequest(&coordinator, context: context, now: later)
    let earlierReset = later.addingTimeInterval(100_000)
    coordinator.complete(
      second, reply: try success(serverDate: later, resetAt: earlierReset),
      context: context, now: later)
    #expect(coordinator.observation?.values.weekly.resetAt == earlierReset)
    #expect(coordinator.observation?.values.weekly.isResetEstimated == false)
  }

  @Test("Rollover requires a new server reset; expiry never adds seven days")
  func actualRolloverRequired() throws {
    var coordinator = allowed()
    let context = context()
    let oldReset = now.addingTimeInterval(60)
    let first = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(
      first, reply: try success(resetAt: oldReset), context: context, now: now)
    #expect(coordinator.nextAllowedAt == oldReset)
    #expect(coordinator.currentObservation(context: context, now: oldReset) == nil)
    let second = try requireRequest(&coordinator, context: context, now: oldReset)
    coordinator.complete(
      second, reply: try success(serverDate: oldReset, resetAt: oldReset),
      context: context, now: oldReset)
    #expect(coordinator.state == .invalidResponse)
    #expect(coordinator.observation == nil)
    let thirdAt = oldReset.addingTimeInterval(60)
    let third = try requireRequest(&coordinator, context: context, now: thirdAt)
    let actualReset = thirdAt.addingTimeInterval(500_000)
    coordinator.complete(
      third, reply: try success(serverDate: thirdAt, resetAt: actualReset),
      context: context, now: thirdAt)
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.values.weekly.resetAt == actualReset)
    #expect(actualReset != oldReset.addingTimeInterval(604_800))
    #expect(coordinator.observation?.values.weekly.isResetEstimated == false)
  }

  @Test("An expired five-hour window is omitted without extending it or losing the weekly window")
  func independentWindowExpiry() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(request, reply: try success(), context: context, now: now)
    let current = coordinator.currentObservation(context: context, now: now.addingTimeInterval(60))
    let observed = try #require(current)
    #expect(observed.values.weekly.resetAt == now.addingTimeInterval(200_000))
    #expect(observed.values.fiveHour == nil)
    #expect(observed.capturedAt == now)
  }

  @Test("Clock rollback clears display values and cannot bypass request throttling")
  func clockRollback() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(first, reply: try success(), context: context, now: now)
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(-1)) == nil)
    #expect(coordinator.state == .invalidClock)
    #expect(coordinator.observation == nil)
    #expect(coordinator.begin(context: context, now: now) == nil)
    #expect(coordinator.nextAllowedAt == now.addingTimeInterval(299))
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(298)) == nil)
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(299)) != nil)
  }

  @Test("A large rollback rebases only the remaining local wait and requires fresh values")
  func clockRollbackRecoversBeforeOldClock() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(first, reply: try success(), context: context, now: now)
    #expect(
      coordinator.currentObservation(context: context, now: now.addingTimeInterval(100)) != nil)
    let corrected = now.addingTimeInterval(-3600)
    #expect(coordinator.currentObservation(context: context, now: corrected) == nil)
    #expect(coordinator.state == .invalidClock)
    #expect(coordinator.observation == nil)
    #expect(coordinator.lastAttemptAt == now)
    let retryAt = corrected.addingTimeInterval(200)
    #expect(coordinator.nextAllowedAt == retryAt)
    #expect(coordinator.begin(context: context, now: retryAt.addingTimeInterval(-1)) == nil)
    let second = try requireRequest(&coordinator, context: context, now: retryAt)
    #expect(coordinator.observation == nil)
    coordinator.complete(
      second, reply: try success(serverDate: retryAt), context: context, now: retryAt)
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.capturedAt == retryAt)
  }

  @Test("Rollback preserves bounded transient backoff instead of retrying immediately")
  func clockRollbackPreservesTransientBackoff() throws {
    var coordinator = allowed()
    let context = context()
    var instant = now
    for delay in [60.0, 120, 240, 480, 900] {
      let request = try requireRequest(&coordinator, context: context, now: instant)
      coordinator.complete(request, reply: .networkFailure, context: context, now: instant)
      if delay < 900 { instant = instant.addingTimeInterval(delay) }
    }
    let corrected = now.addingTimeInterval(-3600)
    #expect(coordinator.begin(context: context, now: corrected) == nil)
    #expect(coordinator.nextAllowedAt == corrected.addingTimeInterval(900))
    #expect(coordinator.begin(context: context, now: corrected.addingTimeInterval(899)) == nil)
    let retryAt = corrected.addingTimeInterval(900)
    let request = try requireRequest(&coordinator, context: context, now: retryAt)
    coordinator.complete(request, reply: .networkFailure, context: context, now: retryAt)
    #expect(coordinator.nextAllowedAt == retryAt.addingTimeInterval(900))
  }

  @Test("Repeated rollback requires a stable minimum wait and revoked success cannot return")
  func clockRollbackCancelsInflightWork() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    let corrected = now.addingTimeInterval(-3600)
    #expect(coordinator.begin(context: context, now: corrected) == nil)
    #expect(coordinator.activeRequest == nil)
    #expect(coordinator.nextAllowedAt == corrected.addingTimeInterval(60))
    let earlier = corrected.addingTimeInterval(-10)
    #expect(coordinator.currentObservation(context: context, now: earlier) == nil)
    #expect(coordinator.nextAllowedAt == earlier.addingTimeInterval(60))
    #expect(coordinator.begin(context: context, now: earlier.addingTimeInterval(59)) == nil)
    let retryAt = earlier.addingTimeInterval(60)
    let second = try requireRequest(&coordinator, context: context, now: retryAt)
    coordinator.complete(first, reply: try success(), context: context, now: retryAt)
    #expect(coordinator.activeRequest == second)
    #expect(coordinator.state == .requesting)
    #expect(coordinator.observation == nil)
    coordinator.complete(
      second, reply: try success(serverDate: retryAt), context: context, now: retryAt)
    #expect(coordinator.state == .current)
  }

  @Test(
    "Rollback never bypasses a generation refusal or revives retained values",
    arguments: [401, 403])
  func clockRollbackPreservesRefusal(status: Int) throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(first, reply: try success(), context: context, now: now)
    let second = try requireRequest(
      &coordinator, context: context, now: now.addingTimeInterval(300))
    let corrected = now.addingTimeInterval(-3600)
    coordinator.complete(second, reply: response(status), context: context, now: corrected)
    #expect(coordinator.state == .invalidClock)
    #expect(coordinator.observation == nil)
    #expect(coordinator.activeRequest == nil)
    coordinator.setPermission(.denied)
    coordinator.setPermission(.allowed)
    let retryAt = corrected.addingTimeInterval(60)
    #expect(coordinator.begin(context: nil, now: retryAt) == nil)
    #expect(coordinator.begin(context: context, now: retryAt) == nil)
    #expect(coordinator.state == (status == 401 ? .waitingForDesktopRenewal : .accessDenied))
    #expect(coordinator.currentObservation(context: context, now: retryAt) == nil)
    #expect(coordinator.begin(context: self.context(), now: retryAt) != nil)
  }

  @Test("A prior Retry-After survives rollback, permission and identity changes")
  func clockRollbackPreservesExistingRateLimit() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    let retryAt = now.addingTimeInterval(7200)
    coordinator.complete(
      request, reply: response(429, retryAfter: retryAt), context: context, now: now)
    let corrected = now.addingTimeInterval(-3600)
    #expect(coordinator.begin(context: context, now: corrected) == nil)
    #expect(coordinator.nextAllowedAt == retryAt)
    coordinator.setPermission(.denied)
    coordinator.setPermission(.allowed)
    let changed = self.context(owner: otherOwner)
    #expect(coordinator.begin(context: changed, now: corrected.addingTimeInterval(900)) == nil)
    #expect(coordinator.begin(context: changed, now: retryAt.addingTimeInterval(-1)) == nil)
    #expect(coordinator.nextAllowedAt == retryAt)
    #expect(coordinator.begin(context: changed, now: retryAt) != nil)
  }

  @Test("A revoked request's late 429 still constrains successful rollback recovery")
  func clockRollbackLateRateLimit() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    let corrected = now.addingTimeInterval(-3600)
    #expect(coordinator.begin(context: context, now: corrected) == nil)
    let recoveredAt = corrected.addingTimeInterval(60)
    let second = try requireRequest(&coordinator, context: context, now: recoveredAt)
    let retryAt = now.addingTimeInterval(7200)
    coordinator.complete(
      first, reply: response(429, retryAfter: retryAt), context: nil, now: recoveredAt)
    #expect(coordinator.activeRequest == second)
    coordinator.complete(
      second, reply: try success(serverDate: recoveredAt), context: context, now: recoveredAt)
    #expect(coordinator.state == .current)
    #expect(coordinator.nextAllowedAt == retryAt)
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(300)) == nil)
  }

  @Test(
    "Nonfinite clock values never anchor recovery", arguments: [Double.nan, .infinity, -.infinity])
  func invalidClockRemainsFailClosed(value: Double) throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(request, reply: try success(), context: context, now: now)
    #expect(coordinator.begin(context: context, now: Date(timeIntervalSince1970: value)) == nil)
    #expect(coordinator.state == .invalidClock)
    #expect(coordinator.observation == nil)
    #expect(coordinator.nextAllowedAt == now.addingTimeInterval(300))
    let corrected = now.addingTimeInterval(-3600)
    #expect(coordinator.begin(context: context, now: corrected) == nil)
    #expect(coordinator.begin(context: context, now: corrected.addingTimeInterval(300)) != nil)
  }

  @Test("Same-owner renewal retains only the original observation until its reset expires")
  func retainedObservationAcrossRenewal() throws {
    var coordinator = allowed()
    let initial = context()
    let first = try requireRequest(&coordinator, context: initial, now: now)
    let resetAt = now.addingTimeInterval(360)
    coordinator.complete(first, reply: try success(resetAt: resetAt), context: initial, now: now)
    let renewed = context()
    let retained = coordinator.currentObservation(
      context: renewed, now: now.addingTimeInterval(100))
    #expect(retained?.capturedAt == now)
    #expect(retained?.values.weekly.resetAt == resetAt)
    #expect(retained?.values.fiveHour == nil)
    #expect(coordinator.state == .contextChanged)
    let retryAt = now.addingTimeInterval(300)
    let second = try requireRequest(&coordinator, context: renewed, now: retryAt)
    coordinator.complete(second, reply: .networkFailure, context: renewed, now: retryAt)
    #expect(coordinator.currentObservation(context: renewed, now: retryAt) == retained)
    #expect(coordinator.state == .temporaryFailure)
    #expect(coordinator.currentObservation(context: renewed, now: resetAt) == nil)
    #expect(coordinator.observation == nil)
    #expect(coordinator.state == .temporaryFailure)
  }

  @Test("A 429 received during clock rollback preserves the service deadline")
  func clockRollbackDuringRateLimit() throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    let retryAt = now.addingTimeInterval(7200)
    coordinator.complete(
      request, reply: response(429, retryAfter: retryAt), context: context,
      now: now.addingTimeInterval(-10))
    #expect(coordinator.state == .invalidClock)
    #expect(coordinator.nextAllowedAt == retryAt)
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(3600)) == nil)
    #expect(coordinator.begin(context: context, now: retryAt) != nil)
  }

  @Test(
    "A display-only context reread restores the unresolved authentication failure",
    arguments: [401, 403])
  func blockedStateSurvivesMissingContext(status: Int) throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(request, reply: response(status), context: context, now: now)
    #expect(coordinator.currentObservation(context: nil, now: now) == nil)
    #expect(coordinator.state == .identityUnavailable)
    #expect(coordinator.currentObservation(context: context, now: now) == nil)
    #expect(coordinator.state == (status == 401 ? .waitingForDesktopRenewal : .accessDenied))
    #expect(coordinator.activeRequest == nil)
  }

  @Test(
    "Authentication refusal survives a failed post-request context read", arguments: [401, 403])
  func refusalBeforeContextRevalidation(status: Int) throws {
    var coordinator = allowed()
    let context = context()
    let request = try requireRequest(&coordinator, context: context, now: now)
    coordinator.complete(
      request, reply: response(status), context: nil, now: now.addingTimeInterval(1))
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(61)) == nil)
    #expect(coordinator.state == (status == 401 ? .waitingForDesktopRenewal : .accessDenied))
  }

  @Test("A cancelled old-generation refusal cannot reject the current generation")
  func lateRefusalIsGenerationBound() throws {
    var coordinator = allowed()
    let old = context()
    let first = try requireRequest(&coordinator, context: old, now: now)
    let current = context()
    let second = try requireRequest(&coordinator, context: current, now: now.addingTimeInterval(61))
    coordinator.complete(
      first, reply: response(401), context: current, now: now.addingTimeInterval(62))
    coordinator.complete(
      second, reply: try success(serverDate: now.addingTimeInterval(62)), context: current,
      now: now.addingTimeInterval(63))
    #expect(coordinator.state == .current)
    #expect(coordinator.observation != nil)
  }

  @Test("A late refusal for the same generation also invalidates a newer response")
  func lateSameGenerationRefusalWins() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    _ = coordinator.currentObservation(context: nil, now: now.addingTimeInterval(1))
    let second = try requireRequest(&coordinator, context: context, now: now.addingTimeInterval(61))
    coordinator.complete(
      first, reply: response(403), context: context, now: now.addingTimeInterval(62))
    coordinator.complete(
      second, reply: try success(serverDate: now.addingTimeInterval(62)), context: context,
      now: now.addingTimeInterval(63))
    #expect(coordinator.state == .accessDenied)
    #expect(coordinator.observation == nil)
  }

  private func requireRequest(
    _ coordinator: inout DesktopUsageCoordinator, context: DesktopUsageContext, now: Date
  ) throws -> DesktopUsageRequest {
    let request = coordinator.begin(context: context, now: now)
    return try #require(request)
  }

  private func context(
    owner: DesktopUsageOwner? = nil, expiresAt: Date? = nil, hasProfileScope: Bool = true
  ) -> DesktopUsageContext {
    DesktopUsageContext(
      owner: owner ?? self.owner, generation: UUID(),
      expiresAt: expiresAt ?? now.addingTimeInterval(20_000), hasProfileScope: hasProfileScope)
  }

  private func allowed() -> DesktopUsageCoordinator {
    var coordinator = DesktopUsageCoordinator()
    coordinator.setPermission(.allowed)
    return coordinator
  }

  private func response(_ status: Int, retryAfter: Date? = nil) -> DesktopUsageReply {
    .response(
      status: status, profileOwner: nil, serverDate: nil, cacheAge: nil,
      retryAfter: retryAfter, body: Data())
  }

  private func success(serverDate: Date? = nil, resetAt: Date? = nil) throws -> DesktopUsageReply {
    .response(
      status: 200, profileOwner: owner, serverDate: serverDate ?? now, cacheAge: 0,
      retryAfter: nil, body: try payload(resetAt: resetAt, observedAt: serverDate))
  }

  private func payload(resetAt: Date? = nil, observedAt: Date? = nil) throws -> Data {
    let formatter = ISO8601DateFormatter()
    return try JSONSerialization.data(withJSONObject: [
      "seven_day": [
        "utilization": 10,
        "resets_at": formatter.string(from: resetAt ?? now.addingTimeInterval(200_000)),
      ],
      "five_hour": [
        "utilization": 20,
        "resets_at": formatter.string(from: (observedAt ?? now).addingTimeInterval(60)),
      ],
    ])
  }
}
