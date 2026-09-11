import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable {
  case codex
  case claude

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }
}

public enum SnapshotSource: String, Codable, Sendable {
  case fixture
  case codexAppServer
  case claudeStatusLine
  case claudeDesktopHistory
  case claudeLocalCache
  case claudeLocalMerged
  case claudeCLI
}

public enum CodexExecutableSource: String, Codable, Equatable, Sendable {
  case desktopBundled
  case userLocal
  case packageManager
  case system
}

public enum SourceState: String, Codable, Equatable, Sendable {
  case neverObserved
  case observationSucceeded
  case accessRestricted
  case attemptTimedOut
  case attemptFailed
  case awaitingEvent
  case bridgeUnavailable
}

public enum AcquisitionErrorCode: String, Codable, Equatable, Sendable {
  case timeout
  case outputLimitExceeded
  case invalidResponse
  case sourceUnavailable
  case unsafePath
  case inputTooLarge
  case usageRestricted
  case atomicWriteFailed
  case sourceNotInstalled
  case launchFailed
  case versionTooOld
  case protocolIncompatible
  case temporaryFailure
}

public struct QuotaWindow: Codable, Equatable, Sendable {
  public let remainingPercent: Double
  public let durationSeconds: TimeInterval
  public let resetAt: Date?
  public let resetAtIsEstimated: Bool?

  public var isResetEstimated: Bool { self.resetAtIsEstimated == true }

  public init(
    remainingPercent: Double,
    durationSeconds: TimeInterval,
    resetAt: Date?,
    resetAtIsEstimated: Bool = false
  ) {
    self.remainingPercent = remainingPercent
    self.durationSeconds = durationSeconds
    self.resetAt = resetAt
    self.resetAtIsEstimated = resetAt != nil && resetAtIsEstimated ? true : nil
  }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
  public let provider: ProviderID
  public let source: SnapshotSource
  public let capturedAt: Date?
  public let weekly: QuotaWindow?
  public let fiveHour: QuotaWindow?
  public let lastAttemptAt: Date?
  public let sourceState: SourceState?
  public let errorCode: AcquisitionErrorCode?
  public let codexExecutableSource: CodexExecutableSource?
  public let codexExecutableVersion: String?

  public init(
    provider: ProviderID,
    source: SnapshotSource,
    capturedAt: Date?,
    weekly: QuotaWindow?,
    fiveHour: QuotaWindow? = nil,
    lastAttemptAt: Date? = nil,
    sourceState: SourceState? = nil,
    errorCode: AcquisitionErrorCode? = nil,
    codexExecutableSource: CodexExecutableSource? = nil,
    codexExecutableVersion: String? = nil
  ) {
    self.provider = provider
    self.source = source
    self.capturedAt = capturedAt
    self.weekly = weekly
    self.fiveHour = fiveHour
    self.lastAttemptAt = lastAttemptAt
    self.sourceState = sourceState
    self.errorCode = errorCode
    self.codexExecutableSource = codexExecutableSource
    self.codexExecutableVersion = codexExecutableVersion
  }
}

public struct FixtureScenario: Codable, Equatable, Sendable {
  public let id: String
  public let now: Date
  public let snapshots: [ProviderSnapshot]

  public init(id: String, now: Date, snapshots: [ProviderSnapshot]) {
    self.id = id
    self.now = now
    self.snapshots = snapshots
  }
}

public enum Freshness: String, Equatable, Sendable {
  case live
  case recent
  case stale
  case unavailable
}

public enum TargetStatus: String, Equatable, Sendable {
  case aboveTarget
  case onTarget
  case belowTarget
  case resetUnknown
  case resetElapsed
  case stale
  case unavailable
}

public struct PlannedProvider: Equatable, Sendable, Identifiable {
  public var id: ProviderID { self.provider }

  public let provider: ProviderID
  public let source: SnapshotSource
  public let capturedAt: Date?
  public let freshness: Freshness
  public let status: TargetStatus
  public let weeklyRemaining: Double?
  public let targetNow: Double?
  public let targetIsEstimated: Bool
  public let vsTarget: Double?
  public let weeklyResetAt: Date?
  public let weeklyResetIsEstimated: Bool
  public let nextCheckpoint: Date?
  public let checkpointTarget: Double?
  public let availableUntilCheckpoint: Double?
  public let fiveHourRisk: Bool
  public let lastAttemptAt: Date?
  public let sourceState: SourceState?
  public let errorCode: AcquisitionErrorCode?
  public let codexExecutableSource: CodexExecutableSource?
  public let codexExecutableVersion: String?
}
