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

  @Test("Expired in-flight work times out and cannot overwrite a subsequent request")
  func timeoutAndOutOfOrder() throws {
    var coordinator = allowed()
    let context = context()
    let first = try requireRequest(&coordinator, context: context, now: now)
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(30)) == nil)
    #expect(coordinator.state == .timedOut)
    let second = try requireRequest(&coordinator, context: context, now: now.addingTimeInterval(90))
    coordinator.complete(
      first, reply: response(401), context: nil, now: now.addingTimeInterval(90))
    #expect(coordinator.activeRequest == second)
    #expect(coordinator.state == .requesting)
    coordinator.complete(
      second, reply: try success(serverDate: now.addingTimeInterval(90)),
      context: context, now: now.addingTimeInterval(91))
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
    let errors: [DesktopUsageReply] = [.networkFailure, .timeout, response(500), response(302)]
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
      #expect(coordinator.state != .current)
      #expect(coordinator.currentObservation(context: context, now: secondAt)?.capturedAt == now)
      #expect(
        coordinator.currentObservation(context: context, now: now.addingTimeInterval(901)) == nil)
    }
  }

  @Test("Cached, undated, old, and future responses cannot masquerade as a live observation")
  func rejectsFalseFreshness() throws {
    let inputs: [(Date?, TimeInterval?)] = [
      (nil, nil), (now.addingTimeInterval(-6), nil), (now.addingTimeInterval(1), nil),
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
    #expect(coordinator.begin(context: context, now: now.addingTimeInterval(300)) != nil)
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
