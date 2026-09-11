import Foundation

public enum QuotaPlanner {
  public static let weeklyMinimumDuration: TimeInterval = 6 * 24 * 60 * 60
  public static let weeklyMaximumDuration: TimeInterval = 8 * 24 * 60 * 60
  public static let checkpointDuration: TimeInterval = 24 * 60 * 60
  public static let onTargetTolerance = 2.0
  public static let liveMaximumAge: TimeInterval = 5 * 60
  public static let recentMaximumAge: TimeInterval = 30 * 60

  public static func evaluate(
    _ snapshot: ProviderSnapshot,
    now: Date
  ) -> PlannedProvider {
    guard let capturedAt = snapshot.capturedAt else {
      return self.unavailable(snapshot, freshness: .unavailable, now: now)
    }
    let freshness = self.freshness(capturedAt: capturedAt, now: now)
    guard freshness != .unavailable else {
      return self.unavailable(snapshot, freshness: .unavailable, now: now)
    }

    guard let weekly = snapshot.weekly,
      weekly.remainingPercent.isFinite,
      (0...100).contains(weekly.remainingPercent),
      weekly.durationSeconds.isFinite,
      (self.weeklyMinimumDuration...self.weeklyMaximumDuration).contains(weekly.durationSeconds)
    else {
      return self.unavailable(snapshot, freshness: freshness, now: now)
    }

    guard let resetAt = weekly.resetAt else {
      return self.withoutTarget(
        snapshot,
        capturedAt: capturedAt,
        freshness: freshness,
        weeklyRemaining: weekly.remainingPercent,
        now: now
      )
    }

    let timeRemaining = resetAt.timeIntervalSince(now)
    guard timeRemaining > 0 else {
      return self.resetElapsed(
        snapshot,
        capturedAt: capturedAt,
        freshness: freshness,
        now: now
      )
    }
    guard timeRemaining <= weekly.durationSeconds else {
      return self.withoutTarget(
        snapshot,
        capturedAt: capturedAt,
        freshness: freshness,
        weeklyRemaining: weekly.remainingPercent,
        now: now
      )
    }

    let targetNow = 100 * timeRemaining / weekly.durationSeconds
    let vsTarget = weekly.remainingPercent - targetNow
    let checkpoint = self.nextCheckpoint(
      now: now,
      resetAt: resetAt,
      duration: weekly.durationSeconds
    )
    let checkpointTarget =
      100
      * resetAt.timeIntervalSince(checkpoint)
      / weekly.durationSeconds
    let available = max(weekly.remainingPercent - checkpointTarget, 0)

    if freshness == .stale {
      return PlannedProvider(
        provider: snapshot.provider,
        source: snapshot.source,
        capturedAt: capturedAt,
        freshness: freshness,
        status: .stale,
        weeklyRemaining: weekly.remainingPercent,
        targetNow: targetNow,
        targetIsEstimated: weekly.isResetEstimated,
        vsTarget: nil,
        weeklyResetAt: resetAt,
        weeklyResetIsEstimated: weekly.isResetEstimated,
        nextCheckpoint: checkpoint,
        checkpointTarget: checkpointTarget,
        availableUntilCheckpoint: nil,
        fiveHourRisk: false,
        lastAttemptAt: snapshot.lastAttemptAt,
        sourceState: snapshot.sourceState,
        errorCode: snapshot.errorCode,
        codexExecutableSource: snapshot.codexExecutableSource,
        codexExecutableVersion: snapshot.codexExecutableVersion
      )
    }

    let status: TargetStatus
    switch freshness {
    case .stale, .unavailable:
      status = .unavailable
    case .live, .recent:
      let displayedDifference =
        self.displayedDifference(
          weeklyRemaining: weekly.remainingPercent,
          targetNow: targetNow
        ) ?? 0
      if displayedDifference > Int(self.onTargetTolerance) {
        status = .aboveTarget
      } else if displayedDifference < -Int(self.onTargetTolerance) {
        status = .belowTarget
      } else {
        status = .onTarget
      }
    }

    return PlannedProvider(
      provider: snapshot.provider,
      source: snapshot.source,
      capturedAt: capturedAt,
      freshness: freshness,
      status: status,
      weeklyRemaining: weekly.remainingPercent,
      targetNow: targetNow,
      targetIsEstimated: weekly.isResetEstimated,
      vsTarget: vsTarget,
      weeklyResetAt: resetAt,
      weeklyResetIsEstimated: weekly.isResetEstimated,
      nextCheckpoint: checkpoint,
      checkpointTarget: checkpointTarget,
      availableUntilCheckpoint: available,
      fiveHourRisk: self.isFiveHourRisk(snapshot.fiveHour, now: now, freshness: freshness),
      lastAttemptAt: snapshot.lastAttemptAt,
      sourceState: snapshot.sourceState,
      errorCode: snapshot.errorCode,
      codexExecutableSource: snapshot.codexExecutableSource,
      codexExecutableVersion: snapshot.codexExecutableVersion
    )
  }

  public static func evaluateUnique(
    _ snapshots: [ProviderSnapshot],
    now: Date
  ) -> [PlannedProvider] {
    var seen = Set<ProviderID>()
    return snapshots.compactMap { snapshot in
      guard seen.insert(snapshot.provider).inserted else { return nil }
      return self.evaluate(snapshot, now: now)
    }
  }

