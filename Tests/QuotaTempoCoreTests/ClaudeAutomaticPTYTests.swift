import Foundation
import Testing

@testable import QuotaTempoCore

private struct CacheUpdatingPTYProbe: ClaudeUsageProbing {
  let cacheURL: URL
  let shouldUpdate: Bool
  let output: Data

  init(
    cacheURL: URL, shouldUpdate: Bool,
    output: Data = Data("Current session\nCurrent week (all models)\nResets".utf8)
  ) {
    self.cacheURL = cacheURL
    self.shouldUpdate = shouldUpdate
    self.output = output
  }

  func capture(executable: URL, workingDirectory: URL) throws -> Data {
    if shouldUpdate {
      let now = Date()
      let formatter = ISO8601DateFormatter()
      let data = try JSONSerialization.data(withJSONObject: [
        "cachedUsageUtilization": [
          "fetchedAtMs": Int64(now.timeIntervalSince1970 * 1_000),
          "utilization": [
            "five_hour": [
              "utilization": 32.0,
              "resets_at": formatter.string(from: now.addingTimeInterval(10_000)),
            ],
            "seven_day": [
              "utilization": 41.0,
              "resets_at": formatter.string(from: now.addingTimeInterval(300_000)),
            ],
          ],
        ]
      ])
      try data.write(to: cacheURL, options: .atomic)
    }
    return output
  }
}

private struct RenderedUsagePTYProbe: ClaudeUsageProbing {
  let output: Data

  func capture(executable: URL, workingDirectory: URL) throws -> Data { output }
}

private struct FailingUsagePTYProbe: ClaudeUsageProbing {
  let error: ClaudeUsagePTYProbeError

  func capture(executable: URL, workingDirectory: URL) throws -> Data { throw error }
}

