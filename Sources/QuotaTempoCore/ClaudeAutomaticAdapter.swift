import CryptoKit
import Foundation
import Security

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
    guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: manager) else {
      throw ClaudeAutomaticAdapterError.unsafePath
    }
    guard manager.fileExists(atPath: url.path) else {
      throw ClaudeAutomaticAdapterError.sourceUnavailable
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

public enum ClaudeCLITrustVerifier {
  public static let expectedIdentifier = "com.anthropic.claude-code"
  public static let expectedTeamIdentifier = "Q6L2SF6YDW"
  static let requirement =
    #"anchor apple generic and identifier "com.anthropic.claude-code" and certificate leaf[subject.OU] = "Q6L2SF6YDW""#

  public static func isTrusted(_ executable: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return false }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(self.requirement as CFString, [], &requirement)
        == errSecSuccess,
      let requirement,
      SecStaticCodeCheckValidity(
        staticCode,
        SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
        requirement
      ) == errSecSuccess
    else { return false }

    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [String: Any],
      values[kSecCodeInfoIdentifier as String] as? String == self.expectedIdentifier,
      values[kSecCodeInfoTeamIdentifier as String] as? String == self.expectedTeamIdentifier
    else { return false }
    return true
  }
}

public enum ClaudeCLIExecutableResolver {
  public static func resolve(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    trustCheck: @Sendable (URL) -> Bool = ClaudeCLITrustVerifier.isTrusted,
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
      guard trustCheck(resolved) else { continue }
      return resolved
    }
    return nil
  }
}

public struct ClaudeAutomaticAdapter: Sendable {
  public static let minimumRefreshInterval: TimeInterval = 14 * 60
  public static let localCacheMaximumAge: TimeInterval = 15 * 60
  public static let historyInputLimit = 8 * 1_024 * 1_024
  public static let cacheInputLimit = 8 * 1_024 * 1_024
  public static let desktopConfigInputLimit = 1 * 1_024 * 1_024
  private static let minimumCapturedAt = Date(timeIntervalSince1970: 0)

