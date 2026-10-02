import Combine
import Foundation
import QuotaTempoCore

// The app sees only the controller. Test injection cannot widen the public
// boundary to leases, account identities, approval objects, or transport replies.
protocol DesktopConnectionServing: AnyObject, DesktopPreviewServing {
  func prepareForOfflineRepair() async -> Bool
}

extension DesktopUsageCandidateService: DesktopConnectionServing {}

@MainActor
public final class DesktopConnectionController: ObservableObject {
  public enum Status: String, Equatable, Sendable {
    case disconnected, consentRequired, connecting, ready, current, stale
    case waitingForNextRefresh, waitingForProvider, renewalRequired, accessDenied
    case sourceUnavailable, temporaryFailure, invalidResponse, invalidClock
    case serviceWaitUnavailable, storageUnavailable, storeInUse, waitingForIdle
    case repairing, repaired, repairUnsupported, restartRequired

    public var text: String {
      switch self {
      case .disconnected: "Desktop connection disconnected."
      case .consentRequired: "Explicit local experiment consent is required."
      case .connecting: "Connecting to Claude Desktop."
      case .ready: "Desktop connection ready."
      case .current: "Desktop usage is current."
      case .stale: "Current Desktop usage is unavailable."
      case .waitingForNextRefresh: "Waiting for the next scheduled update."
      case .waitingForProvider: "Provider requested a wait; requests remain paused."
      case .renewalRequired: "Desktop connection needs renewal or an explicit recheck."
      case .accessDenied: "Desktop usage access is restricted."
      case .sourceUnavailable: "Desktop connection is unavailable."
      case .temporaryFailure: "Desktop connection is temporarily unavailable."
      case .invalidResponse: "Desktop usage could not be verified."
      case .invalidClock: "Local time could not be verified."
      case .serviceWaitUnavailable: "Provider wait unsupported; automatic requests stopped."
      case .storageUnavailable: "Local scheduling state could not be saved or verified."
      case .storeInUse:
        "Another Desktop connection owns scheduling state. Close it before connecting."
      case .waitingForIdle: "Previous Desktop work must finish before this action."
      case .repairing: "Repairing local scheduling state."
      case .repaired: "Local scheduling state checked; provider limits still apply."
      case .repairUnsupported: "Local scheduling state uses an unsupported version."
      case .restartRequired: "Scheduling storage is still owned; restart is required."
      }
    }
  }

  public enum RepairResult: Equatable, Sendable {
    case notNeeded, preserved, repaired, unsupportedVersion
    case busy, restartRequired, failed, cancelled
  }

  @Published public private(set) var snapshot: ProviderSnapshot?
  @Published public private(set) var status: Status = .disconnected
  @Published public private(set) var nextAllowedAt: Date?
  // Connected means explicitly opted in, not a claim of successful acquisition.
  @Published public private(set) var isConnected = false
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var isRepairing = false

  public var statusText: String { status.text }

  private let clock: @Sendable () -> Date
  private let makeService: @MainActor () throws -> any DesktopConnectionServing
  private let repairStore: @MainActor (Date) throws -> DesktopThrottleRecoveryResult
  private let displayInterval: Duration
  private var service: (any DesktopConnectionServing)?
  private var serviceApproved = false
  private var generation = UUID()
  private var approvalID: UUID?
  private var approvalTask: Task<Void, Never>?
  private var refreshID: UUID?
  private var refreshTask: Task<DesktopUsageCandidateResult, Never>?
  private var displayTask: Task<Void, Never>?
  private var lastResult: DesktopUsageCandidateResult?

  /// `directory` is a private scheduling directory, not the credential directory.
  /// Explicit connection may create its last two missing directories below a
  /// validated owner-controlled parent. Initialization opens nothing.
  /// Offline repair of a not-yet-created directory is a no-op.
  /// Consent is memory-only and must never be restored automatically at launch.
  public convenience init(
    directory: URL, clock: @escaping @Sendable () -> Date = Date.init
  ) {
    self.init(
      clock: clock,
      makeService: {
        let store = try DesktopThrottleFileStore.prepared(directory: directory)
        return DesktopUsageCandidateService(clock: clock, throttleStore: store)
      },
      repairStore: { now in
        guard directory.isFileURL,
          directory.host == nil || directory.host == "" || directory.host == "localhost",
          directory.path.hasPrefix("/"), !directory.path.utf8.contains(0)
        else { throw DesktopThrottleStoreError.unsafePath }
        do {
          _ = try FileManager.default.attributesOfItem(atPath: directory.path)
        } catch let error as CocoaError
          where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        {
          return .notNeeded
        }
        return try DesktopThrottleFileStore.recover(directory: directory, now: now)
      })
  }

