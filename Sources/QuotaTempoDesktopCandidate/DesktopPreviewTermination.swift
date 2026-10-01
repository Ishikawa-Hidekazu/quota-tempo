import Foundation

// Local preview only. The lock protects state and task handles, never cleanup or callbacks.
final class DesktopPreviewTermination: @unchecked Sendable {
  private enum State { case idle, finishing, finished }

  private let lock = NSLock()
  private var state = State.idle
  private var tasks: [Task<Void, Never>] = []
  private let waitForDeadline: @Sendable (ContinuousClock.Instant) async throws -> Void
  private let onTimeout: @Sendable () -> Void
  private let requestExit: @Sendable (Int32) -> Void

  init(
    waitForDeadline: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
      try await Task.sleep(until: $0, clock: .continuous)
    },
    onTimeout: @escaping @Sendable () -> Void,
    requestExit: @escaping @Sendable (Int32) -> Void
  ) {
    self.waitForDeadline = waitForDeadline
    self.onTimeout = onTimeout
    self.requestExit = requestExit
  }

  func finish(code: Int32, stop: @escaping @Sendable () async -> Void) {
    lock.withLock {
      guard state == .idle else { return }
      state = .finishing
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      let waitForDeadline = self.waitForDeadline
      // Arm both tasks before releasing the lock. Neither task retains this controller
      // across an await, and the deadline never hops to the cleanup actor/executor.
      tasks = [
        Task.detached { [weak self] in
          do { try await waitForDeadline(deadline) } catch { return }
          guard !Task.isCancelled else { return }
          self?.complete(code: 2, timedOut: true)
        },
        Task.detached { [weak self] in
          guard !Task.isCancelled else { return }
          await stop()
          guard !Task.isCancelled else { return }
          self?.complete(code: code, timedOut: false)
        },
      ]
    }
  }

  private func complete(code: Int32, timedOut: Bool) {
    let pending: [Task<Void, Never>]? = lock.withLock {
      guard state == .finishing else { return nil }
      state = .finished
      defer { tasks.removeAll() }
      return tasks
    }
    guard let pending else { return }
    if timedOut {
      // A cleanup cancellation handler may block too. Request exit before invoking it.
      defer { for task in pending { task.cancel() } }
      onTimeout()
      requestExit(code)
      return
    }
    for task in pending { task.cancel() }
    requestExit(code)
  }

  deinit {
    for task in tasks { task.cancel() }
  }
}