  private let reader: any BoundedLocalDataReading
  private let runner: any BoundedProcessRunning
  private let cliExecutable: URL?
  private let resolveCLIOnRefresh: Bool
  private let cliResolver: @Sendable () -> URL?
  private let historyURL: URL
  private let cacheURL: URL
  private let desktopConfigURL: URL
  private let cliFallbackEnabled: Bool
  private let ptyProbeEnabled: Bool
  private let ptyProbe: any ClaudeUsageProbing
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
    resolveCLIOnRefresh: Bool = false,
    cliResolver: @escaping @Sendable () -> URL? = { ClaudeCLIExecutableResolver.resolve() },
    historyURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json"),
    cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude.json"),
    desktopConfigURL: URL? = nil,
    cliFallbackEnabled: Bool = false,
    ptyProbeEnabled: Bool = false,
    ptyProbe: any ClaudeUsageProbing = FoundationClaudeUsagePTYProbe(),
    probeDirectory: URL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("QuotaTempo/ClaudeProbe", isDirectory: true)
  ) {
    self.reader = reader
    self.runner = runner
    self.cliExecutable = cliExecutable
    self.resolveCLIOnRefresh = resolveCLIOnRefresh
    self.cliResolver = cliResolver
    self.historyURL = historyURL
    self.cacheURL = cacheURL
    self.desktopConfigURL =
      desktopConfigURL
      ?? historyURL.deletingLastPathComponent().appendingPathComponent("config.json")
    self.cliFallbackEnabled = cliFallbackEnabled
    self.ptyProbeEnabled = ptyProbeEnabled
    self.ptyProbe = ptyProbe
    self.probeDirectory = probeDirectory
  }

  public func refresh(
    previous: ProviderSnapshot?, now: Date, forceLiveProbe: Bool = false
  ) -> ProviderSnapshot {
    let accountBeforeRefresh = try? self.readAccountIdentity()
    let effectivePrevious = Self.previousCompatibleWithCurrentAccount(
      previous, currentAccount: accountBeforeRefresh)
    let historyRead = Self.captureLocalRead { try self.readHistory(now: now) }
    let cacheRead = Self.captureLocalRead { try self.readCache(now: now) }
    let history = historyRead.snapshot
    let cache = cacheRead.snapshot
    let desktopAccount = try? self.readDesktopAccountFingerprint()
    let cliExecutable = self.resolveCLIOnRefresh ? self.cliResolver() : self.cliExecutable
    let livePTYAvailable = self.ptyProbeEnabled && cliExecutable != nil
    let local = Self.localCandidate(
      history: history, cache: cache, currentAccount: accountBeforeRefresh,
      desktopAccountFingerprint: desktopAccount, now: now)
    let localError = Self.preferredLocalError(historyRead.error, cacheRead.error)

    if localError == .unsafePath {
      let failedSource: SnapshotSource =
        historyRead.error == .unsafePath ? .claudeDesktopHistory : .claudeLocalCache
      return self.fallback(
        local: local,
        previous: effectivePrevious,
        now: now,
        state: .attemptFailed,
        error: .unsafePath,
        emptySource: failedSource
      )
    }

    if !forceLiveProbe, let local, Self.isCompleteAndFresh(local, now: now) {
      return Self.success(
        Self.preferredObservation(
          local: local, previous: effectivePrevious, now: now,
          allowMerge: !livePTYAvailable
        ) ?? local,
        attemptedAt: now
      )
    }

    if self.ptyProbeEnabled {
      if cliExecutable == nil, let local {
        let retained =
          Self.preferredObservation(
            local: local, previous: effectivePrevious, now: now, allowMerge: true)
          ?? local
        return Self.success(retained, attemptedAt: now)
      }
      do {
        let observed = try self.readPTY(executable: cliExecutable)
        let accountAfterProbe = try? self.readAccountIdentity()
        guard accountBeforeRefresh == accountAfterProbe else {
          let previousAfterSwitch = Self.previousCompatibleWithCurrentAccount(
            previous, currentAccount: accountAfterProbe)
          return self.fallback(
            local: nil, previous: previousAfterSwitch, now: now,
            state: .attemptFailed, error: .sourceUnavailable
          )
        }
        if let desktopAccountAfterProbe = try? self.readDesktopAccountFingerprint(),
          desktopAccountAfterProbe != accountAfterProbe?.principalFingerprint
        {
          return self.fallback(
            local: nil, previous: nil, now: now,
            state: .attemptFailed, error: .sourceUnavailable)
        }
        let verifiedAccount = accountAfterProbe
        return Self.success(
          Self.withAccountFingerprint(
            observed,
            fingerprint: verifiedAccount?.accountFingerprint,
            organizationFingerprint: verifiedAccount?.organizationFingerprint),
          attemptedAt: now
        )
      } catch ClaudeUsagePTYProbeError.authenticationRequired {
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: .attemptFailed, error: .authenticationRequired
        )
      } catch ClaudeUsagePTYProbeError.timeout(let stage) {
        if stage == .authPromptSeen {
          return self.fallbackAfterPTY(
            local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
            state: .attemptFailed, error: .authenticationRequired
          )
        }
        let invalidResponse: Bool = [
          .cliErrorSeen, .commandPaletteSeen, .unsupportedOption, .sessionConflict,
          .usageLoadFailed, .usageSentAfterSafety, .usageSentWithoutSafety,
        ].contains(stage)
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: invalidResponse ? .attemptFailed : .attemptTimedOut,
          error: invalidResponse ? .invalidResponse : .timeout
        )
      } catch BoundedProcessError.timeout {
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: .attemptTimedOut, error: .timeout
        )
      } catch BoundedProcessError.outputLimitExceeded {
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: .attemptFailed, error: .outputLimitExceeded
        )
      } catch BoundedProcessError.launchFailed, BoundedProcessError.inputWriteFailed {
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: .attemptFailed, error: .launchFailed
        )
      } catch ClaudeAutomaticAdapterError.unsafePath {
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: .attemptFailed, error: .unsafePath
        )
      } catch ClaudeAutomaticAdapterError.invalidInput {
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: .attemptFailed, error: .invalidResponse
        )
      } catch {
        return self.fallbackAfterPTY(
          local: local, previous: previous, accountBeforeProbe: accountBeforeRefresh, now: now,
          state: .attemptFailed, error: .sourceUnavailable
        )
      }
    }

    guard self.cliFallbackEnabled else {
      if let retained = Self.preferredObservation(
        local: local, previous: effectivePrevious, now: now)
      {
        // Each local source is optional when the other has a valid observation.
        if local != nil {
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
            errorCode: Self.acquisitionError(for: error),
            claudeAccountFingerprint: retained.claudeAccountFingerprint,
            claudeOrganizationFingerprint: retained.claudeOrganizationFingerprint
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
        errorCode: localError.map(Self.acquisitionError(for:)) ?? .sourceUnavailable
      )
    }

    do {
      return Self.success(try self.readCLI(now: now), attemptedAt: now)
    } catch BoundedProcessError.timeout {
      return self.fallback(
        local: local,
        previous: effectivePrevious,
        now: now,
        state: .attemptTimedOut,
        error: .timeout
      )
    } catch BoundedProcessError.outputLimitExceeded {
      return self.fallback(
        local: local,
        previous: effectivePrevious,
        now: now,
        state: .attemptFailed,
        error: .outputLimitExceeded
      )
    } catch {
      return self.fallback(
        local: local,
        previous: effectivePrevious,
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
    error: AcquisitionErrorCode,
    emptySource: SnapshotSource = .claudeCLI
  ) -> ProviderSnapshot {
    if let previous, Self.hasCurrentExactReset(previous, now: now) {
      let retained =
        error != .unsafePath
        ? Self.preferredObservation(
          local: local, previous: previous, now: now,
          allowMerge: true
        ) ?? previous
        : previous
      return ProviderSnapshot(
        provider: .claude,
        source: retained.source,
        capturedAt: retained.capturedAt,
        weekly: retained.weekly,
        fiveHour: retained.fiveHour,
        lastAttemptAt: now,
        sourceState: state,
        errorCode: error,
        claudeAccountFingerprint: retained.claudeAccountFingerprint,
        claudeOrganizationFingerprint: retained.claudeOrganizationFingerprint
      )
    }
    if let retained = Self.preferredObservation(
      local: local, previous: previous, now: now,
      allowMerge: !self.ptyProbeEnabled
    ) {
      return ProviderSnapshot(
        provider: .claude,
        source: retained.source,
        capturedAt: retained.capturedAt,
        weekly: retained.weekly,
        fiveHour: retained.fiveHour,
        lastAttemptAt: now,
        sourceState: state,
        errorCode: error,
        claudeAccountFingerprint: retained.claudeAccountFingerprint,
        claudeOrganizationFingerprint: retained.claudeOrganizationFingerprint
      )
    }
    return AcquisitionRecords.preservingFailure(
      previous: nil,
      provider: .claude,
      source: emptySource,
      attemptedAt: now,
      state: state,
      error: error
    )
  }

  private func fallbackAfterPTY(
    local: ProviderSnapshot?,
    previous: ProviderSnapshot?,
    accountBeforeProbe: ClaudeAccountIdentity?,
    now: Date,
    state: SourceState,
    error: AcquisitionErrorCode
  ) -> ProviderSnapshot {
    let accountAfterProbe = try? self.readAccountIdentity()
    let accountChanged = accountBeforeProbe != accountAfterProbe
    let desktopAccountAfterProbe = try? self.readDesktopAccountFingerprint()
    let desktopAccountChanged =
      local?.source == .claudeDesktopHistory
      && local?.claudeAccountFingerprint != nil
      && desktopAccountAfterProbe != accountAfterProbe?.principalFingerprint
    if !accountChanged,
      !desktopAccountChanged,
      error == .authenticationRequired,
      let local,
      local.source == .claudeDesktopHistory,
      Self.hasFreshVerifiedWeeklyTarget(local, now: now)
    {
      return Self.success(local, attemptedAt: now)
    }
    return self.fallback(
      local: accountChanged || desktopAccountChanged ? nil : local,
      previous: desktopAccountChanged
        ? nil
        : Self.previousCompatibleWithCurrentAccount(
          previous, currentAccount: accountAfterProbe),
      now: now,
      state: state,
      error: accountChanged || desktopAccountChanged ? .sourceUnavailable : error
    )
  }

  private static func hasCurrentExactReset(_ snapshot: ProviderSnapshot, now: Date) -> Bool {
    guard let weekly = snapshot.weekly,
      !weekly.isResetEstimated,
      let resetAt = weekly.resetAt
    else { return false }
    return resetAt > now
  }

  private static func success(_ snapshot: ProviderSnapshot, attemptedAt: Date) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .claude,
      source: snapshot.source,
      capturedAt: snapshot.capturedAt,
      weekly: snapshot.weekly,
      fiveHour: snapshot.fiveHour,
      lastAttemptAt: attemptedAt,
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: snapshot.claudeAccountFingerprint,
      claudeOrganizationFingerprint: snapshot.claudeOrganizationFingerprint
    )
  }

  private static func previousCompatibleWithCurrentAccount(
    _ previous: ProviderSnapshot?, currentAccount: ClaudeAccountIdentity?
  ) -> ProviderSnapshot? {
    guard let previous, let currentAccount else { return previous }
    guard let previousAccount = previous.claudeAccountFingerprint else { return previous }
    return previousAccount == currentAccount.accountFingerprint ? previous : nil
  }

  private static func preferredObservation(
    local: ProviderSnapshot?,
    previous: ProviderSnapshot?,
    now: Date,
    allowMerge: Bool = true
  ) -> ProviderSnapshot? {
    guard let local else { return previous }
    guard let previous else { return local }
    if let localAccount = local.claudeAccountFingerprint,
      let previousAccount = previous.claudeAccountFingerprint,
      localAccount != previousAccount
    {
      return local
    }
    if local.claudeAccountFingerprint != nil,
      previous.claudeAccountFingerprint == nil,
      previous.source == .claudeDesktopHistory,
      Self.hasCurrentExactReset(local, now: now)
    {
      return local
    }
    guard let localCapturedAt = local.capturedAt else { return previous }
    guard let previousCapturedAt = previous.capturedAt else { return local }
    guard localCapturedAt > previousCapturedAt else { return previous }
    // Unowned observations cannot prove they belong to the same account. Keep an exact
    // observation intact until a verified observation replaces it; never transfer its reset.
    if !Self.hasCurrentExactReset(local, now: now),
      Self.hasCurrentExactReset(previous, now: now)
    {
      guard
        let localAccount = local.claudeAccountFingerprint,
        localAccount == previous.claudeAccountFingerprint
      else { return previous }
    }
    if local.claudeAccountFingerprint == nil,
      previous.claudeAccountFingerprint != nil,
      Self.hasCurrentExactReset(previous, now: now)
    {
      return previous
    }
    guard allowMerge else { return local }
    guard
      let localAccount = local.claudeAccountFingerprint,
      localAccount == previous.claudeAccountFingerprint
    else { return local }

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
      sourceState: local.sourceState,
      claudeAccountFingerprint: localAccount,
      claudeOrganizationFingerprint: local.claudeOrganizationFingerprint
    )
  }

  private static func isCompleteAndFresh(_ snapshot: ProviderSnapshot, now: Date) -> Bool {
    guard let capturedAt = snapshot.capturedAt,
      let weeklyReset = snapshot.weekly?.resetAt,
      weeklyReset > now,
      let fiveHourReset = snapshot.fiveHour?.resetAt,
      fiveHourReset > now
    else { return false }
    let age = now.timeIntervalSince(capturedAt)
    return age >= 0 && age <= self.localCacheMaximumAge
  }

  private static func hasFreshVerifiedWeeklyTarget(
    _ snapshot: ProviderSnapshot, now: Date
  ) -> Bool {
    guard snapshot.claudeAccountFingerprint != nil,
      snapshot.weekly?.resetAt.map({ $0 > now }) == true,
      let capturedAt = snapshot.capturedAt
    else { return false }
    let age = now.timeIntervalSince(capturedAt)
    return age >= 0 && age <= self.localCacheMaximumAge
  }

  private static func localCandidate(
    history: ProviderSnapshot?,
    cache: ProviderSnapshot?,
    currentAccount: ClaudeAccountIdentity?,
    desktopAccountFingerprint: String?,
    now: Date
  ) -> ProviderSnapshot? {
    if let cache,
      let currentAccount,
      cache.claudeAccountFingerprint == currentAccount.accountFingerprint
    {
      if let history,
        history.claudeOrganizationFingerprint == currentAccount.organizationFingerprint,
        desktopAccountFingerprint == currentAccount.principalFingerprint,
        let historyAt = history.capturedAt,
        let cacheAt = cache.capturedAt,
        historyAt > cacheAt
      {
        let ownedHistory = Self.withAccountFingerprint(
          history,
          fingerprint: currentAccount.accountFingerprint,
          organizationFingerprint: currentAccount.organizationFingerprint)
        return Self.preferredObservation(local: ownedHistory, previous: cache, now: now)
      }
      return cache
    }
    return Self.newestUnmerged(history: history, cache: cache)
  }

  private static func newestUnmerged(
    history: ProviderSnapshot?, cache: ProviderSnapshot?
  ) -> ProviderSnapshot? {
    guard let history else { return cache }
    guard let cache else { return history }
    guard let historyAt = history.capturedAt, let cacheAt = cache.capturedAt else {
      return cache.capturedAt != nil ? cache : history
    }
    return cacheAt >= historyAt ? cache : history
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
      sourceState: .observationSucceeded,
      claudeOrganizationFingerprint: Self.fingerprint(sample.organizationUUID)
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
      sourceState: .observationSucceeded,
      claudeAccountFingerprint: Self.accountFingerprint(root.oauthAccount),
      claudeOrganizationFingerprint: Self.fingerprint(root.oauthAccount?.organizationUUID)
    )
  }

  private func readAccountIdentity() throws -> ClaudeAccountIdentity {
    let data = try self.reader.read(from: self.cacheURL, limit: Self.cacheInputLimit)
    let root: AccountRoot
    do { root = try JSONDecoder().decode(AccountRoot.self, from: data) } catch {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    guard let accountFingerprint = Self.accountFingerprint(root.oauthAccount),
      let organizationFingerprint = Self.fingerprint(root.oauthAccount?.organizationUUID),
      let principalFingerprint = Self.fingerprint(root.oauthAccount?.accountUUID)
    else { throw ClaudeAutomaticAdapterError.sourceUnavailable }
    return ClaudeAccountIdentity(
      accountFingerprint: accountFingerprint,
      organizationFingerprint: organizationFingerprint,
      principalFingerprint: principalFingerprint
    )
  }

  private func readDesktopAccountFingerprint() throws -> String {
    let data = try self.reader.read(
      from: self.desktopConfigURL, limit: Self.desktopConfigInputLimit)
    let root: DesktopConfigRoot
    do { root = try JSONDecoder().decode(DesktopConfigRoot.self, from: data) } catch {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    guard let fingerprint = Self.fingerprint(root.lastKnownAccountUUID) else {
      throw ClaudeAutomaticAdapterError.sourceUnavailable
    }
    return fingerprint
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

  private func readPTY(executable cliExecutable: URL?) throws -> ProviderSnapshot {
    guard let cliExecutable else { throw ClaudeAutomaticAdapterError.sourceUnavailable }
    let output = try self.ptyProbe.capture(
      executable: cliExecutable,
      workingDirectory: self.probeDirectory
    )
    let observedAt = Date()
    guard !ClaudeUsageTextParser.indicatesStaleUsage(output) else {
      throw ClaudeAutomaticAdapterError.invalidInput
    }
    guard let parsed = ClaudeUsageTextParser.parse(output, now: observedAt),
      parsed.weekly?.resetAt != nil
    else { throw ClaudeAutomaticAdapterError.invalidInput }
    return ProviderSnapshot(
      provider: .claude, source: .claudeCLI, capturedAt: observedAt,
      weekly: parsed.weekly, fiveHour: parsed.fiveHour,
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

  private static func fingerprint(_ identifier: String?) -> String? {
    guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else { return nil }
    return SHA256.hash(data: Data(identifier.lowercased().utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func accountFingerprint(_ account: OAuthAccount?) -> String? {
    Self.accountFingerprint(
      accountUUID: account?.accountUUID,
      organizationUUID: account?.organizationUUID
    )
  }

  private static func accountFingerprint(
    accountUUID: String?, organizationUUID: String?
  ) -> String? {
    guard let accountUUID = accountUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !accountUUID.isEmpty,
      let organizationUUID = organizationUUID?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !organizationUUID.isEmpty
    else { return nil }
    return Self.fingerprint(
      "claude-owner-v1:\(accountUUID.lowercased()):\(organizationUUID.lowercased())")
  }

  private static func withAccountFingerprint(
    _ snapshot: ProviderSnapshot,
    fingerprint: String?,
    organizationFingerprint: String?
  ) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: snapshot.provider,
      source: snapshot.source,
      capturedAt: snapshot.capturedAt,
      weekly: snapshot.weekly,
      fiveHour: snapshot.fiveHour,
      lastAttemptAt: snapshot.lastAttemptAt,
      sourceState: snapshot.sourceState,
      errorCode: snapshot.errorCode,
      claudeAccountFingerprint: fingerprint,
      claudeOrganizationFingerprint: organizationFingerprint
    )
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
  let organizationUUID: String?
  let usage: HistoryUsage

  enum CodingKeys: String, CodingKey {
    case timestampMilliseconds = "t"
    case organizationUUID = "org"
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
  let oauthAccount: OAuthAccount?
}

private struct AccountRoot: Decodable {
  let oauthAccount: OAuthAccount?
}

private struct OAuthAccount: Decodable {
  let accountUUID: String?
  let organizationUUID: String?

  enum CodingKeys: String, CodingKey {
    case accountUUID = "accountUuid"
    case organizationUUID = "organizationUuid"
  }
}

private struct ClaudeAccountIdentity: Equatable {
  let accountFingerprint: String
  let organizationFingerprint: String
  let principalFingerprint: String
}

private struct DesktopConfigRoot: Decodable {
  let lastKnownAccountUUID: String?

  enum CodingKeys: String, CodingKey {
    case lastKnownAccountUUID = "lastKnownAccountUuid"
  }
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
