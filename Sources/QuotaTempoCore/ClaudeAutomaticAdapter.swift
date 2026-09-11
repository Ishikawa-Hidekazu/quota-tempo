import Foundation

public enum ClaudeAutomaticAdapterError: Error, Equatable {
  case sourceUnavailable
  case unsafePath
  case inputTooLarge
  case invalidInput
}

public protocol BoundedLocalDataReading: Sendable {
  func read(from url: URL, limit: Int) throws -> Data
}

public struct FileBoundedLocalDataReader: BoundedLocalDataReading {
  public init() {}

  public func read(from url: URL, limit: Int) throws -> Data {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else {
      throw ClaudeAutomaticAdapterError.sourceUnavailable
    }
    guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: manager) else {
      throw ClaudeAutomaticAdapterError.unsafePath
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw ClaudeAutomaticAdapterError.unsafePath }
    guard let size = values.fileSize, size <= limit else {
      throw ClaudeAutomaticAdapterError.inputTooLarge
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw ClaudeAutomaticAdapterError.inputTooLarge }
    return data
  }
}

public enum ClaudeCLIExecutableResolver {
  public static func resolve(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> URL? {
    let candidates = [
      homeDirectory.appendingPathComponent(".local/bin/claude"),
      URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
      URL(fileURLWithPath: "/usr/local/bin/claude"),
      URL(fileURLWithPath: "/usr/bin/claude"),
    ]
    for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
      let resolved = candidate.resolvingSymlinksInPath()
      guard
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
        values.isRegularFile == true,
        fileManager.isExecutableFile(atPath: resolved.path)
      else { continue }
      return resolved
    }
    return nil
  }
}

public struct ClaudeAutomaticAdapter: Sendable {
  public static let minimumRefreshInterval: TimeInterval = 5 * 60
  public static let localCacheMaximumAge: TimeInterval = 15 * 60
  public static let historyInputLimit = 8 * 1_024 * 1_024
  public static let cacheInputLimit = 8 * 1_024 * 1_024
  private static let minimumCapturedAt = Date(timeIntervalSince1970: 0)

  private let reader: any BoundedLocalDataReading
  private let runner: any BoundedProcessRunning
  private let cliExecutable: URL?
  private let historyURL: URL
  private let cacheURL: URL
  private let cliFallbackEnabled: Bool
  private let probeDirectory: URL

  public init(
    reader: any BoundedLocalDataReading = FileBoundedLocalDataReader(),
    runner: any BoundedProcessRunning = FoundationBoundedProcessRunner(
      timeout: 10,
      outputLimit: 1_048_576,
      environmentOverrides: [
        "DISABLE_AUTOUPDATER": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
      ]
    ),
    cliExecutable: URL? = ClaudeCLIExecutableResolver.resolve(),
    historyURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json"),
    cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude.json"),
    cliFallbackEnabled: Bool = false,
    probeDirectory: URL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("QuotaTempo/ClaudeProbe", isDirectory: true)
  ) {
    self.reader = reader
    self.runner = runner
    self.cliExecutable = cliExecutable
    self.historyURL = historyURL
    self.cacheURL = cacheURL
    self.cliFallbackEnabled = cliFallbackEnabled
    self.probeDirectory = probeDirectory
  }

