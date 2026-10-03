import Foundation
import Testing

@testable import QuotaTempoCore

@Suite("Codex restriction retention")
struct CodexRestrictionRetentionTests {
  private let capturedAt = Date(timeIntervalSince1970: 1_789_300_800)

  @Test("Failed acquisition retains known exhaustion only before reset", arguments: [-1, 0, 1])
  func resetBoundary(offset: Int) {
    let previous = self.restricted(weekly: self.window(resetAfter: 600))
    let now = self.capturedAt.addingTimeInterval(600 + Double(offset))
    let cases: [(BoundedProcessError, SourceState, AcquisitionErrorCode)] = [
      (.timeout, .attemptTimedOut, .timeout),
      (.launchFailed, .attemptFailed, .launchFailed),
      (.inputWriteFailed, .attemptFailed, .temporaryFailure),
      (.outputLimitExceeded, .attemptFailed, .outputLimitExceeded),
    ]
    for (failure, state, error) in cases {
      let snapshot = self.adapter(failure: failure).refresh(previous: previous, now: now)
      #expect(snapshot.sourceState == (offset < 0 ? .accessRestricted : state))
      #expect(snapshot.errorCode == (offset < 0 ? .usageRestricted : error))
      #expect(snapshot.weekly == previous.weekly)
      #expect(snapshot.capturedAt == previous.capturedAt)
      #expect(snapshot.lastAttemptAt == now)
      #expect(QuotaPlanner.evaluate(snapshot, now: now).availableUntilCheckpoint == nil)
    }
  }

  @Test("Repeated failures do not extend the original restriction deadline")
  func repeatedFailures() {
    let adapter = self.adapter()
    var previous = self.restricted(weekly: self.window(resetAfter: 600))
    for offset in [300, 599, 600, 601] {
      let now = self.capturedAt.addingTimeInterval(Double(offset))
      previous = adapter.refresh(previous: previous, now: now)
      #expect(previous.sourceState == (offset < 600 ? .accessRestricted : .attemptTimedOut))
      #expect(previous.errorCode == (offset < 600 ? .usageRestricted : .timeout))
      #expect(previous.capturedAt == self.capturedAt)
      #expect(previous.weekly?.resetAt == self.capturedAt.addingTimeInterval(600))
      #expect(previous.lastAttemptAt == now)
    }
  }

  @Test("All exhausted windows must reset, but a positive window cannot extend restriction")
  func exhaustedWindowSelection() {
    for weeklyRemaining in [0.0, 80.0] {
      let previous = self.restricted(
        weekly: self.window(remaining: weeklyRemaining, resetAfter: 1_200),
        fiveHour: self.window(resetAfter: 600, duration: 18_000))
      for offset in [599, 600, 601, 1_199, 1_200, 1_201] {
        let now = self.capturedAt.addingTimeInterval(Double(offset))
        let snapshot = self.adapter().refresh(previous: previous, now: now)
        let retained = offset < (weeklyRemaining == 0 ? 1_200 : 600)
        #expect(snapshot.sourceState == (retained ? .accessRestricted : .attemptTimedOut))
        #expect(snapshot.errorCode == (retained ? .usageRestricted : .timeout))
        #expect(snapshot.weekly == previous.weekly)
        #expect(snapshot.fiveHour == previous.fiveHour)
      }
    }
    let fiveHourOnly = self.restricted(
      weekly: nil, fiveHour: self.window(resetAfter: 600, duration: 18_000))
    let snapshot = self.adapter().refresh(
      previous: fiveHourOnly, now: self.capturedAt.addingTimeInterval(600))
    #expect(snapshot.sourceState == .attemptTimedOut)
    #expect(snapshot.errorCode == .timeout)
  }

  @Test("Unknown or estimated restriction deadlines remain conservative")
  func unknownDeadline() {
    let previousSnapshots = [
      self.restricted(weekly: nil),
      self.restricted(weekly: self.window(resetAfter: nil)),
      self.restricted(weekly: self.window(resetAfter: 600, estimated: true)),
      self.restricted(
        weekly: self.window(resetAfter: 600),
        fiveHour: self.window(resetAfter: nil, duration: 18_000)),
      self.restricted(weekly: self.window(remaining: 80, resetAfter: 600)),
    ]
    for previous in previousSnapshots {
      let snapshot = self.adapter().refresh(
        previous: previous, now: self.capturedAt.addingTimeInterval(604_800))
      #expect(snapshot.sourceState == .accessRestricted)
      #expect(snapshot.errorCode == .usageRestricted)
      #expect(snapshot.capturedAt == previous.capturedAt)
    }
  }

  @Test("Missing installation also exposes its actual failure at reset")
  func missingInstallation() {
    let adapter = CodexRateLimitAdapter(
      runner: StubRunner(result: .failure(.launchFailed)),
      versionRunner: StubRunner(result: .failure(.launchFailed)), candidates: [])
    let previous = self.restricted(weekly: self.window(resetAfter: 600))
    for offset in [599, 600, 601] {
      let snapshot = adapter.refresh(
        previous: previous, now: self.capturedAt.addingTimeInterval(Double(offset)))
      #expect(snapshot.sourceState == (offset < 600 ? .accessRestricted : .attemptFailed))
      #expect(snapshot.errorCode == (offset < 600 ? .usageRestricted : .sourceNotInstalled))
    }
  }

  @Test("Post-reset protocol and version diagnostics are not hidden by an old restriction")
  func diagnosticFailures() {
    let previous = self.restricted(weekly: self.window(resetAfter: 600))
    for versionTooOld in [false, true] {
      let adapter = CodexRateLimitAdapter(
        runner: StubRunner(result: .success(self.response("{}"))),
        versionRunner: StubRunner(
          result: .success(self.response(versionTooOld ? "codex 0.133.0" : "codex 0.134.0"))),
        executable: URL(fileURLWithPath: "/mock/codex"))
      let snapshot = adapter.refresh(
        previous: previous, now: self.capturedAt.addingTimeInterval(600))
      #expect(snapshot.sourceState == .attemptFailed)
      #expect(snapshot.errorCode == (versionTooOld ? .versionTooOld : .protocolIncompatible))
    }
  }

  private func adapter(failure: BoundedProcessError = .timeout) -> CodexRateLimitAdapter {
    CodexRateLimitAdapter(
      runner: StubRunner(result: .failure(failure)),
      versionRunner: StubRunner(result: .failure(.launchFailed)),
      executable: URL(fileURLWithPath: "/mock/codex"))
  }

  private func restricted(weekly: QuotaWindow?, fiveHour: QuotaWindow? = nil) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .codex, source: .codexAppServer, capturedAt: self.capturedAt,
      weekly: weekly, fiveHour: fiveHour, lastAttemptAt: self.capturedAt,
      sourceState: .accessRestricted, errorCode: .usageRestricted)
  }

  private func window(
    remaining: Double = 0, resetAfter: TimeInterval?, duration: TimeInterval = 604_800,
    estimated: Bool = false
  ) -> QuotaWindow {
    QuotaWindow(
      remainingPercent: remaining, durationSeconds: duration,
      resetAt: resetAfter.map { self.capturedAt.addingTimeInterval($0) },
      resetAtIsEstimated: estimated)
  }

  private func response(_ text: String) -> BoundedProcessResult {
    BoundedProcessResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
  }

  private struct StubRunner: BoundedProcessRunning {
    let result: Result<BoundedProcessResult, BoundedProcessError>

    func run(
      executable: URL, arguments: [String], stdin: Data, currentDirectory: URL?
    ) throws -> BoundedProcessResult {
      try self.result.get()
    }
  }
}
