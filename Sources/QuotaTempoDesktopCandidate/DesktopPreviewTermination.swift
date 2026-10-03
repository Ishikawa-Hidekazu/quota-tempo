import Dispatch
import Foundation

// Local preview only. The lock protects state and task handles, never cleanup or callbacks.
final class DesktopPreviewTermination: @unchecked Sendable {
  typealias CancelWatchdog = @Sendable () -> Void
  // Schedulers must arm without invoking the callback inline; finish holds the state lock.
  typealias WatchdogScheduler =
    @Sendable (DispatchTime, @escaping @Sendable () -> Void) -> CancelWatchdog

  private enum State { case idle, finishing, finished }

  private let lock = NSLock()
  private var state = State.idle
  private var cleanupTask: Task<Void, Never>?
  private var cancelWatchdog: CancelWatchdog?
  private let scheduleWatchdog: WatchdogScheduler
  private let onTimeout: @Sendable () -> Void
  private let requestExit: @Sendable (Int32) -> Void

  init(
    scheduleWatchdog: @escaping WatchdogScheduler = { deadline, onTimeout in
      let watchdog = DispatchWatchdog(deadline: deadline, onTimeout: onTimeout)
      return { watchdog.cancel() }
    },
    onTimeout: @escaping @Sendable () -> Void,
    requestExit: @escaping @Sendable (Int32) -> Void
  ) {
    self.scheduleWatchdog = scheduleWatchdog
    self.onTimeout = onTimeout
    self.requestExit = requestExit
  }

  func finish(code: Int32, stop: @escaping @Sendable () async -> Void) {
    lock.withLock {
      guard state == .idle else { return }
      state = .finishing
      // Arm before starting cleanup. The watchdog never uses a Swift task or actor.
      cancelWatchdog = scheduleWatchdog(.now() + .seconds(3)) { [weak self] in
        self?.complete(code: 2, timedOut: true)
      }
      cleanupTask = Task.detached { [weak self] in
        guard !Task.isCancelled else { return }
        await stop()
        guard !Task.isCancelled else { return }
        self?.complete(code: code, timedOut: false)
      }
    }
  }

  private func complete(code: Int32, timedOut: Bool) {
    let pending: (cleanup: Task<Void, Never>?, cancelWatchdog: CancelWatchdog?)? = lock.withLock {
      guard state == .finishing else { return nil }
      state = .finished
      defer {
        cleanupTask = nil
        cancelWatchdog = nil
      }
      return (cleanupTask, cancelWatchdog)
    }
    guard let pending else { return }
    // Dispatch timer cancellation does not wait for the handler to finish.
    pending.cancelWatchdog?()
    // A cleanup cancellation handler may block too. Request exit before invoking it.
    defer { pending.cleanup?.cancel() }
    if timedOut { onTimeout() }
    requestExit(code)
  }

  deinit {
    cancelWatchdog?()
    cleanupTask?.cancel()
  }

  private final class DispatchWatchdog: @unchecked Sendable {
    // Dispatch sources are thread-safe; this immutable handle only schedules or cancels.
    private let timer: DispatchSourceTimer

    init(deadline: DispatchTime, onTimeout: @escaping @Sendable () -> Void) {
      timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "QuotaTempo.preview-termination", qos: .userInitiated))
      timer.setEventHandler(handler: onTimeout)
      timer.schedule(deadline: deadline, repeating: .never, leeway: .nanoseconds(0))
      timer.resume()
    }

    func cancel() { timer.cancel() }

    deinit { timer.cancel() }
  }
}