struct ClaudeAutomaticPTYTests {
  @Test("Live Claude guard tolerates jitter before the fifteen-minute scheduler")
  func probeInterval() {
    let now = Date()
    #expect(
      !ClaudeAutomaticAdapter.shouldRefresh(
        lastAttemptAt: now.addingTimeInterval(-(14 * 60 - 1)), now: now))
    #expect(
      ClaudeAutomaticAdapter.shouldRefresh(
        lastAttemptAt: now.addingTimeInterval(-14 * 60), now: now))
    #expect(
      ClaudeAutomaticAdapter.shouldRefresh(
        lastAttemptAt: now.addingTimeInterval(-899), now: now))
  }

  @Test("A concurrently refreshed cache does not make an incomplete PTY panel successful")
  func refreshedCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("claude.json")
    try Data("{}".utf8).write(to: cache)
    let now = Date()
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history.json"),
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: CacheUpdatingPTYProbe(cacheURL: cache, shouldUpdate: true),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now)

    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.fiveHour?.resetAt == nil)
  }

  @Test("PTY success without a fresh structured cache does not invent a reset")
  func missingRefresh() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("claude.json")
    try Data("{}".utf8).write(to: cache)
    let now = Date()
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history.json"),
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: CacheUpdatingPTYProbe(cacheURL: cache, shouldUpdate: false),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now)

    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .sourceUnavailable)
    #expect(snapshot.weekly?.resetAt == nil)
  }

  @Test("Rendered usage supplies exact windows when Claude does not refresh its cache")
  func parsedWithoutCacheUpdate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("claude.json")
    try Data("{}".utf8).write(to: cache)
    let now = Date()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let sessionReset = now.addingTimeInterval(2 * 60 * 60)
    let weeklyReset = now.addingTimeInterval(3 * 24 * 60 * 60)
    let sessionText = DateFormatter()
    sessionText.locale = Locale(identifier: "en_US_POSIX")
    sessionText.timeZone = calendar.timeZone
    sessionText.dateFormat = "h:mma"
    let weeklyText = DateFormatter()
    weeklyText.locale = Locale(identifier: "en_US_POSIX")
    weeklyText.timeZone = calendar.timeZone
    weeklyText.dateFormat = "MMM d 'at' h:mma"
    let output = Data(
      """
      Currentsession
      ███ 32%used
      Resets\(sessionText.string(from: sessionReset))(Asia/Tokyo)
      Currentweek(allmodels)
      ████ 41%used
      Resets\(weeklyText.string(from: weeklyReset))(Asia/Tokyo)
      Current week (Fable)
      90%used
      Resets\(weeklyText.string(from: weeklyReset))(Asia/Tokyo)
      """.utf8)
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history.json"),
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: RenderedUsagePTYProbe(output: output),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now)

    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.fiveHour?.remainingPercent == 68)
    #expect(snapshot.weekly?.remainingPercent == 59)
    #expect(snapshot.fiveHour?.resetAt != nil)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.weekly?.isResetEstimated == false)
  }

  @Test("PTY path never joins Desktop utilization to an unverified cache account")
  func noCrossAccountMerge() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let formatter = ISO8601DateFormatter()
    let historyData = try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-other-account",
          "u": ["fh": 20.0, "sd": 30.0],
        ]
      ]
    ])
    let cacheData = try JSONSerialization.data(withJSONObject: [
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000),
        "utilization": [
          "five_hour": [
            "utilization": 70.0,
            "resets_at": formatter.string(from: now.addingTimeInterval(10_000)),
          ],
          "seven_day": [
            "utilization": 80.0,
            "resets_at": formatter.string(from: now.addingTimeInterval(300_000)),
          ],
        ],
      ]
    ])
    try historyData.write(to: history)
    try cacheData.write(to: cache)
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: CacheUpdatingPTYProbe(cacheURL: cache, shouldUpdate: false),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 70)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.sourceState == .attemptFailed)
  }

  @Test("A failed probe retains a previous exact CLI observation")
  func retainsPreviousCLIObservation() {
    let now = Date()
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 63, durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)),
      fiveHour: QuotaWindow(
        remainingPercent: 42, durationSeconds: 18_000,
        resetAt: now.addingTimeInterval(8_000)),
      lastAttemptAt: now.addingTimeInterval(-600),
      sourceState: .observationSucceeded
    )
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: URL(fileURLWithPath: "/missing-history"),
      cacheURL: URL(fileURLWithPath: "/missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .timeout(stage: .usageSent))
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.fiveHour == previous.fiveHour)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.lastAttemptAt == now)
    #expect(snapshot.sourceState == .attemptTimedOut)
    #expect(snapshot.errorCode == .timeout)
  }

  @Test("A failed probe retains a previous exact local-cache observation")
  func retainsPreviousCacheObservation() {
    let now = Date()
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeLocalCache,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 63, durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)),
      fiveHour: QuotaWindow(
        remainingPercent: 42, durationSeconds: 18_000,
        resetAt: now.addingTimeInterval(8_000)),
      sourceState: .observationSucceeded
    )
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: URL(fileURLWithPath: "/missing-history"),
      cacheURL: URL(fileURLWithPath: "/missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .timeout(stage: .usageSent))
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeLocalCache)
    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.fiveHour == previous.fiveHour)
    #expect(snapshot.sourceState == .attemptTimedOut)
  }

  @Test("Desktop history remains successful when Claude Code is not installed")
  func desktopOnlyWithoutCLI() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let data = try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 20.0, "sd": 30.0],
        ]
      ]
    ])
    try data.write(to: history)
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: nil,
      historyURL: history,
      cacheURL: root.appendingPathComponent("missing-cache"),
      ptyProbeEnabled: true
    ).refresh(previous: nil, now: now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.errorCode == nil)
    #expect(snapshot.weekly?.resetAt == nil)
  }

  @Test("Desktop history keeps exact cache resets when Claude Code is not installed")
  func desktopOnlyWithoutCLIMergesCacheReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let formatter = ISO8601DateFormatter()
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 20.0, "sd": 30.0],
        ]
      ]
    ]).write(to: history)
    try JSONSerialization.data(withJSONObject: [
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000),
        "utilization": [
          "five_hour": [
            "utilization": 25.0,
            "resets_at": formatter.string(from: now.addingTimeInterval(10_000)),
          ],
          "seven_day": [
            "utilization": 35.0,
            "resets_at": formatter.string(from: now.addingTimeInterval(300_000)),
          ],
        ],
      ]
    ]).write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true
    ).refresh(previous: nil, now: now)

    #expect(snapshot.source == .claudeLocalMerged)
    #expect(snapshot.weekly?.remainingPercent == 70)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.fiveHour?.remainingPercent == 80)
    #expect(snapshot.fiveHour?.resetAt != nil)
    #expect(snapshot.sourceState == .observationSucceeded)
  }

  @Test("Authentication prompts are exposed without discarding the last exact observation")
  func authenticationRequired() {
    let now = Date()
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 63, durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)),
      sourceState: .observationSucceeded
    )
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: URL(fileURLWithPath: "/missing-history"),
      cacheURL: URL(fileURLWithPath: "/missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .authenticationRequired)
  }
}
