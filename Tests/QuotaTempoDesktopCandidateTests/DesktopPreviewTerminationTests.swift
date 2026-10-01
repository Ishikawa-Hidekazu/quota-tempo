import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

private enum TerminationEvent: Equatable, Sendable {
  case deadline(ContinuousClock.Instant)
  case deadlineFinished, deadlineCancelled
  case stopStarted, stopFinished, stopCancelled, unexpectedStop
  case stopReleased, deadlineReleased
  case unblocked(Bool)
  case cancellationUnblocked(Bool)
  case timeout
  case exit(Int32)
}

private final class TerminationEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [TerminationEvent] = []

  var values: [TerminationEvent] { lock.withLock { recorded } }
  func add(_ event: TerminationEvent) { lock.withLock { recorded.append(event) } }
}

private final class TerminationGate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream<Void>.makeStream()
  }

  func wait() async { for await _ in stream {} }
  func open() { continuation.finish() }
}

private final class TerminationCapture: Sendable {
  let onRelease: @Sendable () -> Void

  init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
  deinit { onRelease() }
}

private func terminationEventually(_ predicate: @Sendable () -> Bool) async -> Bool {
  let limit = ContinuousClock.now.advanced(by: .seconds(2))
  while ContinuousClock.now < limit {
    if predicate() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return predicate()
}

@Suite("Desktop preview termination", .serialized)
struct DesktopPreviewTerminationTests {
  @Test func initializationIsInert() {
    let events = TerminationEvents()
    let termination = DesktopPreviewTermination(
      waitForDeadline: { events.add(.deadline($0)) },
      onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
    withExtendedLifetime(termination) { #expect(events.values.isEmpty) }
  }

  @Test func normalCleanupCancelsDeadlineAndDoubleQuitIsIdempotent() async throws {
    let events = TerminationEvents()
    let cleanup = TerminationGate()
    let timer = TerminationGate()
    defer {
      cleanup.open()
      timer.open()
    }
    let termination = DesktopPreviewTermination(
      waitForDeadline: { deadline in
        events.add(.deadline(deadline))
        await withTaskCancellationHandler {
          await timer.wait()
        } onCancel: {
          events.add(.deadlineCancelled)
        }
        events.add(.deadlineFinished)
        // Deliberately return on cancellation; the controller must not treat this as timeout.
      }, onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
    let before = ContinuousClock.now
    termination.finish(code: 7) {
      events.add(.stopStarted)
      await cleanup.wait()
      events.add(.stopFinished)
    }
    let after = ContinuousClock.now
    termination.finish(code: 99) { events.add(.unexpectedStop) }
    try #require(
      await terminationEventually {
        events.values.contains(.stopStarted)
          && events.values.contains {
            if case .deadline = $0 { return true }
            return false
          }
      })
    let deadline = try #require(
      events.values.compactMap { event -> ContinuousClock.Instant? in
        if case .deadline(let instant) = event { return instant }
        return nil
      }.first)
    #expect(deadline >= before.advanced(by: .seconds(3)))
    #expect(deadline <= after.advanced(by: .seconds(3)))
    cleanup.open()
    try #require(
      await terminationEventually {
        events.values.contains(.exit(7)) && events.values.contains(.deadlineFinished)
      })
    termination.finish(code: 99) { events.add(.unexpectedStop) }
    #expect(events.values.filter { $0 == .stopStarted }.count == 1)
    #expect(
      events.values.filter {
        if case .exit = $0 { return true }
        return false
      } == [.exit(7)])
    #expect(events.values.contains(.deadlineCancelled))
    let cancelIndex = try #require(events.values.firstIndex(of: .deadlineCancelled))
    let exitIndex = try #require(events.values.firstIndex(of: .exit(7)))
    #expect(cancelIndex < exitIndex)
    #expect(!events.values.contains(.timeout))
    #expect(!events.values.contains(.unexpectedStop))
  }

  @Test("Blocked synchronous cleanup cannot delay timeout", arguments: [false, true])
  func blockedCleanupCannotDelayTimeout(onMainActor: Bool) async throws {
    let events = TerminationEvents()
    let timer = TerminationGate()
    let unblock = DispatchSemaphore(value: 0)
    defer {
      unblock.signal()
      timer.open()
    }
    let termination = DesktopPreviewTermination(
      waitForDeadline: { deadline in
        events.add(.deadline(deadline))
        await timer.wait()
        events.add(.deadlineFinished)
      }, onTimeout: { events.add(.timeout) },
      requestExit: {
        events.add(.exit($0))
        unblock.signal()
      })
    let stop: @Sendable () -> Void = {
      events.add(.stopStarted)
      timer.open()
      events.add(.unblocked(unblock.wait(timeout: .now() + 1) == .success))
      events.add(.stopFinished)
    }
    await MainActor.run {
      termination.finish(code: 7) {
        if onMainActor { await MainActor.run { stop() } } else { stop() }
      }
      termination.finish(code: 99) { events.add(.unexpectedStop) }
    }
    try #require(await terminationEventually { events.values.contains(.stopFinished) })
    #expect(events.values.contains(.unblocked(true)))
    #expect(events.values.filter { $0 == .timeout }.count == 1)
    #expect(
      events.values.filter {
        if case .exit = $0 { return true }
        return false
      } == [.exit(2)])
    #expect(!events.values.contains(.unexpectedStop))
    let exitIndex = try #require(events.values.firstIndex(of: .exit(2)))
    let stopIndex = try #require(events.values.firstIndex(of: .stopFinished))
    #expect(exitIndex < stopIndex)
  }

  @Test func cancellationHandlerCannotDelayExitRequest() async throws {
    let events = TerminationEvents()
    let cleanup = TerminationGate()
    let timer = TerminationGate()
    let exitRequested = DispatchSemaphore(value: 0)
    defer {
      cleanup.open()
      timer.open()
      exitRequested.signal()
    }
    let termination = DesktopPreviewTermination(
      waitForDeadline: { _ in await timer.wait() },
      onTimeout: { events.add(.timeout) },
      requestExit: {
        events.add(.exit($0))
        exitRequested.signal()
      })
    termination.finish(code: 0) {
      await withTaskCancellationHandler {
        events.add(.stopStarted)
        await cleanup.wait()
        events.add(.stopFinished)
      } onCancel: {
        events.add(.cancellationUnblocked(exitRequested.wait(timeout: .now() + 1) == .success))
      }
    }
    try #require(await terminationEventually { events.values.contains(.stopStarted) })
    timer.open()
    try #require(
      await terminationEventually {
        events.values.contains(.cancellationUnblocked(true))
          && events.values.contains(.stopFinished)
      })
    #expect(
      events.values.filter {
        if case .exit = $0 { return true }
        return false
      } == [.exit(2)])
  }

  @Test func racingCleanupAndDeadlineRequestExactlyOneExit() async throws {
    for _ in 0..<25 {
      let events = TerminationEvents()
      let cleanup = TerminationGate()
      let timer = TerminationGate()
      defer {
        cleanup.open()
        timer.open()
      }
      let termination = DesktopPreviewTermination(
        waitForDeadline: { deadline in
          events.add(.deadline(deadline))
          await timer.wait()
          events.add(.deadlineFinished)
        }, onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
      termination.finish(code: 7) {
        events.add(.stopStarted)
        await cleanup.wait()
        events.add(.stopFinished)
      }
      try #require(
        await terminationEventually {
          events.values.contains(.stopStarted)
            && events.values.contains {
              if case .deadline = $0 { return true }
              return false
            }
        })
      cleanup.open()
      timer.open()
      try #require(
        await terminationEventually {
          events.values.contains(.stopFinished) && events.values.contains(.deadlineFinished)
            && events.values.contains {
              if case .exit = $0 { return true }
              return false
            }
        })
      termination.finish(code: 99) { events.add(.unexpectedStop) }
      let exits = events.values.filter {
        if case .exit = $0 { return true }
        return false
      }
      #expect(exits == [.exit(7)] || exits == [.exit(2)])
      #expect(events.values.filter { $0 == .timeout }.count == (exits == [.exit(2)] ? 1 : 0))
      #expect(!events.values.contains(.unexpectedStop))
    }
  }

  @Test func deinitializationCancelsTasksWithoutRetainingControllerOrRequestingExit() async throws {
    let events = TerminationEvents()
    let cleanup = TerminationGate()
    let timer = TerminationGate()
    defer {
      cleanup.open()
      timer.open()
    }
    var termination: DesktopPreviewTermination? = DesktopPreviewTermination(
      waitForDeadline: {
        [capture = TerminationCapture { events.add(.deadlineReleased) }] deadline in
        events.add(.deadline(deadline))
        await timer.wait()
        if Task.isCancelled { events.add(.deadlineCancelled) }
        events.add(.deadlineFinished)
        withExtendedLifetime(capture) {}
      }, onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
    weak let reference = termination
    termination?.finish(code: 0) { [capture = TerminationCapture { events.add(.stopReleased) }] in
      events.add(.stopStarted)
      await cleanup.wait()
      if Task.isCancelled { events.add(.stopCancelled) }
      events.add(.stopFinished)
      withExtendedLifetime(capture) {}
    }
    try #require(
      await terminationEventually {
        events.values.contains(.stopStarted)
          && events.values.contains {
            if case .deadline = $0 { return true }
            return false
          }
      })
    termination = nil
    #expect(reference == nil)
    try #require(
      await terminationEventually {
        events.values.contains(.stopReleased) && events.values.contains(.deadlineReleased)
      })
    #expect(events.values.contains(.stopCancelled))
    #expect(events.values.contains(.deadlineCancelled))
    #expect(!events.values.contains(.timeout))
    #expect(
      !events.values.contains {
        if case .exit = $0 { return true }
        return false
      })
  }
}