  public func refresh(previous: ProviderSnapshot?, now: Date) -> ProviderSnapshot {
    let historyRead = Self.captureLocalRead { try self.readHistory(now: now) }
    let cacheRead = Self.captureLocalRead { try self.readCache(now: now) }
    let history = historyRead.snapshot
    let cache = cacheRead.snapshot
    let local = Self.localCandidate(history: history, cache: cache)

    if let local, Self.isCompleteAndFresh(local, now: now) {
      return Self.success(
        Self.preferredObservation(local: local, previous: previous, now: now) ?? local,
        attemptedAt: now
      )
    }

    guard self.cliFallbackEnabled else {
      if let retained = Self.preferredObservation(local: local, previous: previous, now: now) {
        // A valid current local observation is sufficient. Claude Desktop-only users do not
        // necessarily have the sibling Claude Code cache, so its absence is not a refresh failure.
        let localError = Self.preferredLocalError(historyRead.error, cacheRead.error)
        if local != nil, localError == nil || localError == .sourceUnavailable {
          return Self.success(retained, attemptedAt: now)
        }
        if let error = localError {
          return ProviderSnapshot(
            provider: .claude,
            source: retained.source,
            capturedAt: retained.capturedAt,
            weekly: retained.weekly,
            fiveHour: retained.fiveHour,
            lastAttemptAt: now,
            sourceState: .attemptFailed,
            errorCode: Self.acquisitionError(for: error)
          )
        }
        return Self.success(retained, attemptedAt: now)
      }
      return ProviderSnapshot(
        provider: .claude,
        source: .claudeDesktopHistory,
        capturedAt: nil,
        weekly: nil,
        fiveHour: nil,
        lastAttemptAt: now,
        sourceState: .attemptFailed,
        errorCode: Self.preferredLocalError(historyRead.error, cacheRead.error)
          .map(Self.acquisitionError(for:)) ?? .sourceUnavailable
      )
    }

    do {
      return Self.success(try self.readCLI(now: now), attemptedAt: now)
    } catch BoundedProcessError.timeout {
      return self.fallback(
        local: local,
        previous: previous,
        now: now,
        state: .attemptTimedOut,
        error: .timeout
      )
    } catch BoundedProcessError.outputLimitExceeded {
      return self.fallback(
        local: local,
        previous: previous,
        now: now,
        state: .attemptFailed,
        error: .outputLimitExceeded
      )
    } catch {
      return self.fallback(
        local: local,
        previous: previous,
        now: now,
        state: .attemptFailed,
        error: .sourceUnavailable
      )
    }
  }

  public static func shouldRefresh(lastAttemptAt: Date?, now: Date) -> Bool {
    guard let lastAttemptAt else { return true }
    return now.timeIntervalSince(lastAttemptAt) >= self.minimumRefreshInterval
  }

  private static func captureLocalRead(
    _ operation: () throws -> ProviderSnapshot
  ) -> (snapshot: ProviderSnapshot?, error: ClaudeAutomaticAdapterError?) {
    do {
      return (try operation(), nil)
    } catch let error as ClaudeAutomaticAdapterError {
      return (nil, error)
    } catch {
      return (nil, .sourceUnavailable)
    }
  }

  private static func preferredLocalError(
    _ first: ClaudeAutomaticAdapterError?,
    _ second: ClaudeAutomaticAdapterError?
  ) -> ClaudeAutomaticAdapterError? {
    let errors = [first, second].compactMap { $0 }
    for candidate in [
      ClaudeAutomaticAdapterError.unsafePath,
      .inputTooLarge,
      .invalidInput,
      .sourceUnavailable,
    ] where errors.contains(candidate) {
      return candidate
    }
    return nil
  }

  private static func acquisitionError(
    for error: ClaudeAutomaticAdapterError
  ) -> AcquisitionErrorCode {
    switch error {
    case .sourceUnavailable: .sourceUnavailable
    case .unsafePath: .unsafePath
    case .inputTooLarge: .inputTooLarge
    case .invalidInput: .invalidResponse
    }
  }

  private func fallback(
    local: ProviderSnapshot?,
    previous: ProviderSnapshot?,
    now: Date,
    state: SourceState,
    error: AcquisitionErrorCode
  ) -> ProviderSnapshot {
    if let retained = Self.preferredObservation(local: local, previous: previous, now: now) {
      return ProviderSnapshot(
        provider: .claude,
        source: retained.source,
        capturedAt: retained.capturedAt,
        weekly: retained.weekly,
        fiveHour: retained.fiveHour,
        lastAttemptAt: now,
        sourceState: state,
        errorCode: error
      )
    }
    return AcquisitionRecords.preservingFailure(
      previous: nil,
      provider: .claude,
      source: .claudeCLI,
      attemptedAt: now,
      state: state,
      error: error
    )
  }

