import Dispatch
import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

private enum TerminationEvent: Equatable, Sendable {
  case deadline(DispatchTime)
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
  var exits: [TerminationEvent] {
    values.filter {
      if case .exit = $0 { return true }
      return false
    }
  }
  func add(_ event: TerminationEvent) { lock.withLock { recorded.append(event) } }
}

private final class TerminationWatchdog: @unchecked Sendable {
  private let lock = NSLock()
  private var callback: (@Sendable () -> Void)?
  private let events: TerminationEvents

  init(events: TerminationEvents) { self.events = events }

  func schedule(
    deadline: DispatchTime, callback: @escaping @Sendable () -> Void
  ) -> DesktopPreviewTermination.CancelWatchdog {
    lock.withLock { self.callback = callback }
    events.add(.deadline(deadline))
    return { [events] in events.add(.deadlineCancelled) }
  }

  func fire() {
    // Keep the callback after cancel to simulate an already-enqueued dispatch event.
    let callback = lock.withLock { self.callback }
    callback?()
    events.add(.deadlineFinished)
  }
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

private func terminationEventually(
  timeout: Duration = .seconds(2), _ predicate: @Sendable () -> Bool
) async -> Bool {
  let limit = ContinuousClock.now.advanced(by: timeout)
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
    let timer = TerminationWatchdog(events: events)
    let termination = DesktopPreviewTermination(
      scheduleWatchdog: { timer.schedule(deadline: $0, callback: $1) },
      onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
    withExtendedLifetime(termination) { #expect(events.values.isEmpty) }
  }

  @Test func normalCleanupCancelsDeadlineAndDoubleQuitIsIdempotent() async throws {
    let events = TerminationEvents()
    let cleanup = TerminationGate()
    let timer = TerminationWatchdog(events: events)
    defer { cleanup.open() }
    let termination = DesktopPreviewTermination(
      scheduleWatchdog: { timer.schedule(deadline: $0, callback: $1) },
      onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
    let before = DispatchTime.now()
    termination.finish(code: 7) {
      events.add(.stopStarted)
      await cleanup.wait()
      events.add(.stopFinished)
    }
    let after = DispatchTime.now()
    termination.finish(code: 99) { events.add(.unexpectedStop) }
    try #require(await terminationEventually { events.values.contains(.stopStarted) })
    let deadlines = events.values.compactMap { event -> DispatchTime? in
      if case .deadline(let instant) = event { return instant }
      return nil
    }
    #expect(deadlines.count == 1)
    let deadline = try #require(deadlines.first)
    #expect(deadline >= before + .seconds(3))
    #expect(deadline <= after + .seconds(3))
    cleanup.open()
    try #require(await terminationEventually { events.values.contains(.exit(7)) })
    timer.fire()
    timer.fire()
    termination.finish(code: 99) { events.add(.unexpectedStop) }
    #expect(events.values.filter { $0 == .stopStarted }.count == 1)
    #expect(events.exits == [.exit(7)])
    #expect(events.values.filter { $0 == .deadlineCancelled }.count == 1)
    let cancelIndex = try #require(events.values.firstIndex(of: .deadlineCancelled))
    let exitIndex = try #require(events.values.firstIndex(of: .exit(7)))
    #expect(cancelIndex < exitIndex)
    #expect(!events.values.contains(.timeout))
    #expect(!events.values.contains(.unexpectedStop))
  }

  @Test func virtualTimeoutCancelsCleanupAndIgnoresLateCompletion() async throws {
    let events = TerminationEvents()
    let cleanup = TerminationGate()
    let timer = TerminationWatchdog(events: events)
    defer { cleanup.open() }
    let termination = DesktopPreviewTermination(
      scheduleWatchdog: { timer.schedule(deadline: $0, callback: $1) },
      onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
    termination.finish(code: 7) {
      events.add(.stopStarted)
      await cleanup.wait()
      if Task.isCancelled { events.add(.stopCancelled) }
      events.add(.stopFinished)
    }
    try #require(await terminationEventually { events.values.contains(.stopStarted) })
    timer.fire()
    timer.fire()
    termination.finish(code: 99) { events.add(.unexpectedStop) }
    try #require(await terminationEventually { events.values.contains(.stopFinished) })
    #expect(events.values.contains(.stopCancelled))
    #expect(events.values.filter { $0 == .deadlineCancelled }.count == 1)
    #expect(events.values.filter { $0 == .timeout }.count == 1)
    #expect(events.exits == [.exit(2)])
    #expect(!events.values.contains(.unexpectedStop))
  }

  @Test("Blocked synchronous cleanup cannot delay timeout", arguments: [false, true])
  func blockedCleanupCannotDelayTimeout(onMainActor: Bool) async throws {
    let events = TerminationEvents()
    let unblock = DispatchSemaphore(value: 0)
    defer { unblock.signal() }
    // Use the real three-second watchdog. The six-second wait is only a safety release
    // if it fails, and cannot depend on a Swift task or the blocked MainActor.
    let termination = DesktopPreviewTermination(
      onTimeout: { events.add(.timeout) },
      requestExit: {
        events.add(.exit($0))
        unblock.signal()
      })
    let stop: @Sendable () -> Void = {
      events.add(.stopStarted)
      events.add(.unblocked(unblock.wait(timeout: .now() + .seconds(6)) == .success))
      events.add(.stopFinished)
    }
    termination.finish(code: 7) {
      if onMainActor { await MainActor.run { stop() } } else { stop() }
    }
    termination.finish(code: 99) { events.add(.unexpectedStop) }
    try #require(
      await terminationEventually(timeout: .seconds(8)) { events.values.contains(.stopFinished) })
    #expect(events.values.contains(.unblocked(true)))
    #expect(events.values.filter { $0 == .timeout }.count == 1)
    #expect(events.exits == [.exit(2)])
    #expect(!events.values.contains(.unexpectedStop))
    let exitIndex = try #require(events.values.firstIndex(of: .exit(2)))
    let stopIndex = try #require(events.values.firstIndex(of: .stopFinished))
    #expect(exitIndex < stopIndex)
    withExtendedLifetime(termination) {}
  }

  @Test func cancellationHandlerCannotDelayExitRequest() async throws {
    let events = TerminationEvents()
    let cleanup = TerminationGate()
    let timer = TerminationWatchdog(events: events)
    let exitRequested = DispatchSemaphore(value: 0)
    defer {
      cleanup.open()
      exitRequested.signal()
    }
    let termination = DesktopPreviewTermination(
      scheduleWatchdog: { timer.schedule(deadline: $0, callback: $1) },
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
    timer.fire()
    try #require(
      await terminationEventually {
        events.values.contains(.cancellationUnblocked(true))
          && events.values.contains(.stopFinished)
      })
    #expect(events.exits == [.exit(2)])
    let exitIndex = try #require(events.values.firstIndex(of: .exit(2)))
    let cancelIndex = try #require(events.values.firstIndex(of: .cancellationUnblocked(true)))
    #expect(exitIndex < cancelIndex)
  }

  @Test func racingCleanupAndDeadlineRequestExactlyOneExit() async throws {
    for _ in 0..<25 {
      let events = TerminationEvents()
      let cleanup = TerminationGate()
      let timer = TerminationWatchdog(events: events)
      defer { cleanup.open() }
      let termination = DesktopPreviewTermination(
        scheduleWatchdog: { timer.schedule(deadline: $0, callback: $1) },
        onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
      termination.finish(code: 7) {
        events.add(.stopStarted)
        await cleanup.wait()
        events.add(.stopFinished)
      }
      try #require(await terminationEventually { events.values.contains(.stopStarted) })
      DispatchQueue(label: "QuotaTempo.test-termination-race").async { timer.fire() }
      cleanup.open()
      try #require(
        await terminationEventually {
          events.values.contains(.stopFinished) && events.values.contains(.deadlineFinished)
            && !events.exits.isEmpty
        })
      timer.fire()
      termination.finish(code: 99) { events.add(.unexpectedStop) }
      let exits = events.exits
      #expect(exits == [.exit(7)] || exits == [.exit(2)])
      #expect(events.values.filter { $0 == .timeout }.count == (exits == [.exit(2)] ? 1 : 0))
      #expect(events.values.filter { $0 == .deadlineCancelled }.count == 1)
      #expect(!events.values.contains(.unexpectedStop))
    }
  }

  @Test func deinitializationCancelsTasksWithoutRetainingControllerOrRequestingExit() async throws {
    let events = TerminationEvents()
    let cleanup = TerminationGate()
    let timer = TerminationWatchdog(events: events)
    defer { cleanup.open() }
    var termination: DesktopPreviewTermination? = DesktopPreviewTermination(
      scheduleWatchdog: {
        [capture = TerminationCapture { events.add(.deadlineReleased) }] deadline, callback in
        let cancel = timer.schedule(deadline: deadline, callback: callback)
        return { withExtendedLifetime(capture) { cancel() } }
      }, onTimeout: { events.add(.timeout) }, requestExit: { events.add(.exit($0)) })
    weak var reference = termination
    termination?.finish(code: 0) { [capture = TerminationCapture { events.add(.stopReleased) }] in
      events.add(.stopStarted)
      await cleanup.wait()
      if Task.isCancelled { events.add(.stopCancelled) }
      events.add(.stopFinished)
      withExtendedLifetime(capture) {}
    }
    try #require(await terminationEventually { events.values.contains(.stopStarted) })
    termination = nil
    #expect(reference == nil)
    timer.fire()
    try #require(
      await terminationEventually {
        events.values.contains(.stopReleased) && events.values.contains(.deadlineReleased)
      })
    #expect(events.values.contains(.stopCancelled))
    #expect(events.values.filter { $0 == .deadlineCancelled }.count == 1)
    #expect(!events.values.contains(.timeout))
    #expect(events.exits.isEmpty)
  }
}
