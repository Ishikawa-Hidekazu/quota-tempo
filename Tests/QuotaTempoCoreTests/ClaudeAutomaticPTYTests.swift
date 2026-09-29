import CryptoKit
import Foundation
import Testing

@testable import QuotaTempoCore

private func accountFingerprint(_ value: String) -> String {
  ownerFingerprint(account: value, organization: value)
}

private func accountFingerprintValue(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func ownerFingerprint(account: String, organization: String) -> String {
  SHA256.hash(data: Data("claude-owner-v1:\(account):\(organization)".utf8))
    .map { String(format: "%02x", $0) }.joined()
}

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

private final class TransientDesktopConfigReader: BoundedLocalDataReading, @unchecked Sendable {
  private let lock = NSLock()
  private var configReads = 0

  func read(from url: URL, limit: Int) throws -> Data {
    if url.lastPathComponent == "config.json" {
      lock.lock()
      configReads += 1
      let count = configReads
      lock.unlock()
      if count > 1 { throw ClaudeAutomaticAdapterError.sourceUnavailable }
    }
    return try FileBoundedLocalDataReader().read(from: url, limit: limit)
  }
}

private struct FailingUsagePTYProbe: ClaudeUsageProbing {
  let error: ClaudeUsagePTYProbeError

  func capture(executable: URL, workingDirectory: URL) throws -> Data { throw error }
}

private struct AccountSwitchingUsagePTYProbe: ClaudeUsageProbing {
  let cacheURL: URL
  let output: Data

  func capture(executable: URL, workingDirectory: URL) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-b", "organizationUuid": "shared-org"]
    ])
    try data.write(to: cacheURL, options: .atomic)
    return output
  }
}

private struct FailingAccountSwitchingUsagePTYProbe: ClaudeUsageProbing {
  let cacheURL: URL

  func capture(executable: URL, workingDirectory: URL) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-b", "organizationUuid": "shared-org"]
    ])
    try data.write(to: cacheURL, options: .atomic)
    throw ClaudeUsagePTYProbeError.authenticationRequired
  }
}

private struct DesktopAccountSwitchingPTYProbe: ClaudeUsageProbing {
  let configURL: URL

  func capture(executable: URL, workingDirectory: URL) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-b"
    ]).write(to: configURL, options: .atomic)
    throw ClaudeUsagePTYProbeError.authenticationRequired
  }
}

private struct AdapterFailingUsagePTYProbe: ClaudeUsageProbing {
  let error: ClaudeAutomaticAdapterError

  func capture(executable: URL, workingDirectory: URL) throws -> Data { throw error }
}

private struct ProcessFailingUsagePTYProbe: ClaudeUsageProbing {
  let error: BoundedProcessError

  func capture(executable: URL, workingDirectory: URL) throws -> Data { throw error }
}

private final class CLIResolutionSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [URL]

  init(_ values: [URL]) { self.values = values }

  func next() -> URL? {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard !self.values.isEmpty else { return nil }
    return self.values.removeFirst()
  }
}

private final class ExecutableRecordingPTYProbe: @unchecked Sendable, ClaudeUsageProbing {
  private let lock = NSLock()
  private(set) var executables: [URL] = []
  let output: Data

  init(output: Data) { self.output = output }

  func capture(executable: URL, workingDirectory: URL) throws -> Data {
    self.lock.lock()
    self.executables.append(executable)
    self.lock.unlock()
    return self.output
  }
}