  init(
    clock: @escaping @Sendable () -> Date = Date.init,
    displayInterval: Duration = .seconds(1),
    makeService: @escaping @MainActor () throws -> any DesktopConnectionServing,
    repairStore: @escaping @MainActor (Date) throws -> DesktopThrottleRecoveryResult
  ) {
    self.clock = clock
    self.displayInterval = displayInterval
    self.makeService = makeService
    self.repairStore = repairStore
  }

  /// Calling with true is the explicit consent action for this local experiment;
  /// it is not provider approval. False revokes consent without creating a service.
  public func connect(localExperimentAuthorized: Bool) async {
    guard localExperimentAuthorized else {
      await disconnect()
      if !isConnected { status = .consentRequired }
      return
    }
    guard !Task.isCancelled, !isConnected else { return }
    guard !isRepairing, approvalTask == nil, refreshTask == nil else {
      status = .waitingForIdle
      return
    }
    generation = UUID()
    let expected = generation
    isConnected = true
    status = .connecting
    do {
      if service == nil { service = try makeService() }
    } catch DesktopThrottleStoreError.locked {
      isConnected = false
      status = .storeInUse
      return
    } catch {
      status = .storageUnavailable
      return
    }
    await setApproval(DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true))
    guard generation == expected, isConnected else { return }
    guard !Task.isCancelled else {
      await disconnect()
      return
    }
    serviceApproved = true
    status = .ready
    startDisplayUpdates()
    await refresh()
  }

  /// Clears display before the first suspension. A cancelled, non-cooperative
  /// refresh retains its service/lock until it finishes, but cannot publish.
  public func disconnect() async {
    generation = UUID()
    isConnected = false
    serviceApproved = false
    refreshTask?.cancel()
    displayTask?.cancel()
    displayTask = nil
    isRefreshing = false
    lastResult = nil
    snapshot = nil
    nextAllowedAt = nil
    status = .disconnected
    await setApproval(DesktopAccessApproval())
  }

  /// No acquisition timer or source fallback. Recheck uses the service's durable
  /// admission rules; neither reconnect nor recheck replaces its throttle store.
  public func refresh(recheck: Bool = false) async {
    guard isConnected, serviceApproved, !isRepairing, !Task.isCancelled else { return }
    updateDisplay()
    guard approvalTask == nil, refreshTask == nil, let service else { return }
    let expected = generation
    let id = UUID()
    refreshID = id
    isRefreshing = true
    let task = Task {
      recheck ? await service.recheckConnection() : await service.refresh()
    }
    refreshTask = task
    defer {
      if refreshID == id {
        refreshID = nil
        refreshTask = nil
        if generation == expected { isRefreshing = false }
      }
    }
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    guard generation == expected, isConnected, !Task.isCancelled, !task.isCancelled,
      result.disposition == .replaceDisplay
    else { return }
    lastResult = result
    nextAllowedAt = result.nextAllowedAt.flatMap {
      $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 ? $0 : nil
    }
    updateDisplay()
  }

  /// Explicit offline repair is allowed without acquisition consent. It revokes
  /// any prior consent and stays disconnected until a new explicit connect call.
  /// Busy work is refused: cancellation is not proof a store owner has exited.
  /// A retained owner returns restartRequired instead of force-unlocking a file.
  @discardableResult
  public func repair() async -> RepairResult {
    guard !Task.isCancelled else { return .cancelled }
    guard !isRepairing, approvalTask == nil, refreshTask == nil else {
      status = .waitingForIdle
      return .busy
    }
    isRepairing = true
    defer { isRepairing = false }
    generation = UUID()
    let expected = generation
    isConnected = false
    serviceApproved = false
    isRefreshing = false
    displayTask?.cancel()
    displayTask = nil
    lastResult = nil
    snapshot = nil
    status = .repairing
    await setApproval(DesktopAccessApproval())
    guard generation == expected else { return .cancelled }
    guard !Task.isCancelled else {
      await disconnect()
      return .cancelled
    }
    let prepared = await service?.prepareForOfflineRepair() ?? true
    guard generation == expected else { return .cancelled }
    guard !Task.isCancelled else {
      await disconnect()
      return .cancelled
    }
    guard prepared else {
      status = .storageUnavailable
      return .failed
    }

    weak var previousService = service
    service = nil
    guard previousService == nil else {
      // Preserve the revoked owner for a later safe retry, never a second owner.
      service = previousService
      status = .restartRequired
      return .restartRequired
    }
    let outcome: DesktopThrottleRecoveryResult
    do {
      outcome = try repairStore(clock())
      guard outcome != .unsupportedVersion else {
        status = .repairUnsupported
        return .unsupportedVersion
      }
    } catch {
      status = .storageUnavailable
      return .failed
    }
    status = .repaired
    switch outcome {
    case .notNeeded: return .notNeeded
    case .preserved: return .preserved
    case .repaired: return .repaired
    case .unsupportedVersion: return .unsupportedVersion
    }
  }

  // Serialize approval changes even across actor suspension. A disconnect queued
  // during connect/repair must be the final reader approval, never overtaken.
  private func setApproval(_ approval: DesktopAccessApproval) async {
    guard let service else { return }
    let previous = approvalTask
    let id = UUID()
    let task = Task {
      await previous?.value
      await service.setApproval(approval)
    }
    approvalID = id
    approvalTask = task
    await task.value
    if approvalID == id {
      approvalID = nil
      approvalTask = nil
    }
  }

  private func startDisplayUpdates() {
    displayTask?.cancel()
    let expected = generation
    let interval = displayInterval
    displayTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { return }
        guard let self, self.isConnected, self.generation == expected else { return }
        self.updateDisplay()
      }
    }
  }

  /// Re-evaluates only the in-memory result at the current clock. This never
  /// reads protected storage, changes approval, or makes a network request.
  public func updateDisplay() {
    guard isConnected, !isRepairing, let lastResult,
      let projected = DesktopPreviewPresentation.snapshot(lastResult, now: clock())
    else { return }
    if snapshot != projected { snapshot = projected }
    let updated = Self.status(for: lastResult, snapshot: projected)
    if status != updated { status = updated }
  }

  private static func status(
    for result: DesktopUsageCandidateResult, snapshot: ProviderSnapshot
  ) -> Status {
    if result.state == .persistenceUnavailable { return .storageUnavailable }
    if let error = result.credentialError {
      switch error {
      case .consentRequired, .providerApprovalRequired: return .consentRequired
      case .permissionRequired, .missingScope: return .accessDenied
      case .expired: return .renewalRequired
      case .keychainLocked, .changedDuringRead: return .temporaryFailure
      case .invalidStore, .unsafePath, .inputTooLarge: return .invalidResponse
      case .unavailable, .identityUnavailable, .ambiguousIdentity: return .sourceUnavailable
      }
    }
    switch result.state {
    case .consentRequired: return .consentRequired
    case .permissionDenied, .missingScope, .accessDenied: return .accessDenied
    case .credentialExpired, .waitingForDesktopRenewal: return .renewalRequired
    case .identityUnavailable: return .sourceUnavailable
    case .contextChanged: return snapshot.weekly == nil ? .sourceUnavailable : .current
    case .ready, .requesting: return .ready
    case .current: return snapshot.weekly == nil ? .stale : .current
    case .stale, .resetElapsed: return .stale
    case .rateLimited, .waitingForProvider: return .waitingForProvider
    case .temporaryFailure, .timedOut: return .temporaryFailure
    case .invalidResponse, .identityMismatch: return .invalidResponse
    case .invalidClock: return .invalidClock
    case .serviceWaitUnavailable: return .serviceWaitUnavailable
    case .persistenceUnavailable: return .storageUnavailable
    case .waitingForNextRefresh: return .waitingForNextRefresh
    }
  }

  deinit {
    refreshTask?.cancel()
    displayTask?.cancel()
  }
}