  public static func freshness(capturedAt: Date, now: Date) -> Freshness {
    let age = now.timeIntervalSince(capturedAt)
    guard age >= 0 else { return .unavailable }
    if age <= self.liveMaximumAge { return .live }
    if age <= self.recentMaximumAge { return .recent }
    return .stale
  }

  public static func nextCheckpoint(
    now: Date,
    resetAt: Date,
    duration: TimeInterval
  ) -> Date {
    let timeRemaining = max(resetAt.timeIntervalSince(now), 0)
    guard timeRemaining > self.checkpointDuration else { return resetAt }

    let intervalsRemaining = ceil(timeRemaining / self.checkpointDuration)
    let intervalsAfterCheckpoint = max(intervalsRemaining - 1, 0)
    let candidate = resetAt.addingTimeInterval(
      -intervalsAfterCheckpoint * self.checkpointDuration
    )
    let windowStart = resetAt.addingTimeInterval(-duration)
    return max(candidate, windowStart)
  }

  public static func roundedPercent(_ value: Double) -> Int {
    Int(value.rounded(.toNearestOrAwayFromZero))
  }

  public static func displayedDifference(
    weeklyRemaining: Double?,
    targetNow: Double?
  ) -> Int? {
    guard let weeklyRemaining, let targetNow else { return nil }
    return self.roundedPercent(weeklyRemaining) - self.roundedPercent(targetNow)
  }

  private static func isFiveHourRisk(
    _ window: QuotaWindow?,
    now: Date,
    freshness: Freshness
  ) -> Bool {
    guard freshness == .live || freshness == .recent,
      let window,
      window.remainingPercent.isFinite,
      (0...100).contains(window.remainingPercent),
      window.durationSeconds > 0
    else { return false }

    guard let resetAt = window.resetAt else { return false }
    let timeRemaining = resetAt.timeIntervalSince(now)
    return window.remainingPercent <= 15 && timeRemaining > 30 * 60
  }

  private static func unavailable(
    _ snapshot: ProviderSnapshot,
    freshness: Freshness,
    now: Date
  ) -> PlannedProvider {
    PlannedProvider(
      provider: snapshot.provider,
      source: snapshot.source,
      capturedAt: snapshot.capturedAt,
      freshness: freshness,
      status: .unavailable,
      weeklyRemaining: nil,
      targetNow: nil,
      targetIsEstimated: false,
      vsTarget: nil,
      weeklyResetAt: nil,
      weeklyResetIsEstimated: false,
      nextCheckpoint: nil,
      checkpointTarget: nil,
      availableUntilCheckpoint: nil,
      fiveHourRisk: self.isFiveHourRisk(
        snapshot.fiveHour,
        now: now,
        freshness: freshness
      ),
      lastAttemptAt: snapshot.lastAttemptAt,
      sourceState: snapshot.sourceState,
      errorCode: snapshot.errorCode,
      codexExecutableSource: snapshot.codexExecutableSource,
      codexExecutableVersion: snapshot.codexExecutableVersion
    )
  }

  private static func withoutTarget(
    _ snapshot: ProviderSnapshot,
    capturedAt: Date,
    freshness: Freshness,
    weeklyRemaining: Double,
    now: Date
  ) -> PlannedProvider {
    PlannedProvider(
      provider: snapshot.provider,
      source: snapshot.source,
      capturedAt: capturedAt,
      freshness: freshness,
      status: freshness == .stale ? .stale : .resetUnknown,
      weeklyRemaining: weeklyRemaining,
      targetNow: nil,
      targetIsEstimated: false,
      vsTarget: nil,
      weeklyResetAt: nil,
      weeklyResetIsEstimated: false,
      nextCheckpoint: nil,
      checkpointTarget: nil,
      availableUntilCheckpoint: nil,
      fiveHourRisk: self.isFiveHourRisk(snapshot.fiveHour, now: now, freshness: freshness),
      lastAttemptAt: snapshot.lastAttemptAt,
      sourceState: snapshot.sourceState,
      errorCode: snapshot.errorCode,
      codexExecutableSource: snapshot.codexExecutableSource,
      codexExecutableVersion: snapshot.codexExecutableVersion
    )
  }

  private static func resetElapsed(
    _ snapshot: ProviderSnapshot,
    capturedAt: Date,
    freshness: Freshness,
    now: Date
  ) -> PlannedProvider {
    PlannedProvider(
      provider: snapshot.provider,
      source: snapshot.source,
      capturedAt: capturedAt,
      freshness: freshness,
      status: .resetElapsed,
      weeklyRemaining: nil,
      targetNow: nil,
      targetIsEstimated: false,
      vsTarget: nil,
      weeklyResetAt: nil,
      weeklyResetIsEstimated: false,
      nextCheckpoint: nil,
      checkpointTarget: nil,
      availableUntilCheckpoint: nil,
      fiveHourRisk: self.isFiveHourRisk(snapshot.fiveHour, now: now, freshness: freshness),
      lastAttemptAt: snapshot.lastAttemptAt,
      sourceState: snapshot.sourceState,
      errorCode: snapshot.errorCode,
      codexExecutableSource: snapshot.codexExecutableSource,
      codexExecutableVersion: snapshot.codexExecutableVersion
    )
  }
}
