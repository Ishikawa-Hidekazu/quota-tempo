#if DESKTOP_INTEGRATION_PREVIEW
  import Foundation
  import QuotaTempoCore
  import QuotaTempoDesktopCandidate

  @MainActor
  protocol DesktopAcceptanceConnecting: AnyObject {
    var status: DesktopConnectionController.Status { get }
    var snapshot: ProviderSnapshot? { get }
    var nextAllowedAt: Date? { get }
    func connectForAcceptance() async
    func refreshForAcceptance() async
    func disconnect() async
  }

  extension DesktopConnectionController: DesktopAcceptanceConnecting {
    func connectForAcceptance() async { await connect(localExperimentAuthorized: true) }
    func refreshForAcceptance() async { await refresh() }
  }

  enum DesktopAcceptanceCommand {
    // Takes arguments WITHOUT the executable name. The parent entry point routes
    // all reserved flags here before constructing the app, including invalid input.
    static let requiredArguments = [
      "--desktop-acceptance", "--consent-desktop-read-only",
      "--acknowledge-provider-permission-unconfirmed",
    ]

    @MainActor
    static func run(
      arguments: [String],
      supportDirectory: @escaping @MainActor () -> URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      },
      makeConnection: @escaping @MainActor (URL, UserDefaults?) -> any DesktopAcceptanceConnecting =
        {
          DesktopConnectionController(directory: $0, consentDefaults: $1)
        },
      output: @escaping @MainActor (String) -> Void = { print($0) }
    ) async -> Int32 {
      let clock = ContinuousClock()
      let origin = clock.now
      return await DesktopAcceptanceRunner(
        makeConnection: {
          let configuration = DesktopIntegrationConfiguration(
            arguments: arguments, supportDirectory: supportDirectory())
          // Keep the real scheduling namespace and standard admission/service.
          // No persisted app consent is supplied: consent is process-only.
          // Both dependencies remain lazy until the runner admits the arguments.
          return makeConnection(configuration.schedulingDirectory, nil)
        },
        now: Date.init,
        monotonicNow: { origin.duration(to: clock.now) },
        sleep: { try await Task.sleep(for: $0) },
        output: output
      ).run(arguments: arguments)
    }
  }

  @MainActor
  struct DesktopAcceptanceRunner {
    let makeConnection: @MainActor () -> any DesktopAcceptanceConnecting
    let now: @MainActor () -> Date
    let monotonicNow: @MainActor () -> Duration
    let sleep: @MainActor (Duration) async throws -> Void
    let output: @MainActor (String) -> Void

    private enum Event: Sendable { case completed, tick, deadline, clockFailure, sleepFailure }

    private enum Status: String, Encodable {
      case captured, success, invalidArguments, cancelled, deadlineExceeded, invalidClock
      case schedulingUnavailable, consentRequired, permissionRequired, accessDenied
      case renewalRequired, sourceUnavailable, temporaryFailure, invalidResponse
      case waitingForProvider, serviceWaitUnavailable, storageUnavailable, storeInUse
      case consentStorageUnavailable, unexpectedState

      var exitCode: Int32 {
        switch self {
        case .success: 0
        case .invalidArguments: 64
        case .cancelled: 130
        case .deadlineExceeded: 124
        default: 1
        }
      }
    }

    private struct Counts: Encodable {
      var captures = 0
      // Connect performs the initial refresh; these count scheduled calls only,
      // not HTTP attempts (admission remains owned by the standard service).
      var scheduledRefreshes = 0
      var duplicates = 0
    }

    private struct Capture {
      let capturedAt: Date
      let weeklyRemaining: Double
      let targetNow: Double
      let difference: Double
      let exactResetAt: Date
    }

    private struct Report: Encodable {
      let status: Status
      let capturedAt: Date?
      let weeklyRemaining: Double?
      let targetNow: Double?
      let difference: Double?
      let exactResetAt: Date?
      let nextAllowedAt: Date?
      let counts: Counts
      let desktopOnly = true
      let providerPermissionConfirmed = false

      enum CodingKeys: String, CodingKey {
        case status, capturedAt, difference, exactResetAt, nextAllowedAt, counts
        case desktopOnly, providerPermissionConfirmed
        case weeklyRemaining = "W"
        case targetNow = "P"
      }
    }

    func run(arguments: [String]) async -> Int32 {
      var counts = Counts()
      guard arguments == DesktopAcceptanceCommand.requiredArguments else {
        emit(.invalidArguments, counts: counts)
        return Status.invalidArguments.exitCode
      }
      guard !Task.isCancelled else {
        emit(.cancelled, counts: counts)
        return Status.cancelled.exitCode
      }
      let startedAt = now()
      guard Self.validDate(startedAt) else {
        emit(.invalidClock, counts: counts)
        return Status.invalidClock.exitCode
      }
      let started = monotonicNow()
      let deadline = started + .seconds(660)
      let connection = makeConnection()
      let (events, continuation) = AsyncStream<Event>.makeStream()
      var pending: Task<Void, Never>? = Task {
        guard !Task.isCancelled else { return }
        await connection.connectForAcceptance()
        continuation.yield(.completed)
      }
      let ticker = Task {
        var previous = started
        while !Task.isCancelled {
          let before = monotonicNow()
          guard before >= previous else {
            continuation.yield(.clockFailure)
            return
          }
          if before >= deadline {
            continuation.yield(.deadline)
            return
          }
          let target = min(before + .seconds(30), deadline)
          do { try await sleep(target - before) } catch {
            if !Task.isCancelled { continuation.yield(.sleepFailure) }
            return
          }
          guard !Task.isCancelled else { return }
          let after = monotonicNow()
          // A broken injected clock/sleeper must not become a busy retry loop.
          guard after >= target else {
            continuation.yield(.clockFailure)
            return
          }
          previous = after
          if after >= deadline {
            continuation.yield(.deadline)
            return
          }
          continuation.yield(.tick)
        }
      }

      var outcome = Status.cancelled
      var finalCapture: Capture?
      var seen = Set<Date>()
      var firstCapture: (date: Date, monotonic: Duration)?
      var latestCaptureAt: Date?
      var lastInstant = started
      // Unstructured operations are deliberately not awaited during shutdown:
      // disconnect fences late results; the parent owns the process watchdog
      // for non-cooperative controller work or cleanup.
      eventLoop: for await event in events {
        if Task.isCancelled { break }
        let instant = monotonicNow()
        guard instant >= lastInstant else {
          outcome = .invalidClock
          break
        }
        lastInstant = instant
        if instant >= deadline {
          outcome = .deadlineExceeded
          break
        }
        switch event {
        case .deadline:
          outcome = .deadlineExceeded
          break eventLoop
        case .clockFailure:
          outcome = .invalidClock
          break eventLoop
        case .sleepFailure:
          outcome = .schedulingUnavailable
          break eventLoop
        case .tick:
          guard pending == nil else { continue }
          counts.scheduledRefreshes += 1
          pending = Task {
            guard !Task.isCancelled else { return }
            await connection.refreshForAcceptance()
            continuation.yield(.completed)
          }
        case .completed:
          pending = nil
          if let stop = Self.terminalStatus(connection.status) {
            outcome = stop
            break eventLoop
          }
          guard connection.status == .current,
            let capture = capture(connection.snapshot, startedAt: startedAt)
          else { continue }
          guard !seen.contains(capture.capturedAt) else {
            counts.duplicates += 1
            continue
          }
          if let latestCaptureAt, capture.capturedAt <= latestCaptureAt { continue }
          seen.insert(capture.capturedAt)
          latestCaptureAt = capture.capturedAt
          counts.captures += 1
          if let firstCapture,
            capture.capturedAt.timeIntervalSince(firstCapture.date) >= 300,
            instant - firstCapture.monotonic >= .seconds(300)
          {
            finalCapture = capture
            outcome = .success
            break eventLoop
          }
          if firstCapture == nil { firstCapture = (capture.capturedAt, instant) }
          emit(.captured, capture: capture, nextAllowedAt: connection.nextAllowedAt, counts: counts)
        }
      }

      let nextAllowedAt = connection.nextAllowedAt
      continuation.finish()
      ticker.cancel()
      pending?.cancel()
      await connection.disconnect()
      if Task.isCancelled {
        outcome = .cancelled
      } else if outcome == .success && monotonicNow() >= deadline {
        outcome = .deadlineExceeded
      }
      emit(
        outcome, capture: outcome == .success ? finalCapture : nil,
        nextAllowedAt: nextAllowedAt, counts: counts)
      return outcome.exitCode
    }

    private func capture(_ snapshot: ProviderSnapshot?, startedAt: Date) -> Capture? {
      let current = now()
      guard Self.validDate(current), let snapshot,
        snapshot.provider == .claude, snapshot.source == .claudeDesktopDirect,
        snapshot.sourceState == .observationSucceeded, snapshot.errorCode == nil,
        let capturedAt = snapshot.capturedAt, Self.validDate(capturedAt),
        capturedAt >= startedAt, capturedAt <= current,
        QuotaPlanner.freshness(capturedAt: capturedAt, now: current) == .live,
        let weekly = snapshot.weekly, weekly.durationSeconds == 604_800,
        !weekly.isResetEstimated, let resetAt = weekly.resetAt,
        Self.validDate(resetAt), resetAt > current
      else { return nil }
      let plan = QuotaPlanner.evaluate(snapshot, now: current)
      guard !plan.targetIsEstimated, !plan.weeklyResetIsEstimated,
        let weeklyRemaining = plan.weeklyRemaining, weeklyRemaining.isFinite,
        let targetNow = plan.targetNow, targetNow.isFinite,
        let difference = plan.vsTarget, difference.isFinite
      else { return nil }
      return Capture(
        capturedAt: capturedAt, weeklyRemaining: weeklyRemaining, targetNow: targetNow,
        difference: difference, exactResetAt: resetAt)
    }

    private static func terminalStatus(_ status: DesktopConnectionController.Status) -> Status? {
      switch status {
      case .connecting, .ready, .current, .stale, .waitingForNextRefresh: nil
      case .consentRequired: .consentRequired
      case .keychainPermissionRequired: .permissionRequired
      case .accessDenied: .accessDenied
      case .renewalRequired: .renewalRequired
      case .waitingForProvider: .waitingForProvider
      case .sourceUnavailable: .sourceUnavailable
      case .temporaryFailure: .temporaryFailure
      case .invalidResponse: .invalidResponse
      case .invalidClock: .invalidClock
      case .serviceWaitUnavailable: .serviceWaitUnavailable
      case .storageUnavailable: .storageUnavailable
      case .storeInUse: .storeInUse
      case .consentStorageUnavailable: .consentStorageUnavailable
      case .disconnected, .waitingForIdle, .repairing, .repaired, .repairUnsupported,
        .restartRequired, .requestingKeychainAccess:
        .unexpectedState
      }
    }

    private static func validDate(_ date: Date) -> Bool {
      date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0
    }

    private func emit(
      _ status: Status, capture: Capture? = nil, nextAllowedAt: Date? = nil, counts: Counts
    ) {
      let report = Report(
        status: status, capturedAt: capture?.capturedAt,
        weeklyRemaining: capture?.weeklyRemaining, targetNow: capture?.targetNow,
        difference: capture?.difference, exactResetAt: capture?.exactResetAt,
        nextAllowedAt: nextAllowedAt.flatMap { Self.validDate($0) ? $0 : nil }, counts: counts)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      // Report contains only fixed statuses and validated normalized scalars.
      guard let data = try? encoder.encode(report) else { return }
      output(String(decoding: data, as: UTF8.self))
    }
  }
#endif
