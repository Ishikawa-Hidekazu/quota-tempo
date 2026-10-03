#if DESKTOP_INTEGRATION_PREVIEW
  import Foundation
  import Testing
  import QuotaTempoCore
  import QuotaTempoDesktopCandidate
  @testable import QuotaTempoApp

  @Suite("Bounded Desktop-only acquisition acceptance")
  @MainActor
  struct DesktopAcceptanceCommandTests {
    private let arguments = DesktopAcceptanceCommand.requiredArguments

    private var invalidArguments: [[String]] {
      [
        [String](), ["--desktop-acceptance"], Array(arguments.dropLast()),
        Array(arguments.reversed()), arguments + ["--request-keychain-access"],
        arguments + ["--recheck-connection-once"], arguments + ["--repair-scheduling-state"],
        arguments + ["--storage-directory", "/unused"], arguments + [arguments[0]],
        ["--desktop-acceptance=true"], ["--desktop-acceptance-unknown"],
        ["QuotaTempo"] + arguments, Array(arguments.dropFirst()),
        ["--consent-desktop-read-only"], ["--acknowledge-provider-permission-unconfirmed"],
        ["--provider-disabled"], arguments + ["--provider-disabled"],
        ["--provider-disabled"] + arguments,
        ["--storage-directory", "/unused"] + arguments,
        arguments + ["--provider-disabled", "--storage-directory", "/unused"],
      ]
    }

    @Test("Only the exact consent array runs; malformed reserved flags create nothing")
    func invalidArgumentsDoNotConstructConnection() async {
      for args in invalidArguments {
        let harness = AcceptanceHarness()
        let code = await harness.runner.run(arguments: args)
        #expect(code == 64)
        #expect(harness.constructions == 0)
        #expect(harness.connection.connects == 0)
        #expect(harness.clock.sleeps.isEmpty)
        #expect(harness.statuses == ["invalidArguments"])
      }
    }

    @Test("Production entry point rejects default and disabled modes before resolving dependencies")
    func commandAdmissionPrecedesProductionConstruction() async {
      let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      for args in invalidArguments {
        let harness = AcceptanceHarness()
        // Fail promptly even if admission regresses and the factory is reached.
        harness.connection.currentStatus = .consentRequired
        var resolutions = 0
        let code = await DesktopAcceptanceCommand.run(
          arguments: args,
          supportDirectory: {
            resolutions += 1
            return support
          },
          makeConnection: { _, _ in
            harness.constructions += 1
            return harness.connection
          },
          output: { harness.lines.append($0) })
        #expect(code == 64)
        #expect(resolutions == 0)
        #expect(harness.constructions == 0)
        #expect(harness.connection.connects == 0)
        #expect(harness.connection.disconnects == 0)
        #expect(harness.statuses == ["invalidArguments"])
      }
      #expect(!FileManager.default.fileExists(atPath: support.path))
    }

    @Test("Production construction shares the app schedule and never supplies persisted consent")
    func commandUsesSharedScheduleAndProcessOnlyConsent() async {
      let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let normalApp = DesktopIntegrationConfiguration(arguments: [], supportDirectory: support)
      let harness = AcceptanceHarness()
      harness.connection.currentStatus = .consentRequired
      var resolutions = 0
      var directories: [URL] = []
      let code = await DesktopAcceptanceCommand.run(
        arguments: arguments,
        supportDirectory: {
          resolutions += 1
          return support
        },
        makeConnection: { directory, consentDefaults in
          #expect(resolutions == 1)
          // The real constructor maps non-nil defaults to remembered app consent.
          // Inspect its inputs without ever opening a store or a live service.
          #expect(consentDefaults == nil)
          directories.append(directory)
          harness.constructions += 1
          return harness.connection
        },
        output: { harness.lines.append($0) })
      #expect(code == 1)
      #expect(resolutions == 1)
      #expect(harness.constructions == 1)
      #expect(directories == [normalApp.schedulingDirectory])
      #expect(
        directories == [
          support.appendingPathComponent("QuotaTempoDesktopPreview", isDirectory: true)
        ])
      #expect(directories.first != normalApp.appDirectory)
      #expect(harness.connection.connects == 1)
      #expect(harness.connection.refreshes == 0)
      #expect(harness.connection.disconnects == 1)
      #expect(harness.statuses == ["consentRequired"])
      #expect(!harness.lines.joined().contains(support.path))
      #expect(!FileManager.default.fileExists(atPath: support.path))
    }

    @Test("Cancellation at the production entry point resolves and constructs nothing")
    func cancelledCommandDoesNotConstructConnection() async {
      let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let harness = AcceptanceHarness()
      harness.connection.currentStatus = .consentRequired
      var resolutions = 0
      let task = Task { @MainActor in
        await DesktopAcceptanceCommand.run(
          arguments: arguments,
          supportDirectory: {
            resolutions += 1
            return support
          },
          makeConnection: { _, _ in
            harness.constructions += 1
            return harness.connection
          },
          output: { harness.lines.append($0) })
      }
      task.cancel()
      #expect(await task.value == 130)
      #expect(resolutions == 0)
      #expect(harness.constructions == 0)
      #expect(harness.connection.connects == 0)
      #expect(harness.statuses == ["cancelled"])
      #expect(!FileManager.default.fileExists(atPath: support.path))
    }

    @Test("Two exact captures pass only after normal five-minute spacing")
    func distinctCapturesAndOutputAllowlist() async throws {
      let harness = AcceptanceHarness()
      harness.connection.refresh = {
        if harness.clock.elapsed >= .seconds(300) {
          harness.connection.value = harness.snapshot()
          harness.connection.currentStatus = .current
        } else {
          harness.connection.currentStatus = .waitingForNextRefresh
        }
      }
      let task = harness.start(arguments)
      await harness.connection.waitForRead()
      #expect(harness.statuses == ["captured"])
      for _ in 0..<9 { await harness.tick() }
      #expect(harness.statuses == ["captured"])
      await harness.tick()
      #expect(await task.value == 0)
      #expect(harness.statuses == ["captured", "success"])
      #expect(harness.connection.connects == 1)
      #expect(harness.connection.refreshes == 10)
      #expect(harness.connection.disconnects == 1)
      #expect(harness.clock.sleeps.allSatisfy { $0 == .seconds(30) })

      let records = try harness.records()
      let allowed: Set<String> = [
        "status", "capturedAt", "W", "P", "difference", "exactResetAt", "nextAllowedAt",
        "counts", "desktopOnly", "providerPermissionConfirmed",
      ]
      for record in records {
        #expect(Set(record.keys) == allowed)
        #expect(record["desktopOnly"] as? Bool == true)
        #expect(record["providerPermissionConfirmed"] as? Bool == false)
        let counts = try #require(record["counts"] as? [String: Int])
        #expect(Set(counts.keys) == ["captures", "scheduledRefreshes", "duplicates"])
        let weeklyRemaining = try #require(record["W"] as? Double)
        let targetNow = try #require(record["P"] as? Double)
        #expect(record["difference"] as? Double == weeklyRemaining - targetNow)
        #expect(weeklyRemaining == 80)
        #expect(record["exactResetAt"] as? String == harness.dateString(harness.resetAt))
      }
      #expect((records[0]["capturedAt"] as? String) != (records[1]["capturedAt"] as? String))
      #expect((records[1]["counts"] as? [String: Int])?["captures"] == 2)
      #expect(!harness.lines.joined().contains("synthetic-private-marker"))
    }

    @Test("One capture cannot pass through repeated display updates or changed quota values")
    func duplicatesReachDeadlineWithoutBusyLoop() async throws {
      let harness = AcceptanceHarness()
      let original = harness.clock.wall
      harness.connection.refresh = {
        harness.connection.value = harness.snapshot(capturedAt: original, remaining: 79)
      }
      let task = harness.start(arguments)
      await harness.connection.waitForRead()
      for _ in 0..<21 { await harness.tick() }
      await harness.clock.advance(by: .seconds(30))
      #expect(await task.value == 124)
      #expect(harness.statuses == ["captured", "deadlineExceeded"])
      #expect(harness.connection.refreshes == 21)
      #expect(harness.connection.disconnects == 1)
      #expect(harness.clock.sleeps.count == 22)
      let records = try harness.records()
      let counts = try #require(records.last?["counts"] as? [String: Int])
      #expect(counts["captures"] == 1)
      #expect(counts["duplicates"] == 10)
    }

    @Test("Wall-clock jumps and closely spaced distinct captures cannot bypass monotonic spacing")
    func earlyDistinctCapturesDoNotSucceed() async {
      let harness = AcceptanceHarness()
      harness.connection.refresh = { harness.connection.value = harness.snapshot() }
      let task = harness.start(arguments)
      await harness.connection.waitForRead()
      harness.clock.wall = harness.clock.wall.addingTimeInterval(400)
      await harness.tick()
      #expect(harness.statuses == ["captured", "captured"])
      #expect(harness.clock.elapsed == .seconds(30))
      task.cancel()
      #expect(await task.value == 130)
      #expect(harness.statuses.last == "cancelled")
      #expect(harness.connection.disconnects == 1)
    }

    @Test("Stale, estimated, absent, invalid and non-Desktop observations are never captures")
    func refuseInvalidCaptures() async throws {
      for kind in InvalidCapture.allCases {
        let harness = AcceptanceHarness()
        harness.connection.value = harness.invalidSnapshot(kind)
        let task = harness.start(arguments)
        await harness.connection.waitForRead()
        #expect(harness.lines.isEmpty)
        await harness.clock.advance(by: .seconds(660))
        #expect(await task.value == 124)
        #expect(harness.statuses == ["deadlineExceeded"])
        let records = try harness.records()
        let counts = try #require(records.last?["counts"] as? [String: Int])
        #expect(counts["captures"] == 0)
        #expect(harness.connection.disconnects == 1)
      }
    }

    @Test("A 299-second capture gap cannot pass even after 300 monotonic seconds")
    func captureSpacingIsIndependentlyRequired() async {
      let harness = AcceptanceHarness()
      let initial = harness.clock.wall
      harness.connection.refresh = {
        harness.connection.value = harness.snapshot(capturedAt: initial.addingTimeInterval(299))
      }
      let task = harness.start(arguments)
      await harness.connection.waitForRead()
      let reads = harness.connection.reads
      await harness.clock.advance(by: .seconds(300))
      await harness.connection.waitForRead(after: reads)
      #expect(harness.clock.elapsed == .seconds(300))
      #expect(harness.statuses == ["captured", "captured"])
      task.cancel()
      #expect(await task.value == 130)
      #expect(!harness.statuses.contains("success"))
    }

    @Test("A 300-second capture gap cannot pass after only 299 monotonic seconds")
    func monotonicSpacingIsIndependentlyRequired() async {
      let harness = AcceptanceHarness()
      let initial = harness.clock.wall
      harness.connection.refresh = {
        harness.connection.value = harness.snapshot(capturedAt: initial.addingTimeInterval(300))
      }
      let task = harness.start(arguments)
      await harness.connection.waitForRead()
      harness.clock.wall = initial.addingTimeInterval(1)
      let reads = harness.connection.reads
      await harness.clock.advance(by: .seconds(299))
      await harness.connection.waitForRead(after: reads)
      #expect(harness.clock.elapsed == .seconds(299))
      #expect(harness.clock.wall.timeIntervalSince(initial) == 300)
      #expect(harness.statuses == ["captured", "captured"])
      task.cancel()
      #expect(await task.value == 130)
      #expect(!harness.statuses.contains("success"))
    }

    @Test("Terminal states stop immediately without refresh, retry or a quota record")
    func terminalStops() async {
      let cases: [(DesktopConnectionController.Status, String)] = [
        (.keychainPermissionRequired, "permissionRequired"), (.storeInUse, "storeInUse"),
        (.renewalRequired, "renewalRequired"), (.accessDenied, "accessDenied"),
        (.waitingForProvider, "waitingForProvider"), (.temporaryFailure, "temporaryFailure"),
        (.consentRequired, "consentRequired"), (.storageUnavailable, "storageUnavailable"),
        (.sourceUnavailable, "sourceUnavailable"), (.invalidResponse, "invalidResponse"),
        (.invalidClock, "invalidClock"), (.serviceWaitUnavailable, "serviceWaitUnavailable"),
        (.consentStorageUnavailable, "consentStorageUnavailable"),
        (.waitingForIdle, "unexpectedState"), (.requestingKeychainAccess, "unexpectedState"),
      ]
      for (state, expected) in cases {
        let harness = AcceptanceHarness()
        harness.connection.currentStatus = state
        #expect(await harness.runner.run(arguments: arguments) == 1)
        #expect(harness.statuses == [expected])
        #expect(harness.connection.refreshes == 0)
        #expect(harness.connection.disconnects == 1)
        #expect(harness.clock.elapsed == .zero)
      }
    }

    @Test("A terminal scheduled refresh wins over a retained valid capture")
    func scheduledTerminalStop() async {
      let harness = AcceptanceHarness()
      harness.connection.refresh = { harness.connection.currentStatus = .waitingForProvider }
      let task = harness.start(arguments)
      await harness.connection.waitForRead()
      await harness.tick()
      #expect(await task.value == 1)
      #expect(harness.statuses == ["captured", "waitingForProvider"])
      #expect(harness.connection.refreshes == 1)
      #expect(harness.connection.disconnects == 1)
    }

    @Test("Cancellation and deadline disconnect even when connect or refresh completes late")
    func lateCompletionIsFenced() async {
      for duringRefresh in [false, true] {
        for cancelled in [false, true] {
          let harness = AcceptanceHarness()
          let gate = AcceptanceGate()
          if duringRefresh {
            harness.connection.refreshGate = gate
          } else {
            harness.connection.connectGate = gate
          }
          let task = harness.start(arguments)
          if duringRefresh {
            await harness.connection.waitForRead()
            await harness.clock.advance(by: .seconds(30))
          }
          await gate.waitForEntry()
          if cancelled { task.cancel() } else { await harness.clock.advance(by: .seconds(660)) }
          #expect(await task.value == (cancelled ? 130 : 124))
          #expect(harness.connection.disconnects == 1)
          let linesAtStop = harness.lines
          gate.release()
          await harness.connection.waitForCompletion()
          #expect(harness.lines == linesAtStop)
          #expect(!harness.statuses.contains("success"))
        }
      }
    }

    @Test("A blocked connect is never overlapped by scheduled refresh")
    func blockedConnectDoesNotOverlap() async {
      let harness = AcceptanceHarness()
      let gate = AcceptanceGate()
      harness.connection.connectGate = gate
      let task = harness.start(arguments)
      await gate.waitForEntry()
      await harness.clock.advance(by: .seconds(30))
      await harness.clock.advance(by: .seconds(630))
      #expect(await task.value == 124)
      #expect(harness.connection.refreshes == 0)
      #expect(harness.connection.disconnects == 1)
      gate.release()
      await harness.connection.waitForCompletion()
    }

    @Test("Broken sleepers stop instead of spinning; cancellation before start creates nothing")
    func brokenSleeperAndPrecancel() async {
      for throwsError in [false, true] {
        let harness = AcceptanceHarness()
        let runner = harness.makeRunner(sleep: { _ in
          if throwsError { throw CancellationError() }
        })
        #expect(await runner.run(arguments: arguments) == 1)
        #expect(harness.statuses.last == (throwsError ? "schedulingUnavailable" : "invalidClock"))
        #expect(harness.connection.refreshes == 0)
        #expect(harness.connection.disconnects == 1)
      }
      let harness = AcceptanceHarness()
      let task = harness.start(arguments)
      task.cancel()
      #expect(await task.value == 130)
      #expect(harness.constructions == 0)
      #expect(harness.statuses == ["cancelled"])
    }
  }

  private enum InvalidCapture: CaseIterable, Equatable {
    case stale, estimated, missingReset, elapsedReset, distantReset, futureCapture
    case missingCapture, wrongSource, wrongProvider, failed, restricted, invalidNumber,
      wrongDuration
  }

  @MainActor
  private final class AcceptanceHarness {
    let clock = AcceptanceClock()
    let connection = AcceptanceConnection()
    let resetAt = Date(timeIntervalSince1970: 1_900_302_400)
    var constructions = 0
    var lines: [String] = []

    init() {
      connection.value = snapshot()
      connection.nextAllowedAt = clock.wall.addingTimeInterval(300)
    }

    var runner: DesktopAcceptanceRunner { makeRunner(sleep: clock.sleep) }

    func makeRunner(sleep: @escaping @MainActor (Duration) async throws -> Void)
      -> DesktopAcceptanceRunner
    {
      DesktopAcceptanceRunner(
        makeConnection: {
          self.constructions += 1
          return self.connection
        },
        now: { self.clock.wall }, monotonicNow: { self.clock.elapsed }, sleep: sleep,
        output: { self.lines.append($0) })
    }

    func start(_ arguments: [String]) -> Task<Int32, Never> {
      Task { await runner.run(arguments: arguments) }
    }

    func tick() async {
      let previous = connection.reads
      await clock.advance(by: .seconds(30))
      await connection.waitForRead(after: previous)
    }

    var statuses: [String] { (try? records().compactMap { $0["status"] as? String }) ?? [] }

    func records() throws -> [[String: Any]] {
      try lines.map {
        let object = try JSONSerialization.jsonObject(with: Data($0.utf8))
        return try #require(object as? [String: Any])
      }
    }

    func dateString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    func snapshot(capturedAt: Date? = nil, remaining: Double = 80) -> ProviderSnapshot {
      ProviderSnapshot(
        provider: .claude, source: .claudeDesktopDirect, capturedAt: capturedAt ?? clock.wall,
        weekly: QuotaWindow(
          remainingPercent: remaining, durationSeconds: 604_800, resetAt: resetAt),
        sourceState: .observationSucceeded,
        codexExecutableVersion: "synthetic-private-marker",
        claudeAccountFingerprint: "synthetic-private-marker",
        claudeOrganizationFingerprint: "synthetic-private-marker")
    }

    func invalidSnapshot(_ kind: InvalidCapture) -> ProviderSnapshot {
      let capturedAt: Date? =
        kind == .missingCapture
        ? nil
        : clock.wall.addingTimeInterval(kind == .stale ? -301 : kind == .futureCapture ? 1 : 0)
      let reset: Date? =
        kind == .missingReset
        ? nil
        : kind == .elapsedReset
          ? clock.wall
          : kind == .distantReset ? clock.wall.addingTimeInterval(900_000) : resetAt
      return ProviderSnapshot(
        provider: kind == .wrongProvider ? .codex : .claude,
        source: kind == .wrongSource ? .claudeCLI : .claudeDesktopDirect, capturedAt: capturedAt,
        weekly: QuotaWindow(
          remainingPercent: kind == .invalidNumber ? .nan : 80,
          durationSeconds: kind == .wrongDuration ? 18_000 : 604_800, resetAt: reset,
          resetAtIsEstimated: kind == .estimated),
        sourceState: kind == .failed ? .attemptFailed : .observationSucceeded,
        errorCode: kind == .restricted ? .usageRestricted : nil)
    }
  }

  @MainActor
  private final class AcceptanceClock {
    var wall = Date(timeIntervalSince1970: 1_900_000_000)
    var elapsed = Duration.zero
    var sleeps: [Duration] = []
    private var sleeper: CheckedContinuation<Void, Error>?
    private var waitingForSleep: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async throws {
      try Task.checkCancellation()
      sleeps.append(duration)
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          sleeper = continuation
          waitingForSleep?.resume()
          waitingForSleep = nil
        }
      } onCancel: {
        Task { @MainActor in
          self.sleeper?.resume(throwing: CancellationError())
          self.sleeper = nil
        }
      }
    }

    func advance(by duration: Duration) async {
      if sleeper == nil { await withCheckedContinuation { waitingForSleep = $0 } }
      elapsed += duration
      wall = wall.addingTimeInterval(Double(duration.components.seconds))
      let previous = sleeper
      sleeper = nil
      previous?.resume()
    }
  }

  @MainActor
  private final class AcceptanceGate {
    private var entered = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func pause() async {
      entered = true
      waiting?.resume()
      waiting = nil
      await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
      if !entered { await withCheckedContinuation { waiting = $0 } }
    }
    func release() {
      blocked?.resume()
      blocked = nil
    }
  }

  @MainActor
  private final class AcceptanceConnection: DesktopAcceptanceConnecting {
    var currentStatus = DesktopConnectionController.Status.current
    var value: ProviderSnapshot?
    var nextAllowedAt: Date?
    var connects = 0
    var refreshes = 0
    var disconnects = 0
    var reads = 0
    var refresh: (() -> Void)?
    var connectGate: AcceptanceGate?
    var refreshGate: AcceptanceGate?
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var completionWaiter: CheckedContinuation<Void, Never>?
    private var lateCompleted = false

    var status: DesktopConnectionController.Status {
      reads += 1
      readWaiter?.resume()
      readWaiter = nil
      return currentStatus
    }
    var snapshot: ProviderSnapshot? { value }
    func connectForAcceptance() async {
      connects += 1
      if let connectGate {
        await connectGate.pause()
        completeLate()
      }
    }
    func refreshForAcceptance() async {
      refreshes += 1
      if let refreshGate {
        await refreshGate.pause()
        completeLate()
      }
      refresh?()
    }
    func disconnect() async { disconnects += 1 }
    func waitForRead(after previous: Int = 0) async {
      if reads <= previous { await withCheckedContinuation { readWaiter = $0 } }
    }
    private func completeLate() {
      lateCompleted = true
      completionWaiter?.resume()
      completionWaiter = nil
    }
    func waitForCompletion() async {
      if !lateCompleted { await withCheckedContinuation { completionWaiter = $0 } }
    }
  }
#endif