struct ClaudeAutomaticPTYTests {
  @Test("A signed-in CLI result survives a different Desktop account")
  func cliResultDoesNotRequireDesktopAccountMatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "cli-account", "organizationUuid": "cli-org"]
    ]).write(to: cache)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "desktop-account"
    ]).write(to: config)
    let session = DateFormatter()
    session.locale = Locale(identifier: "en_US_POSIX")
    session.timeZone = TimeZone(identifier: "UTC")
    session.dateFormat = "h:mma"
    let weekly = DateFormatter()
    weekly.locale = Locale(identifier: "en_US_POSIX")
    weekly.timeZone = TimeZone(identifier: "UTC")
    weekly.dateFormat = "MMM d 'at' h:mma"
    let output = Data(
      """
      Currentsession
      32%used
      Resets\(session.string(from: now.addingTimeInterval(7_200)))(UTC)
      Currentweek(allmodels)
      41%used
      Resets\(weekly.string(from: now.addingTimeInterval(259_200)))(UTC)
      """.utf8)
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history.json"),
      cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: RenderedUsagePTYProbe(output: output),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(
      snapshot.claudeAccountFingerprint
        == ownerFingerprint(
          account: "cli-account", organization: "cli-org"))
  }

  @Test("A temporary Desktop config failure does not block a signed-in Claude Code CLI")
  func missingDesktopConfigStillAllowsCLI() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "cli-account", "organizationUuid": "cli-org"]
    ]).write(to: cache)
    let weekly = DateFormatter()
    weekly.locale = Locale(identifier: "en_US_POSIX")
    weekly.timeZone = TimeZone(identifier: "UTC")
    weekly.dateFormat = "MMM d 'at' h:mma"
    let session = DateFormatter()
    session.locale = Locale(identifier: "en_US_POSIX")
    session.timeZone = TimeZone(identifier: "UTC")
    session.dateFormat = "h:mma"
    let output = Data(
      """
      Currentsession
      32%used
      Resets\(session.string(from: now.addingTimeInterval(7_200)))(UTC)
      Currentweek(allmodels)
      41%used
      Resets\(weekly.string(from: now.addingTimeInterval(259_200)))(UTC)
      """.utf8)
    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopHistory,
      capturedAt: now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 90, durationSeconds: 7 * 24 * 60 * 60,
        resetAt: now.addingTimeInterval(200_000)),
      sourceState: .observationSucceeded,
      claudeDesktopPrincipalFingerprint: accountFingerprintValue("desktop-account"))

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history.json"),
      cacheURL: cache, desktopConfigURL: root.appendingPathComponent("missing-config.json"),
      ptyProbeEnabled: true, ptyProbe: RenderedUsagePTYProbe(output: output),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: previous, now: now, forceLiveProbe: true)
    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.claudeAccountFingerprint != nil)
    #expect(snapshot.claudeDesktopPrincipalFingerprint == nil)
  }

  @Test("A Desktop config reread failure cannot discard an independently verified CLI result")
  func configRereadFailureStillAllowsCLI() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "cli-account", "organizationUuid": "cli-org"]
    ]).write(to: cache)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "cli-account"
    ]).write(to: config)
    let session = DateFormatter()
    session.locale = Locale(identifier: "en_US_POSIX")
    session.timeZone = TimeZone(identifier: "UTC")
    session.dateFormat = "h:mma"
    let weekly = DateFormatter()
    weekly.locale = Locale(identifier: "en_US_POSIX")
    weekly.timeZone = TimeZone(identifier: "UTC")
    weekly.dateFormat = "MMM d 'at' h:mma"
    let output = Data(
      """
      Currentsession
      32%used
      Resets\(session.string(from: now.addingTimeInterval(7_200)))(UTC)
      Currentweek(allmodels)
      41%used
      Resets\(weekly.string(from: now.addingTimeInterval(259_200)))(UTC)
      """.utf8)
    let snapshot = ClaudeAutomaticAdapter(
      reader: TransientDesktopConfigReader(),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history.json"),
      cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true, ptyProbe: RenderedUsagePTYProbe(output: output),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now, forceLiveProbe: true)
    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.claudeAccountFingerprint != nil)
  }

  @Test("A partial Desktop history does not erase a verified current weekly reset")
  func partialDesktopHistoryPreservesWeeklyReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")
    let cacheAt = now.addingTimeInterval(-3_600)
    let reset = now.addingTimeInterval(200_000)
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "shared-org", "u": ["fh": 10.0],
        ]
      ]
    ]).write(to: history)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"],
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(cacheAt.timeIntervalSince1970 * 1_000),
        "utilization": [
          "seven_day": [
            "utilization": 69.0,
            "resets_at": ISO8601DateFormatter().string(from: reset),
          ]
        ],
      ],
    ]).write(to: cache)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-a"
    ]).write(to: config)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history, cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: nil, now: now, forceLiveProbe: true)

    #expect(snapshot.weekly?.remainingPercent == 31)
    #expect(abs(snapshot.weekly!.resetAt!.timeIntervalSince(reset)) < 1)
    #expect(snapshot.fiveHour?.remainingPercent == 90)
    #expect(abs(snapshot.capturedAt!.timeIntervalSince(cacheAt)) < 1)
    #expect(snapshot.sourceState == .attemptFailed)
  }

  @Test("A weekly-only Desktop sample keeps a recent verified five-hour reset")
  func weeklyOnlyDesktopHistoryPreservesRecentSession() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")
    let fiveHourReset = now.addingTimeInterval(10_000)
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "shared-org", "u": ["sd": 80.0],
        ]
      ]
    ]).write(to: history)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"],
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000),
        "utilization": [
          "five_hour": [
            "utilization": 40.0,
            "resets_at": ISO8601DateFormatter().string(from: fiveHourReset),
          ],
          "seven_day": [
            "utilization": 30.0,
            "resets_at": ISO8601DateFormatter().string(
              from: now.addingTimeInterval(200_000)),
          ],
        ],
      ],
    ]).write(to: cache)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-a"
    ]).write(to: config)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history, cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: nil, now: now, forceLiveProbe: true)

    #expect(snapshot.weekly?.remainingPercent == 20)
    #expect(snapshot.fiveHour?.remainingPercent == 60)
    #expect(abs(snapshot.fiveHour!.resetAt!.timeIntervalSince(fiveHourReset)) < 1)
    #expect(snapshot.sourceState == .observationSucceeded)
  }

  @Test("A symlinked Desktop account config stops before the live probe")
  func unsafeDesktopConfigStopsProbe() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let config = root.appendingPathComponent("config.json")
    let target = root.appendingPathComponent("config-target.json")
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-a"
    ]).write(to: target)
    try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "shared-org", "u": ["sd": 91.0],
        ]
      ]
    ]).write(to: history)
    let probe = ExecutableRecordingPTYProbe(output: Data())
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: root.appendingPathComponent("missing-cache.json"),
      desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: probe
    ).refresh(previous: nil, now: now)

    #expect(snapshot.errorCode == .unsafePath)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(probe.executables.isEmpty)
  }

  @Test("Fresh Desktop usage inherits only a same-account, same-window exact reset")
  func verifiedDesktopUsageKeepsCurrentTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")
    let reset = now.addingTimeInterval(200_000)
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "shared-org", "u": ["fh": 43.0, "sd": 91.0],
        ]
      ]
    ]).write(to: history)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"],
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1_000),
        "utilization": [
          "seven_day": [
            "utilization": 69.0,
            "resets_at": ISO8601DateFormatter().string(from: reset),
          ]
        ],
      ],
    ]).write(to: cache)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-a"
    ]).write(to: config)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history, cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: nil, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 9)
    #expect(abs(snapshot.weekly!.resetAt!.timeIntervalSince(reset)) < 1)
    #expect(snapshot.weekly?.isResetEstimated == false)
    #expect(
      snapshot.claudeAccountFingerprint
        == ownerFingerprint(
          account: "account-a", organization: "shared-org"))
    #expect(QuotaPlanner.evaluate(snapshot, now: now).vsTarget != nil)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.errorCode == nil)

    let automatic = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history, cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: nil, now: now)
    #expect(automatic.sourceState == .observationSucceeded)
    #expect(automatic.weekly?.remainingPercent == 9)
  }

  @Test("Desktop-only usage cannot confirm the next weekly reset from an expired cache")
  func desktopOnlyRolloverNeedsNewExactReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(120)
    let afterReset = reset.addingTimeInterval(30)
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")

    func writeHistory(at capturedAt: Date, weeklyUtilization: Double) throws {
      try JSONSerialization.data(withJSONObject: [
        "samples": [
          [
            "t": Int64(capturedAt.timeIntervalSince1970 * 1_000),
            "org": "shared-org", "u": ["sd": weeklyUtilization],
          ]
        ]
      ]).write(to: history, options: .atomic)
    }

    try writeHistory(at: now.addingTimeInterval(-30), weeklyUtilization: 91)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"],
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1_000),
        "utilization": [
          "seven_day": [
            "utilization": 69.0,
            "resets_at": ISO8601DateFormatter().string(from: reset),
          ]
        ],
      ],
    ]).write(to: cache)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-a"
    ]).write(to: config)

    let adapter = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history, cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    )
    let before = adapter.refresh(previous: nil, now: now, forceLiveProbe: true)
    #expect(before.weekly?.resetAt == reset)
    #expect(before.weekly?.isResetEstimated == false)

    try writeHistory(at: afterReset.addingTimeInterval(-5), weeklyUtilization: 5)
    let freshInstall = adapter.refresh(previous: nil, now: afterReset, forceLiveProbe: true)
    #expect(freshInstall.weekly?.remainingPercent == 95)
    #expect(freshInstall.weekly?.resetAt == nil)
    #expect(QuotaPlanner.evaluate(freshInstall, now: afterReset).targetNow == nil)

    let continued = adapter.refresh(previous: before, now: afterReset, forceLiveProbe: true)
    #expect(continued.weekly?.remainingPercent == 95)
    #expect(continued.weekly?.resetAt == nil)
    #expect(continued.sourceState == .attemptFailed)
    #expect(continued.errorCode == .authenticationRequired)
    #expect(QuotaPlanner.evaluate(continued, now: afterReset).targetNow == nil)
  }

  @Test("Desktop reset joins fail closed across account, organization, and quota-window boundaries")
  func desktopResetJoinBoundaries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")
    let reset = now.addingTimeInterval(200_000)
    let cases: [(String, String, Date, Bool)] = [
      ("account-b", "shared-org", reset, false),
      ("account-a", "other-org", reset, false),
      ("account-a", "shared-org", now.addingTimeInterval(604_800 - 60), true),
    ]
    for (desktopAccount, historyOrganization, cacheReset, matchesIdentity) in cases {
      try JSONSerialization.data(withJSONObject: [
        "samples": [
          [
            "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
            "org": historyOrganization, "u": ["sd": 91.0],
          ]
        ]
      ]).write(to: history, options: .atomic)
      try JSONSerialization.data(withJSONObject: [
        "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"],
        "cachedUsageUtilization": [
          "fetchedAtMs": Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1_000),
          "utilization": [
            "seven_day": [
              "utilization": 69.0,
              "resets_at": ISO8601DateFormatter().string(from: cacheReset),
            ]
          ],
        ],
      ]).write(to: cache, options: .atomic)
      try JSONSerialization.data(withJSONObject: [
        "lastKnownAccountUuid": desktopAccount
      ]).write(to: config, options: .atomic)
      let snapshot = ClaudeAutomaticAdapter(
        cliExecutable: URL(fileURLWithPath: "/mock/claude"),
        historyURL: history, cacheURL: cache, desktopConfigURL: config,
        ptyProbeEnabled: true,
        ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
      ).refresh(previous: nil, now: now, forceLiveProbe: true)
      if matchesIdentity {
        #expect(snapshot.weekly?.resetAt == nil)
      } else {
        #expect(abs(snapshot.weekly!.resetAt!.timeIntervalSince(cacheReset)) < 1)
      }
      #expect(snapshot.source == (matchesIdentity ? .claudeDesktopHistory : .claudeLocalCache))
    }
  }

  @Test("A Desktop account change during probe cannot publish the old account's balance")
  func desktopAccountChangeDuringProbe() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    let config = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "shared-org", "u": ["sd": 91.0],
        ]
      ]
    ]).write(to: history)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"],
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1_000),
        "utilization": [
          "seven_day": [
            "utilization": 69.0,
            "resets_at": ISO8601DateFormatter().string(
              from: now.addingTimeInterval(200_000)),
          ]
        ],
      ],
    ]).write(to: cache)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-a"
    ]).write(to: config)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history, cacheURL: cache, desktopConfigURL: config,
      ptyProbeEnabled: true,
      ptyProbe: DesktopAccountSwitchingPTYProbe(configURL: config)
    ).refresh(
      previous: ProviderSnapshot(
        provider: .claude, source: .claudeCLI,
        capturedAt: now.addingTimeInterval(-600),
        weekly: QuotaWindow(
          remainingPercent: 31, durationSeconds: 604_800,
          resetAt: now.addingTimeInterval(200_000)),
        sourceState: .observationSucceeded,
        claudeAccountFingerprint: ownerFingerprint(
          account: "account-a", organization: "shared-org")),
      now: now, forceLiveProbe: true)

    #expect(snapshot.weekly == nil)
    #expect(snapshot.errorCode == .sourceUnavailable)
  }

  @Test("Production Claude adapter resolves the CLI for every refresh")
  func resolvesCLIForEveryRefresh() {
    let first = URL(fileURLWithPath: "/mock/claude-1")
    let second = URL(fileURLWithPath: "/mock/claude-2")
    let sequence = CLIResolutionSequence([first, second])
    let probe = ExecutableRecordingPTYProbe(
      output: Data(
        "Current week (all models)\n20% used\nResets 2026-09-29T05:00:00Z".utf8
      )
    )
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = ClaudeAutomaticAdapter(
      cliExecutable: nil,
      resolveCLIOnRefresh: true,
      cliResolver: { sequence.next() },
      historyURL: root.appendingPathComponent("missing-history.json"),
      cacheURL: root.appendingPathComponent("missing-cache.json"),
      ptyProbeEnabled: true,
      ptyProbe: probe,
      probeDirectory: root.appendingPathComponent("probe")
    )
    let now = ISO8601DateFormatter().date(from: "2026-09-23T00:00:00Z")!

    _ = adapter.refresh(previous: nil, now: now, forceLiveProbe: true)
    _ = adapter.refresh(previous: nil, now: now, forceLiveProbe: true)

    #expect(probe.executables == [first, second])
  }

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
    #expect(snapshot.errorCode == .invalidResponse)
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

  @Test("A failed probe combines newer Desktop usage with a still-current exact reset")
  func failedProbeKeepsCurrentUsageAndVerifiedReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 69.0, "sd": 77.0],
        ]
      ]
    ]).write(to: history)
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": [
        "accountUuid": "desktop-account", "organizationUuid": "desktop-account",
      ]
    ]).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 31,
        durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)
      ),
      fiveHour: QuotaWindow(
        remainingPercent: 42,
        durationSeconds: 18_000,
        resetAt: now.addingTimeInterval(8_000)
      ),
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: accountFingerprint("desktop-account")
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.weekly?.remainingPercent == 31)
    #expect(snapshot.weekly?.resetAt == previous.weekly?.resetAt)
    #expect(snapshot.weekly?.isResetEstimated == false)
    #expect(snapshot.fiveHour?.remainingPercent == 42)
    #expect(snapshot.fiveHour?.resetAt == previous.fiveHour?.resetAt)
    #expect(snapshot.fiveHour?.isResetEstimated == false)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .authenticationRequired)
  }

  @Test("A failed probe recovers an owned exact cache after a legacy unowned snapshot")
  func failedProbeRecoversOwnedCacheAfterLegacySnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 18.0, "sd": 82.0],
        ]
      ]
    ]).write(to: history)
    let cache = root.appendingPathComponent("claude.json")
    let formatter = ISO8601DateFormatter()
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": [
        "accountUuid": "desktop-account", "organizationUuid": "desktop-account",
      ],
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1_000),
        "utilization": [
          "five_hour": ["utilization": 13.0],
          "seven_day": [
            "utilization": 69.0,
            "resets_at": formatter.string(from: now.addingTimeInterval(200_000)),
          ],
        ],
      ],
    ]).write(to: cache)
    let legacy = ProviderSnapshot(
      provider: .claude,
      source: .claudeDesktopHistory,
      capturedAt: now.addingTimeInterval(-30),
      weekly: QuotaWindow(remainingPercent: 18, durationSeconds: 604_800, resetAt: nil),
      fiveHour: QuotaWindow(remainingPercent: 82, durationSeconds: 18_000, resetAt: nil),
      sourceState: .attemptFailed,
      errorCode: .authenticationRequired
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: legacy, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeLocalCache)
    #expect(abs(snapshot.capturedAt!.timeIntervalSince(now.addingTimeInterval(-86_400))) < 1)
    #expect(snapshot.weekly?.remainingPercent == 31)
    #expect(abs(snapshot.weekly!.resetAt!.timeIntervalSince(now.addingTimeInterval(200_000))) < 1)
    #expect(snapshot.claudeAccountFingerprint == accountFingerprint("desktop-account"))
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .authenticationRequired)
  }

  @Test("A failed probe never combines observations from different Claude accounts")
  func failedProbeRejectsCrossAccountReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 69.0, "sd": 77.0],
        ]
      ]
    ]).write(to: history)
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": [
        "accountUuid": "desktop-account", "organizationUuid": "desktop-account",
      ]
    ]).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 31,
        durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)
      ),
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: accountFingerprint("different-account")
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 23)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
  }

  @Test("A failed probe does not combine accounts that share a Claude organization")
  func failedProbeRejectsDifferentPrincipalInSameOrganization() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "shared-org",
          "u": ["fh": 40.0, "sd": 25.0],
        ]
      ]
    ]).write(to: history)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-b", "organizationUuid": "shared-org"]
    ]).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 50,
        durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)
      ),
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: ownerFingerprint(
        account: "account-a", organization: "shared-org")
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.weekly?.remainingPercent == 75)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
  }

  @Test("A legacy exact observation remains intact until ownership can be verified")
  func legacyExactObservationIsNotMergedWithNewUsage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "shared-org",
          "u": ["fh": 40.0, "sd": 25.0],
        ]
      ]
    ]).write(to: history)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"]
    ]).write(to: cache)
    let reset = now.addingTimeInterval(200_000)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(remainingPercent: 50, durationSeconds: 604_800, resetAt: reset),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.weekly?.remainingPercent == 50)
    #expect(snapshot.weekly?.resetAt == reset)
    #expect(snapshot.claudeAccountFingerprint == nil)
  }

  @Test("PTY output is not assigned to an account that changed during capture")
  func ptyAccountSwitchFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"]
    ]).write(to: cache)
    let output = Data(
      "Current session\nCurrent week (all models)\n40% used\nResets 2026-09-29T05:00:00Z".utf8)

    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: Date().addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 50,
        durationSeconds: 604_800,
        resetAt: Date().addingTimeInterval(100_000)
      ),
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: accountFingerprint("account-a"),
      claudeOrganizationFingerprint: accountFingerprintValue("shared-org")
    )
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history"),
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: AccountSwitchingUsagePTYProbe(cacheURL: cache, output: output)
    ).refresh(previous: previous, now: Date(), forceLiveProbe: true)

    #expect(snapshot.weekly == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .sourceUnavailable)
  }

  @Test("A failed PTY probe also discards a snapshot when the account changes")
  func failedPTYAccountSwitchFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-a", "organizationUuid": "shared-org"]
    ]).write(to: cache)
    let now = Date()
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 50,
        durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(100_000)
      ),
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: accountFingerprint("account-a"),
      claudeOrganizationFingerprint: accountFingerprintValue("shared-org")
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history"),
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: FailingAccountSwitchingUsagePTYProbe(cacheURL: cache)
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.weekly == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .sourceUnavailable)
  }

  @Test("Account identity remains available when cached usage changes shape")
  func malformedUsageStillExcludesPreviousAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-b", "organizationUuid": "organization-b"],
      "cachedUsageUtilization": ["fetchedAtMs": "changed-upstream-shape"],
    ]).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: Date().addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 50,
        durationSeconds: 604_800,
        resetAt: Date().addingTimeInterval(100_000)
      ),
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: accountFingerprint("account-a"),
      claudeOrganizationFingerprint: accountFingerprintValue("organization-a")
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history"),
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .authenticationRequired)
    ).refresh(previous: previous, now: Date(), forceLiveProbe: true)

    #expect(snapshot.weekly == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .authenticationRequired)
  }

  @Test("An unowned complete cache cannot replace an owned exact observation")
  func unownedCacheCannotReplaceOwnedExactObservation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let cache = root.appendingPathComponent("claude.json")
    let formatter = ISO8601DateFormatter()
    try JSONSerialization.data(withJSONObject: [
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
        "utilization": [
          "five_hour": [
            "utilization": 20.0,
            "resets_at": formatter.string(from: now.addingTimeInterval(10_000)),
          ],
          "seven_day": [
            "utilization": 25.0,
            "resets_at": formatter.string(from: now.addingTimeInterval(300_000)),
          ],
        ],
      ]
    ]).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 50,
        durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(200_000)
      ),
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: accountFingerprint("account-a"),
      claudeOrganizationFingerprint: accountFingerprintValue("organization-a")
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: root.appendingPathComponent("missing-history"),
      cacheURL: cache,
      ptyProbeEnabled: true
    ).refresh(previous: previous, now: now)

    #expect(snapshot.source == previous.source)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.claudeAccountFingerprint == previous.claudeAccountFingerprint)
  }

  @Test(
    "A failed probe prefers newer local weekly usage when only the old five-hour reset is current")
  func expiredPreviousWeeklyDoesNotHideNewLocalUsage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 20.0, "sd": 30.0],
        ]
      ]
    ]).write(to: history)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 15,
        durationSeconds: 604_800,
        resetAt: now.addingTimeInterval(-60)
      ),
      fiveHour: QuotaWindow(
        remainingPercent: 42,
        durationSeconds: 18_000,
        resetAt: now.addingTimeInterval(8_000)
      ),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: root.appendingPathComponent("missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .timeout(stage: .usageSent))
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 70)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.fiveHour?.remainingPercent == 80)
    #expect(snapshot.sourceState == .attemptTimedOut)
    #expect(snapshot.errorCode == .timeout)
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

  @Test("Owned cache outranks unowned Desktop history when Claude Code is not installed")
  func desktopOnlyWithoutCLIPrefersOwnedCache() throws {
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
      "oauthAccount": [
        "accountUuid": "desktop-account", "organizationUuid": "desktop-account",
      ],
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
      ],
    ]).write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true
    ).refresh(previous: nil, now: now)

    #expect(snapshot.source == .claudeLocalCache)
    #expect(snapshot.weekly?.remainingPercent == 65)
    #expect(abs(snapshot.weekly!.resetAt!.timeIntervalSince(now.addingTimeInterval(300_000))) < 1)
    #expect(snapshot.fiveHour?.remainingPercent == 75)
    #expect(abs(snapshot.fiveHour!.resetAt!.timeIntervalSince(now.addingTimeInterval(10_000))) < 1)
    #expect(snapshot.claudeAccountFingerprint == accountFingerprint("desktop-account"))
    #expect(snapshot.sourceState == .observationSucceeded)
  }

  @Test("Claude Code absence keeps a valid Desktop observation despite a malformed cache")
  func desktopOnlyWithoutCLIIgnoresMalformedOptionalCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 20.0, "sd": 30.0],
        ]
      ]
    ]).write(to: history)
    let cache = root.appendingPathComponent("claude.json")
    try Data("not-json".utf8).write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true
    ).refresh(previous: nil, now: now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 70)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.errorCode == nil)
  }

  @Test("Unsafe local paths fail before the live PTY probe")
  func unsafeLocalPathPreventsPTYProbe() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let realCache = root.appendingPathComponent("real-cache.json")
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 20.0, "sd": 30.0],
        ]
      ]
    ]).write(to: history)
    try Data("{}".utf8).write(to: realCache)
    try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: realCache)
    let probe = ExecutableRecordingPTYProbe(
      output: Data(
        "Current week (all models)\n20% used\nResets 2026-09-29T05:00:00Z".utf8
      )
    )
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
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: probe,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: previous, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.fiveHour == previous.fiveHour)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .unsafePath)
    #expect(probe.executables.isEmpty)
  }

  @Test("Dangling local symlinks fail before the live PTY probe")
  func danglingLocalSymlinkPreventsPTYProbe() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1_000),
          "org": "desktop-account",
          "u": ["fh": 20.0, "sd": 30.0],
        ]
      ]
    ]).write(to: history)
    try FileManager.default.createSymbolicLink(
      at: cache,
      withDestinationURL: root.appendingPathComponent("missing-cache.json")
    )
    let probe = ExecutableRecordingPTYProbe(
      output: Data(
        "Current week (all models)\n20% used\nResets 2026-09-29T05:00:00Z".utf8
      )
    )

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      ptyProbeEnabled: true,
      ptyProbe: probe,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now, forceLiveProbe: true)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 70)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .unsafePath)
    #expect(probe.executables.isEmpty)
  }

  @Test("Late authentication prompt stages remain authentication failures")
  func lateAuthenticationPrompt() {
    let now = Date()
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: URL(fileURLWithPath: "/missing-history"),
      cacheURL: URL(fileURLWithPath: "/missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: FailingUsagePTYProbe(error: .timeout(stage: .authPromptSeen))
    ).refresh(previous: nil, now: now, forceLiveProbe: true)

    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .authenticationRequired)
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

  @Test("PTY failures retain actionable diagnostic categories")
  func diagnosticCategories() {
    let now = Date()
    let base = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: URL(fileURLWithPath: "/missing-history"),
      cacheURL: URL(fileURLWithPath: "/missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: AdapterFailingUsagePTYProbe(error: .invalidInput)
    ).refresh(previous: nil, now: now, forceLiveProbe: true)
    #expect(base.errorCode == .invalidResponse)

    let unsafe = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: URL(fileURLWithPath: "/missing-history"),
      cacheURL: URL(fileURLWithPath: "/missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: AdapterFailingUsagePTYProbe(error: .unsafePath)
    ).refresh(previous: nil, now: now, forceLiveProbe: true)
    #expect(unsafe.errorCode == .unsafePath)

    let launch = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: URL(fileURLWithPath: "/missing-history"),
      cacheURL: URL(fileURLWithPath: "/missing-cache"),
      ptyProbeEnabled: true,
      ptyProbe: ProcessFailingUsagePTYProbe(error: .launchFailed)
    ).refresh(previous: nil, now: now, forceLiveProbe: true)
    #expect(launch.errorCode == .launchFailed)
  }
}