  private static func success(_ snapshot: ProviderSnapshot, attemptedAt: Date) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .claude,
      source: snapshot.source,
      capturedAt: snapshot.capturedAt,
      weekly: snapshot.weekly,
      fiveHour: snapshot.fiveHour,
      lastAttemptAt: attemptedAt,
      sourceState: .observationSucceeded
    )
  }

  private static func preferredObservation(
    local: ProviderSnapshot?,
    previous: ProviderSnapshot?,
    now: Date
  ) -> ProviderSnapshot? {
    guard let local else { return previous }
    guard let previous else { return local }
    guard let localCapturedAt = local.capturedAt else { return previous }
    guard let previousCapturedAt = previous.capturedAt else { return local }
    guard localCapturedAt > previousCapturedAt else { return previous }

    let mergedWeekly = Self.mergedWindow(
      latest: local.weekly,
      resetCarrier: previous.weekly,
      latestCapturedAt: localCapturedAt,
      resetCapturedAt: previousCapturedAt
    )
    let weekly = Self.projectedWeeklyWindow(
      latest: mergedWeekly,
      resetCarrier: previous.weekly,
      latestCapturedAt: localCapturedAt,
      resetCapturedAt: previousCapturedAt,
      now: now
    )

    return ProviderSnapshot(
      provider: .claude,
      source: local.source,
      capturedAt: localCapturedAt,
      weekly: weekly,
      fiveHour: Self.mergedWindow(
        latest: local.fiveHour,
        resetCarrier: previous.fiveHour,
        latestCapturedAt: localCapturedAt,
        resetCapturedAt: previousCapturedAt
      ),
      sourceState: local.sourceState
    )
  }

  private static func isCompleteAndFresh(_ snapshot: ProviderSnapshot, now: Date) -> Bool {
    guard let capturedAt = snapshot.capturedAt,
      let weeklyReset = snapshot.weekly?.resetAt,
      weeklyReset > now
    else { return false }
    let age = now.timeIntervalSince(capturedAt)
    return age >= 0 && age <= self.localCacheMaximumAge
  }

  private static func localCandidate(
    history: ProviderSnapshot?,
    cache: ProviderSnapshot?
  ) -> ProviderSnapshot? {
    guard let history else { return cache }
    guard let cache else { return history }
    guard
      let historyCapturedAt = history.capturedAt,
      let cacheCapturedAt = cache.capturedAt,
      historyCapturedAt >= cacheCapturedAt
    else { return cache }

    let weekly = Self.mergedWindow(
      latest: history.weekly,
      resetCarrier: cache.weekly,
      latestCapturedAt: historyCapturedAt,
      resetCapturedAt: cacheCapturedAt
    )
    let fiveHour = Self.mergedWindow(
      latest: history.fiveHour,
      resetCarrier: cache.fiveHour,
      latestCapturedAt: historyCapturedAt,
      resetCapturedAt: cacheCapturedAt
    )
    let transferredReset =
      (history.weekly?.resetAt == nil && weekly?.resetAt != nil)
      || (history.fiveHour?.resetAt == nil && fiveHour?.resetAt != nil)
    guard transferredReset else { return history }
    return ProviderSnapshot(
      provider: .claude,
      source: .claudeLocalMerged,
      capturedAt: historyCapturedAt,
      weekly: weekly,
      fiveHour: fiveHour,
      sourceState: .observationSucceeded
    )
  }

  private static func mergedWindow(
    latest: QuotaWindow?,
    resetCarrier: QuotaWindow?,
    latestCapturedAt: Date,
    resetCapturedAt: Date
  ) -> QuotaWindow? {
    guard let latest else { return nil }
    guard latest.resetAt == nil else { return latest }
    guard
      let resetCarrier,
      latest.durationSeconds == resetCarrier.durationSeconds,
      let resetAt = resetCarrier.resetAt,
      Self.isObservation(
        latestCapturedAt,
        withinWindowEndingAt: resetAt,
        duration: resetCarrier.durationSeconds
      ),
      Self.isObservation(
        resetCapturedAt,
        withinWindowEndingAt: resetAt,
        duration: resetCarrier.durationSeconds
      )
    else { return latest }
    return QuotaWindow(
      remainingPercent: latest.remainingPercent,
      durationSeconds: latest.durationSeconds,
      resetAt: resetAt,
      resetAtIsEstimated: resetCarrier.isResetEstimated
    )
  }

  private static func projectedWeeklyWindow(
    latest: QuotaWindow?,
    resetCarrier: QuotaWindow?,
    latestCapturedAt: Date,
    resetCapturedAt: Date,
    now: Date
  ) -> QuotaWindow? {
    guard let latest else { return nil }
    guard latest.resetAt == nil else { return latest }
    guard
      let resetCarrier,
      !resetCarrier.isResetEstimated,
      latest.durationSeconds == resetCarrier.durationSeconds,
      let confirmedReset = resetCarrier.resetAt,
      Self.isObservation(
        resetCapturedAt,
        withinWindowEndingAt: confirmedReset,
        duration: resetCarrier.durationSeconds
      )
    else { return latest }

    let projectedReset = confirmedReset.addingTimeInterval(resetCarrier.durationSeconds)
    guard
      confirmedReset <= now,
      now < projectedReset,
      latestCapturedAt >= confirmedReset,
      latestCapturedAt < projectedReset,
      latest.remainingPercent > resetCarrier.remainingPercent
    else { return latest }

    return QuotaWindow(
      remainingPercent: latest.remainingPercent,
      durationSeconds: latest.durationSeconds,
      resetAt: projectedReset,
      resetAtIsEstimated: true
    )
  }

  private static func isObservation(
    _ capturedAt: Date,
    withinWindowEndingAt resetAt: Date,
    duration: TimeInterval
  ) -> Bool {
    capturedAt >= resetAt.addingTimeInterval(-duration) && capturedAt < resetAt
  }

  private func readHistory(now: Date) throws -> ProviderSnapshot {
    let data = try self.reader.read(from: self.historyURL, limit: Self.historyInputLimit)
    let root: HistoryRoot
    do { root = try JSONDecoder().decode(HistoryRoot.self, from: data) } catch {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    guard let sample = root.samples.max(by: { $0.timestampMilliseconds < $1.timestampMilliseconds })
    else { throw ClaudeAutomaticAdapterError.sourceUnavailable }
    let capturedAt = Date(timeIntervalSince1970: Double(sample.timestampMilliseconds) / 1_000)
    guard capturedAt >= Self.minimumCapturedAt, capturedAt <= now.addingTimeInterval(1) else {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    let weekly = Self.validatedWindow(
      utilization: sample.usage.sevenDay,
      duration: 7 * 24 * 60 * 60,
      resetAt: nil,
      now: now
    )
    let fiveHour = Self.validatedWindow(
      utilization: sample.usage.fiveHour,
      duration: 5 * 60 * 60,
      resetAt: nil,
      now: now
    )
    guard weekly != nil || fiveHour != nil else {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    return ProviderSnapshot(
      provider: .claude,
      source: .claudeDesktopHistory,
      capturedAt: capturedAt,
      weekly: weekly,
      fiveHour: fiveHour,
      sourceState: .observationSucceeded
    )
  }

  private func readCache(now: Date) throws -> ProviderSnapshot {
    let data = try self.reader.read(from: self.cacheURL, limit: Self.cacheInputLimit)
    let root: CacheRoot
    do { root = try JSONDecoder().decode(CacheRoot.self, from: data) } catch {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    guard let cache = root.cachedUsageUtilization else {
      throw ClaudeAutomaticAdapterError.sourceUnavailable
    }
    let capturedAt = Date(timeIntervalSince1970: Double(cache.fetchedAtMilliseconds) / 1_000)
    guard capturedAt >= Self.minimumCapturedAt, capturedAt <= now.addingTimeInterval(1) else {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    let weekly = Self.validatedWindow(
      cache.utilization.sevenDay,
      duration: 7 * 24 * 60 * 60,
      now: now
    )
    let fiveHour = Self.validatedWindow(
      cache.utilization.fiveHour,
      duration: 5 * 60 * 60,
      now: now
    )
    guard weekly != nil || fiveHour != nil else {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    return ProviderSnapshot(
      provider: .claude,
      source: .claudeLocalCache,
      capturedAt: capturedAt,
      weekly: weekly,
      fiveHour: fiveHour,
      sourceState: .observationSucceeded
    )
  }

  private func readCLI(now: Date) throws -> ProviderSnapshot {
    guard let cliExecutable else { throw ClaudeAutomaticAdapterError.sourceUnavailable }
    guard
      !LocalPathSafety.containsSymlink(
        atOrAbove: self.probeDirectory,
        fileManager: .default
      )
    else { throw ClaudeAutomaticAdapterError.unsafePath }
    try FileManager.default.createDirectory(
      at: self.probeDirectory,
      withIntermediateDirectories: true
    )
    let result = try self.runner.run(
      executable: cliExecutable,
      arguments: [
        "-p",
        "--no-session-persistence",
        "--verbose",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--safe-mode",
        "--setting-sources",
        "",
        "--tools",
        "",
        "--no-chrome",
        "--settings",
        #"{"disableAllHooks":true}"#,
      ],
      stdin: Self.cliRequest,
      currentDirectory: self.probeDirectory
    )
    guard result.exitCode == 0 else { throw ClaudeAutomaticAdapterError.sourceUnavailable }
    let decoder = JSONDecoder()
    let envelope = result.stdout.split(separator: 0x0A).lazy.compactMap {
      try? decoder.decode(ControlEnvelope.self, from: Data($0))
    }.first {
      $0.type == "control_response" && $0.response?.requestID == "quota-tempo-usage"
    }
    guard let response = envelope?.response,
      response.subtype == "success",
      let limits = response.response?.rateLimits
    else { throw ClaudeAutomaticAdapterError.invalidInput }
    let weekly = Self.validatedWindow(limits.sevenDay, duration: 7 * 24 * 60 * 60, now: now)
    let fiveHour = Self.validatedWindow(limits.fiveHour, duration: 5 * 60 * 60, now: now)
    guard weekly != nil || fiveHour != nil else {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    return ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: now,
      weekly: weekly,
      fiveHour: fiveHour,
      sourceState: .observationSucceeded
    )
  }

  private static func window(
    _ input: UsageWindow?,
    duration: TimeInterval,
    now: Date
  ) throws -> QuotaWindow? {
    guard let input else { return nil }
    let resetAt: Date?
    if let reset = input.resetsAt {
      if let parsed = Self.parseISO8601(reset),
        parsed > now,
        parsed.timeIntervalSince(now) <= duration
      {
        resetAt = parsed
      } else {
        resetAt = nil
      }
    } else {
      resetAt = nil
    }
    return try Self.window(
      utilization: input.utilization,
      duration: duration,
      resetAt: resetAt,
      now: now
    )
  }

  private static func validatedWindow(
    _ input: UsageWindow?,
    duration: TimeInterval,
    now: Date
  ) -> QuotaWindow? {
    try? self.window(input, duration: duration, now: now)
  }

  private static func validatedWindow(
    utilization: Double?,
    duration: TimeInterval,
    resetAt: Date?,
    now: Date
  ) -> QuotaWindow? {
    try? self.window(
      utilization: utilization,
      duration: duration,
      resetAt: resetAt,
      now: now
    )
  }

  private static func window(
    utilization: Double?,
    duration: TimeInterval,
    resetAt: Date?,
    now _: Date
  ) throws -> QuotaWindow? {
    guard let utilization else { return nil }
    guard utilization.isFinite, (0...100).contains(utilization) else {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    return QuotaWindow(
      remainingPercent: 100 - utilization,
      durationSeconds: duration,
      resetAt: resetAt
    )
  }

  private static func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  static let cliRequest = Data(
    """
    {"type":"control_request","request_id":"quota-tempo-usage","request":{"subtype":"get_usage"}}

    """.utf8
  )
}

private struct HistoryRoot: Decodable {
  let samples: [HistorySample]
}

private struct HistorySample: Decodable {
  let timestampMilliseconds: Int64
  let usage: HistoryUsage

  enum CodingKeys: String, CodingKey {
    case timestampMilliseconds = "t"
    case usage = "u"
  }
}

private struct HistoryUsage: Decodable {
  let fiveHour: Double?
  let sevenDay: Double?

  enum CodingKeys: String, CodingKey {
    case fiveHour = "fh"
    case sevenDay = "sd"
  }
}

private struct CacheRoot: Decodable {
  let cachedUsageUtilization: CachedUsage?
}

private struct CachedUsage: Decodable {
  let fetchedAtMilliseconds: Int64
  let utilization: UsageLimits

  enum CodingKeys: String, CodingKey {
    case fetchedAtMilliseconds = "fetchedAtMs"
    case utilization
  }
}

private struct UsageLimits: Decodable {
  let fiveHour: UsageWindow?
  let sevenDay: UsageWindow?

  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
  }
}

private struct UsageWindow: Decodable {
  let utilization: Double
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }
}

private struct ControlEnvelope: Decodable {
  let type: String
  let response: ControlResponse?
}

private struct ControlResponse: Decodable {
  let requestID: String?
  let subtype: String?
  let response: ControlPayload?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case subtype
    case response
  }
}

private struct ControlPayload: Decodable {
  let rateLimits: UsageLimits?

  enum CodingKeys: String, CodingKey {
    case rateLimits = "rate_limits"
  }
}
