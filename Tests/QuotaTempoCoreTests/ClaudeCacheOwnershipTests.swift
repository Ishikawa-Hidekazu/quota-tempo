import Foundation
import Testing

@testable import QuotaTempoCore

private struct CacheOwnershipReader: BoundedLocalDataReading {
  let records: [URL: Data]

  func read(from url: URL, limit: Int) throws -> Data {
    guard let data = records[url] else { throw ClaudeAutomaticAdapterError.sourceUnavailable }
    return data
  }
}

struct ClaudeCacheOwnershipTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let history = URL(fileURLWithPath: "/test/history.json")
  private let cache = URL(fileURLWithPath: "/test/cache.json")
  private let config = URL(fileURLWithPath: "/test/config.json")

  @Test("Usage stamped by another account is not attributed to the current account")
  func otherAccountCacheIsRejected() throws {
    let snapshot = try refresh(cacheAccount: "account-a", currentAccount: "account-b")
    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 90)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
    #expect(QuotaPlanner.evaluate(snapshot, now: now).vsTarget == nil)
  }

  @Test("An account-mismatched cache alone cannot produce quota or target")
  func otherAccountCacheWithoutHistoryIsRejected() throws {
    let snapshot = try refresh(
      cacheAccount: "account-a", currentAccount: "account-b", includeHistory: false)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.sourceState == .attemptFailed)
  }

  @Test("A legacy cache without an observation owner never supplies a Desktop reset")
  func missingCacheOwnerCannotMerge() throws {
    let snapshot = try refresh(cacheAccount: nil, currentAccount: "account-b")
    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 90)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
  }

  @Test("An owner-stamped matching cache still supplies a compatible exact reset")
  func matchingCacheOwnerCanMerge() throws {
    let snapshot = try refresh(cacheAccount: " ACCOUNT-B ", currentAccount: "account-b")
    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 90)
    #expect(snapshot.weekly?.resetAt == now.addingTimeInterval(200_000))
    #expect(snapshot.claudeAccountFingerprint != nil)
    #expect(QuotaPlanner.evaluate(snapshot, now: now).vsTarget != nil)
  }

  @Test("A blank observation owner cannot be used as account evidence")
  func blankOwnerCannotMerge() throws {
    let snapshot = try refresh(cacheAccount: "  ", currentAccount: "account-b")
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
  }

  @Test("A local-only reread does not overwrite a successful CLI capture when files are missing")
  func missingFilesKeepExistingLiveObservation() {
    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeCLI, capturedAt: now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 50, durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)),
      lastAttemptAt: now.addingTimeInterval(-60), sourceState: .observationSucceeded)
    let adapter = ClaudeAutomaticAdapter(
      reader: CacheOwnershipReader(records: [:]), cliExecutable: nil,
      historyURL: history, cacheURL: cache, desktopConfigURL: config)
    #expect(adapter.observeLocalChanges(previous: previous, now: now) == nil)
  }

  @Test("Local-only observation never reuses a browser account or its reset")
  func browserPreviousIsNotLocalInput() throws {
    let browser = ProviderSnapshot(
      provider: .claude, source: .claudeBrowser, capturedAt: now,
      weekly: QuotaWindow(
        remainingPercent: 50, durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)),
      lastAttemptAt: now, sourceState: .observationSucceeded)
    let adapter = ClaudeAutomaticAdapter(
      reader: CacheOwnershipReader(records: [:]), cliExecutable: nil,
      historyURL: history, cacheURL: cache, desktopConfigURL: config)
    let result = try #require(adapter.observeLocalChanges(previous: browser, now: now))
    #expect(result.source == .claudeDesktopHistory)
    #expect(result.weekly == nil)
    #expect(result.lastAttemptAt == nil)
  }

  @Test("Missing local files do not replace a prior live failure or advance its attempt")
  func missingFilesKeepLiveFailure() throws {
    let previous = failedPrevious(owner: String(repeating: "a", count: 64))
    let adapter = ClaudeAutomaticAdapter(
      reader: CacheOwnershipReader(records: [:]), cliExecutable: nil,
      historyURL: history, cacheURL: cache, desktopConfigURL: config)
    #expect(adapter.observeLocalChanges(previous: previous, now: now) == nil)
  }

  @Test("An owned observation from another account does not inherit a prior account's error")
  func accountChangeDoesNotInheritFailure() throws {
    let adapter = try adapter(
      cacheAccount: "account-b", currentAccount: "account-b", includeHistory: false,
      resetAfter: nil)
    let previous = failedPrevious(owner: String(repeating: "a", count: 64))
    let result = try #require(adapter.observeLocalChanges(previous: previous, now: now))
    #expect(result.claudeAccountFingerprint != previous.claudeAccountFingerprint)
    #expect(result.weekly?.resetAt == nil)
    #expect(result.sourceState == .observationSucceeded)
    #expect(result.errorCode == nil)
    #expect(result.lastAttemptAt == previous.lastAttemptAt)
  }

  @Test("Unowned history does not revive an error excluded by the current account check")
  func unownedHistoryAfterAccountChangeDoesNotInheritFailure() throws {
    let adapter = try adapter(
      cacheAccount: "account-a", currentAccount: "account-b", resetAfter: nil)
    let previous = failedPrevious(owner: String(repeating: "a", count: 64))
    let result = try #require(adapter.observeLocalChanges(previous: previous, now: now))
    #expect(result.source == .claudeDesktopHistory)
    #expect(result.weekly?.remainingPercent == 90)
    #expect(result.weekly?.resetAt == nil)
    #expect(result.claudeAccountFingerprint == nil)
    #expect(result.sourceState == .observationSucceeded)
    #expect(result.errorCode == nil)
    #expect(result.lastAttemptAt == previous.lastAttemptAt)
  }

  @Test("Only an exact fresh reset clears a same-account live failure", arguments: [false, true])
  func recoveryRequiresExactReset(exact: Bool) throws {
    let owner = try #require(
      refresh(cacheAccount: "account-b", currentAccount: "account-b").claudeAccountFingerprint)
    let previous = failedPrevious(owner: owner)
    let adapter = try adapter(
      cacheAccount: "account-b", currentAccount: "account-b", includeHistory: false,
      resetAfter: exact ? 200_000 : nil)
    let result = try #require(adapter.observeLocalChanges(previous: previous, now: now))
    #expect(result.weekly?.resetAt != nil)
    #expect(result.weekly?.isResetEstimated == !exact)
    #expect(result.sourceState == (exact ? .observationSucceeded : .attemptFailed))
    #expect(result.errorCode == (exact ? nil : .authenticationRequired))
    #expect(result.lastAttemptAt == previous.lastAttemptAt)
  }

  @Test(
    "A first local balance replaces nonfailure waiting states",
    arguments: [SourceState.neverObserved, .awaitingEvent, .bridgeUnavailable])
  func firstObservationDoesNotInheritWaitingState(state: SourceState) throws {
    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopHistory, capturedAt: nil, weekly: nil,
      sourceState: state)
    let adapter = try adapter(
      cacheAccount: "account-b", currentAccount: "account-b", includeHistory: false,
      resetAfter: nil)
    let result = try #require(adapter.observeLocalChanges(previous: previous, now: now))
    #expect(result.weekly?.remainingPercent == 20)
    #expect(result.sourceState == .observationSucceeded)
    #expect(result.errorCode == nil)
    #expect(result.lastAttemptAt == nil)
  }

  private func failedPrevious(owner: String) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .claude, source: .claudeCLI, capturedAt: now.addingTimeInterval(-120),
      weekly: QuotaWindow(
        remainingPercent: 10, durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(-90)),
      lastAttemptAt: now.addingTimeInterval(-30), sourceState: .attemptFailed,
      errorCode: .authenticationRequired, claudeAccountFingerprint: owner)
  }

  private func refresh(
    cacheAccount: String?, currentAccount: String, includeHistory: Bool = true
  ) throws -> ProviderSnapshot {
    try adapter(
      cacheAccount: cacheAccount, currentAccount: currentAccount, includeHistory: includeHistory
    ).refresh(previous: nil, now: now)
  }

  private func adapter(
    cacheAccount: String?, currentAccount: String, includeHistory: Bool = true,
    resetAfter: TimeInterval? = 200_000
  ) throws -> ClaudeAutomaticAdapter {
    var weekly: [String: Any] = ["utilization": 80]
    if let resetAfter {
      weekly["resets_at"] = ISO8601DateFormatter().string(
        from: now.addingTimeInterval(resetAfter))
    }
    var cached: [String: Any] = [
      "fetchedAtMs": Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000),
      "utilization": ["seven_day": weekly],
    ]
    if let cacheAccount { cached["accountUuid"] = cacheAccount }
    var records: [URL: Data] = [
      cache: try JSONSerialization.data(withJSONObject: [
        "oauthAccount": ["accountUuid": currentAccount, "organizationUuid": "same-org"],
        "cachedUsageUtilization": cached,
      ]),
      config: try JSONSerialization.data(withJSONObject: [
        "lastKnownAccountUuid": currentAccount
      ]),
    ]
    if includeHistory {
      records[history] = try JSONSerialization.data(withJSONObject: [
        "samples": [
          [
            "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
            "org": "same-org", "u": ["sd": 10],
          ]
        ]
      ])
    }
    return ClaudeAutomaticAdapter(
      reader: CacheOwnershipReader(records: records), cliExecutable: nil,
      historyURL: history, cacheURL: cache, desktopConfigURL: config
    )
  }
}
