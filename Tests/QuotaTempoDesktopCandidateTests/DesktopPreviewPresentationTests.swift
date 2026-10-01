import Foundation
import QuotaTempoCore
import Testing

@testable import QuotaTempoDesktopCandidate

@Suite("Desktop preview presentation")
struct DesktopPreviewPresentationTests {
  private let now = Date(timeIntervalSince1970: 1_900_000_000)
  private let owner = DesktopUsageOwner(
    accountFingerprint: String(repeating: "a", count: 64),
    organizationFingerprint: String(repeating: "b", count: 64))

  @Test("A current Desktop result uses the core planner for W, P, and difference")
  func currentObservation() throws {
    let observed = observation()
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(result(observed), now: now))
    #expect(snapshot.provider == .claude)
    #expect(snapshot.source == .claudeDesktopDirect)
    #expect(snapshot.capturedAt == observed.capturedAt)
    #expect(snapshot.weekly == observed.values.weekly)
    #expect(snapshot.fiveHour == observed.values.fiveHour)
    #expect(snapshot.lastAttemptAt == nil)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.errorCode == nil)
    let plan = QuotaPlanner.evaluate(snapshot, now: now)
    #expect(plan.weeklyRemaining == 75)
    #expect(plan.targetNow == 50)
    #expect(plan.vsTarget == 25)
    #expect(!plan.targetIsEstimated)
    #expect(!plan.weeklyResetIsEstimated)
    #expect(plan.source == .claudeDesktopDirect)
  }

  @Test("Only unchangedInFlight returns nil, regardless of placeholder metadata")
  func unchangedInFlight() throws {
    for observed in [nil, observation()] {
      let input = result(
        observed, state: .permissionDenied, error: .permissionRequired,
        disposition: .unchangedInFlight)
      #expect(DesktopPreviewPresentation.snapshot(input, now: now) == nil)
      #expect(
        DesktopPreviewPresentation.snapshot(input, now: Date(timeIntervalSince1970: .nan)) == nil)
    }
    try expectUnavailable(result())
  }

  @Test("No observation replaces old values with generic unavailable, not CLI login")
  func missingObservation() throws {
    for state: DesktopUsageState in [.current, .ready, .requesting, .contextChanged] {
      let snapshot = try expectUnavailable(result(state: state))
      #expect(snapshot.errorCode == .sourceUnavailable)
      #expect(snapshot.sourceState == .attemptFailed)
    }
    let original = try #require(
      DesktopPreviewPresentation.snapshot(result(observation()), now: now))
    let cleared = try expectUnavailable(result())
    let scenario = SnapshotScenarioOverlay.apply(
      [.claude: cleared],
      to: FixtureScenario(id: "synthetic-preview", now: now, snapshots: [original]),
      now: now)
    #expect(scenario.snapshots == [cleared])
    #expect(QuotaPlanner.evaluate(scenario.snapshots[0], now: now).weeklyRemaining == nil)
  }

  @Test(
    "Observation age is strictly less than fifteen minutes",
    arguments: [0.0, 899, 899.999, 900, 901])
  func observationAge(age: TimeInterval) throws {
    let capturedAt = now.addingTimeInterval(-age)
    let input = result(observation(capturedAt: capturedAt))
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(input, now: now))
    #expect((snapshot.weekly != nil) == (age < 900))
    #expect(snapshot.capturedAt == (age < 900 ? capturedAt : nil))
    #expect(snapshot.lastAttemptAt == nil)
    if age >= 900 { try expectUnavailable(input) }
  }

  @Test("Future and invalid observation clocks never yield values")
  func invalidClocks() throws {
    for capturedAt in [
      now.addingTimeInterval(0.001), Date(timeIntervalSince1970: 0),
      Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .infinity),
      Date(timeIntervalSince1970: .nan),
    ] {
      try expectUnavailable(result(observation(capturedAt: capturedAt)))
    }
    for clock in [
      Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -1),
      Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan),
    ] {
      let snapshot = try #require(
        DesktopPreviewPresentation.snapshot(result(observation()), now: clock))
      #expect(snapshot.weekly == nil)
      #expect(snapshot.fiveHour == nil)
      #expect(snapshot.capturedAt == nil)
      #expect(snapshot.lastAttemptAt == nil)
      #expect(snapshot.errorCode == .invalidResponse)
      #expect(
        try NormalizedSnapshotCodec.decode(NormalizedSnapshotCodec.encode(snapshot)) == snapshot)
    }
  }

  @Test("Invalid or expired weekly data cannot leave a five-hour-only display")
  func invalidWeeklyWindows() throws {
    let validReset = now.addingTimeInterval(302_400)
    let invalid = [
      QuotaWindow(remainingPercent: 50, durationSeconds: 604_800, resetAt: nil),
      QuotaWindow(remainingPercent: 50, durationSeconds: 604_800, resetAt: now),
      QuotaWindow(
        remainingPercent: 50, durationSeconds: 604_800, resetAt: now.addingTimeInterval(-1)),
      QuotaWindow(
        remainingPercent: 50, durationSeconds: 604_800, resetAt: now.addingTimeInterval(691_201)),
      QuotaWindow(
        remainingPercent: 50, durationSeconds: 604_800,
        resetAt: Date(timeIntervalSince1970: .infinity)),
      QuotaWindow(
        remainingPercent: 50, durationSeconds: 604_800, resetAt: Date(timeIntervalSince1970: .nan)),
      QuotaWindow(
        remainingPercent: 50, durationSeconds: 604_800, resetAt: validReset,
        resetAtIsEstimated: true),
      QuotaWindow(remainingPercent: .nan, durationSeconds: 604_800, resetAt: validReset),
      QuotaWindow(remainingPercent: .infinity, durationSeconds: 604_800, resetAt: validReset),
      QuotaWindow(remainingPercent: -1, durationSeconds: 604_800, resetAt: validReset),
      QuotaWindow(remainingPercent: 101, durationSeconds: 604_800, resetAt: validReset),
      QuotaWindow(remainingPercent: 50, durationSeconds: 18_000, resetAt: validReset),
      QuotaWindow(remainingPercent: 50, durationSeconds: .infinity, resetAt: validReset),
    ]
    for weekly in invalid {
      try expectUnavailable(result(observation(weekly: weekly)))
    }
  }

  @Test("A valid weekly observation does not require a five-hour window")
  func weeklyOnly() throws {
    let observed = DesktopUsageObservation(
      owner: owner, capturedAt: now,
      values: DesktopUsageValues(weekly: observation().values.weekly, fiveHour: nil))
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(result(observed), now: now))
    #expect(snapshot.weekly == observed.values.weekly)
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.errorCode == nil)
    #expect(QuotaPlanner.evaluate(snapshot, now: now).targetNow == 50)
  }

  @Test("Five-hour expiry and invalid data are omitted without resetting weekly values")
  func invalidFiveHourWindows() throws {
    let validReset = now.addingTimeInterval(3600)
    let windows = [
      QuotaWindow(remainingPercent: 2, durationSeconds: 18_000, resetAt: nil),
      QuotaWindow(remainingPercent: 2, durationSeconds: 18_000, resetAt: now),
      QuotaWindow(
        remainingPercent: 2, durationSeconds: 18_000, resetAt: now.addingTimeInterval(-1)),
      QuotaWindow(
        remainingPercent: 2, durationSeconds: 18_000, resetAt: now.addingTimeInterval(21_601)),
      QuotaWindow(
        remainingPercent: 2, durationSeconds: 18_000, resetAt: validReset, resetAtIsEstimated: true),
      QuotaWindow(remainingPercent: .nan, durationSeconds: 18_000, resetAt: validReset),
      QuotaWindow(remainingPercent: 101, durationSeconds: 18_000, resetAt: validReset),
      QuotaWindow(remainingPercent: 2, durationSeconds: 604_800, resetAt: validReset),
    ]
    for window in windows {
      let observed = observation(fiveHour: window)
      let snapshot = try #require(DesktopPreviewPresentation.snapshot(result(observed), now: now))
      #expect(snapshot.weekly == observed.values.weekly)
      #expect(snapshot.fiveHour == nil)
      #expect(snapshot.capturedAt == now)
      #expect(snapshot.errorCode == nil)
      #expect(QuotaPlanner.evaluate(snapshot, now: now).targetNow == 50)
    }
  }

  @Test("Reset bounds are measured from capture, not renewed on display")
  func futureBoundsNeverSlide() throws {
    let captured = now.addingTimeInterval(-300)
    try expectUnavailable(
      result(
        observation(
          capturedAt: captured,
          weekly: QuotaWindow(
            remainingPercent: 75, durationSeconds: 604_800,
            resetAt: captured.addingTimeInterval(691_201)))))
    let input = result(
      observation(
        capturedAt: captured,
        weekly: QuotaWindow(
          remainingPercent: 75, durationSeconds: 604_800,
          resetAt: captured.addingTimeInterval(691_200))))
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(input, now: now))
    #expect(snapshot.capturedAt == captured)
    #expect(snapshot.weekly?.resetAt == captured.addingTimeInterval(691_200))
    // Keep the exact provider reset. The core planner, not this mapper, decides
    // whether a reset beyond the nominal week can support P.
    #expect(QuotaPlanner.evaluate(snapshot, now: now).targetNow == nil)
  }

  @Test("Transient failures keep only the service-approved current observation")
  func retainedObservationDuringBackoff() throws {
    let cases: [(DesktopUsageState, AcquisitionErrorCode, SourceState)] = [
      (.rateLimited, .temporaryFailure, .attemptFailed),
      (.temporaryFailure, .temporaryFailure, .attemptFailed),
      (.timedOut, .timeout, .attemptTimedOut),
      (.invalidResponse, .invalidResponse, .attemptFailed),
    ]
    let captured = now.addingTimeInterval(-300)
    for (state, error, sourceState) in cases {
      let input = result(observation(capturedAt: captured), state: state)
      let snapshot = try #require(DesktopPreviewPresentation.snapshot(input, now: now))
      #expect(snapshot.capturedAt == captured)
      #expect(snapshot.weekly?.remainingPercent == 75)
      #expect(snapshot.lastAttemptAt == nil)
      #expect(snapshot.errorCode == error)
      #expect(snapshot.sourceState == sourceState)
      #expect(
        try NormalizedSnapshotCodec.decode(NormalizedSnapshotCodec.encode(snapshot)) == snapshot)
      let later = try #require(
        DesktopPreviewPresentation.snapshot(input, now: now.addingTimeInterval(60)))
      #expect(later == snapshot)
      let expired = try #require(
        DesktopPreviewPresentation.snapshot(input, now: captured.addingTimeInterval(900)))
      #expect(expired.weekly == nil)
      #expect(expired.fiveHour == nil)
      #expect(expired.capturedAt == nil)
      try expectUnavailable(result(state: state))
    }
  }

  @Test("A context change clears even an otherwise valid same-owner observation")
  func contextChangeClearsValues() throws {
    let input = result(
      observation(capturedAt: now.addingTimeInterval(-300)), state: .contextChanged)
    let snapshot = try expectUnavailable(input)
    #expect(snapshot.lastAttemptAt == nil)
    #expect(snapshot.errorCode == .sourceUnavailable)
  }

  @Test("Permission, identity, authentication and expiry states always clear values")
  func clearingStates() throws {
    let cases: [(DesktopUsageState, AcquisitionErrorCode)] = [
      (.consentRequired, .sourceUnavailable), (.permissionDenied, .sourceUnavailable),
      (.identityUnavailable, .sourceUnavailable), (.ready, .sourceUnavailable),
      (.credentialExpired, .authenticationRequired), (.missingScope, .usageRestricted),
      (.stale, .sourceUnavailable), (.resetElapsed, .sourceUnavailable),
      (.waitingForDesktopRenewal, .authenticationRequired), (.accessDenied, .usageRestricted),
      (.identityMismatch, .invalidResponse), (.invalidClock, .invalidResponse),
    ]
    for (state, error) in cases {
      for observed in [nil, observation()] {
        let snapshot = try expectUnavailable(result(observed, state: state))
        #expect(snapshot.errorCode == error)
      }
    }
  }

  @Test("Credential failures cannot retain observations or suggest CLI authentication")
  func credentialFailures() throws {
    let cases: [(DesktopCredentialError, AcquisitionErrorCode)] = [
      (.consentRequired, .sourceUnavailable), (.providerApprovalRequired, .sourceUnavailable),
      (.permissionRequired, .sourceUnavailable), (.unavailable, .sourceUnavailable),
      (.keychainLocked, .temporaryFailure),
      (.unsafePath, .unsafePath), (.inputTooLarge, .inputTooLarge),
      (.invalidStore, .invalidResponse),
      (.identityUnavailable, .sourceUnavailable), (.ambiguousIdentity, .sourceUnavailable),
      (.expired, .authenticationRequired), (.missingScope, .usageRestricted),
      (.changedDuringRead, .sourceUnavailable),
    ]
    for (credentialError, error) in cases {
      let snapshot = try expectUnavailable(result(observation(), error: credentialError))
      #expect(snapshot.errorCode == error)
      for language in ["en", "ja"] {
        let copy = MenuCopy(languageCode: language).error(error, source: snapshot.source)
        #expect(!copy.contains("CLI"))
        #expect(!copy.contains("claude auth login"))
        #expect(!copy.contains("Codex"))
      }
    }
  }

  @Test("Normalized snapshots round-trip without owner metadata")
  func codecRoundTrip() throws {
    for input in [result(observation()), result(), result(state: .permissionDenied)] {
      let snapshot = try #require(DesktopPreviewPresentation.snapshot(input, now: now))
      let encoded = try NormalizedSnapshotCodec.encode(snapshot)
      #expect(try NormalizedSnapshotCodec.decode(encoded) == snapshot)
      let text = String(decoding: encoded, as: UTF8.self)
      #expect(text.contains("claudeDesktopDirect"))
      #expect(!text.contains("Fingerprint"))
      #expect(!text.contains(owner.accountFingerprint))
      #expect(!text.contains(owner.organizationFingerprint))
      #expect(snapshot.claudeAccountFingerprint == nil)
      #expect(snapshot.claudeOrganizationFingerprint == nil)
      #expect(snapshot.codexExecutableSource == nil)
      #expect(snapshot.codexExecutableVersion == nil)
    }
  }

  @Test("The Desktop source cannot be encoded or decoded as Codex")
  func codecRejectsWrongProvider() throws {
    let snapshot = ProviderSnapshot(
      provider: .codex, source: .claudeDesktopDirect, capturedAt: nil, weekly: nil)
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.encode(snapshot)
    }
    let legacy = try JSONEncoder().encode(snapshot)
    #expect(throws: SnapshotStoreError.invalidRecord) { try NormalizedSnapshotCodec.decode(legacy) }
  }

  @Test("The Desktop codec refuses persisted account or organization fingerprints")
  func codecRejectsIdentityMetadata() throws {
    for (account, organization) in [
      (owner.accountFingerprint as String?, nil as String?),
      (nil, owner.organizationFingerprint),
    ] {
      let snapshot = ProviderSnapshot(
        provider: .claude, source: .claudeDesktopDirect, capturedAt: nil, weekly: nil,
        claudeAccountFingerprint: account, claudeOrganizationFingerprint: organization)
      #expect(throws: SnapshotStoreError.invalidRecord) {
        try NormalizedSnapshotCodec.encode(snapshot)
      }
      let legacy = try JSONEncoder().encode(snapshot)
      #expect(throws: SnapshotStoreError.invalidRecord) {
        try NormalizedSnapshotCodec.decode(legacy)
      }
    }
  }

  @Test("Source-aware Desktop advice is localized without changing existing CLI advice")
  func localizedCopy() {
    for (language, label) in [("en", "Claude Desktop connection"), ("ja", "Claude Desktop接続")] {
      let copy = MenuCopy(languageCode: language)
      #expect(copy.source(.claudeDesktopDirect) == label)
      #expect(copy.text("claude.desktop.reset.help").contains("Desktop"))
      #expect(!copy.text("claude.desktop.reset.help").contains("Claude Code"))
      for error: AcquisitionErrorCode in [
        .authenticationRequired, .temporaryFailure, .sourceUnavailable, .usageRestricted,
      ] {
        let advice = copy.error(error, source: .claudeDesktopDirect)
        #expect(advice.contains("Desktop"))
        #expect(!advice.contains("CLI"))
        #expect(!advice.contains("Codex"))
        #expect(!advice.contains("browser"))
        #expect(advice != "error.claudeDesktopDirect.\(error.rawValue)")
      }
      #expect(copy.error(.authenticationRequired).contains("claude auth login"))
      #expect(
        copy.error(.authenticationRequired, source: .claudeCLI)
          == copy.error(.authenticationRequired))
      #expect(
        copy.error(.temporaryFailure, source: .codexAppServer) == copy.error(.temporaryFailure))
      #expect(
        copy.error(.authenticationRequired, source: .claudeBrowser)
          == copy.text("claude.browser.refresh.error"))
      #expect(
        copy.error(.invalidResponse, source: .claudeDesktopDirect) == copy.error(.invalidResponse))
    }
  }

  @discardableResult
  private func expectUnavailable(_ input: DesktopUsageCandidateResult) throws -> ProviderSnapshot {
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(input, now: now))
    #expect(snapshot.provider == .claude)
    #expect(snapshot.source == .claudeDesktopDirect)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.capturedAt == nil)
    #expect(snapshot.lastAttemptAt == nil)
    let plan = QuotaPlanner.evaluate(snapshot, now: now)
    #expect(plan.weeklyRemaining == nil)
    #expect(plan.targetNow == nil)
    #expect(plan.vsTarget == nil)
    #expect(
      try NormalizedSnapshotCodec.decode(NormalizedSnapshotCodec.encode(snapshot)) == snapshot)
    return snapshot
  }

  private func result(
    _ observation: DesktopUsageObservation? = nil,
    state: DesktopUsageState = .current, error: DesktopCredentialError? = nil,
    disposition: DesktopUsageCandidateResult.Disposition = .replaceDisplay
  ) -> DesktopUsageCandidateResult {
    DesktopUsageCandidateResult(
      disposition: disposition, state: state, observation: observation, credentialError: error,
      nextAllowedAt: now.addingTimeInterval(3600))
  }

  private func observation(
    capturedAt: Date? = nil, weekly: QuotaWindow? = nil, fiveHour: QuotaWindow? = nil
  ) -> DesktopUsageObservation {
    DesktopUsageObservation(
      owner: owner, capturedAt: capturedAt ?? now,
      values: DesktopUsageValues(
        weekly: weekly
          ?? QuotaWindow(
            remainingPercent: 75, durationSeconds: 604_800, resetAt: now.addingTimeInterval(302_400)
          ),
        fiveHour: fiveHour
          ?? QuotaWindow(
            remainingPercent: 80, durationSeconds: 18_000, resetAt: now.addingTimeInterval(3600))))
  }
}
