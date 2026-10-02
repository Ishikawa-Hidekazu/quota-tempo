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
    case repairing, repaired, repairUnsupported, restartRequired, consentStorageUnavailable
    case keychainPermissionRequired, requestingKeychainAccess

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
      case .consentStorageUnavailable:
        "Connection stopped; consent preference could not be saved or verified."
      case .keychainPermissionRequired:
        "macOS permission is needed to access Claude Desktop authentication."
      case .requestingKeychainAccess: "Waiting for your response to macOS access permission."
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
  @Published public private(set) var consentPersistenceFailed = false
  @Published public private(set) var isRequestingKeychainAccess = false

  public var canRequestKeychainAccess: Bool {
    isConnected && !isRepairing && !isRefreshing && !isRequestingKeychainAccess
      && approvalTask == nil && refreshTask == nil
      && lastResult?.credentialError == .permissionRequired
  }

  public var statusText: String { status.text }

  private let clock: @Sendable () -> Date
  private let makeService: @MainActor () throws -> any DesktopConnectionServing
  private let repairStore: @MainActor (Date) throws -> DesktopThrottleRecoveryResult
  private let displayInterval: Duration
  private let authorizeKeychainAccess: @Sendable () async -> Bool
  private var consentStore: (any DesktopConnectionConsentStoring)?
  private var attemptedResume = false
  private var service: (any DesktopConnectionServing)?
  private var serviceApproved = false
  private var generation = UUID()
  private var approvalID: UUID?
  private var approvalTask: Task<Void, Never>?
  private var refreshID: UUID?
  private var refreshTask: Task<DesktopUsageCandidateResult, Never>?
  private var displayTask: Task<Void, Never>?
  private var keychainTask: Task<Bool, Never>?
  private var lastResult: DesktopUsageCandidateResult?

  /// `directory` is a private scheduling directory, not the credential directory.
  /// Explicit connection may create its last two missing directories below a
  /// validated owner-controlled parent. Initialization opens nothing.
  /// Offline repair of a not-yet-created directory is a no-op.
  /// Without consent preferences, consent remains limited to this process.
  public convenience init(
    directory: URL, clock: @escaping @Sendable () -> Date = Date.init,
    consentDefaults: UserDefaults? = nil
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
      },
      consentStore: consentDefaults.map { DesktopConnectionConsentPreferences(defaults: $0) },
      authorizeKeychainAccess: { await DesktopKeychainAuthorization.request() })
  }

  init(
    clock: @escaping @Sendable () -> Date = Date.init,
    displayInterval: Duration = .seconds(1),
    makeService: @escaping @MainActor () throws -> any DesktopConnectionServing,
    repairStore: @escaping @MainActor (Date) throws -> DesktopThrottleRecoveryResult,
    consentStore: (any DesktopConnectionConsentStoring)? = nil,
    authorizeKeychainAccess: @escaping @Sendable () async -> Bool = { false }
  ) {
    self.clock = clock
    self.displayInterval = displayInterval
    self.makeService = makeService
    self.repairStore = repairStore
    self.consentStore = consentStore
    self.authorizeKeychainAccess = authorizeKeychainAccess
  }

  /// Called once at app startup, only with acquisition enabled. Restored consent
  /// uses the normal service/store and cannot shorten an existing provider wait.
  /// No snapshots, credentials, account identity or approval objects are restored.
  public func resumeIfConsented(acquisitionAllowed: Bool) async {
    guard !attemptedResume, !Task.isCancelled else { return }
    attemptedResume = true
    guard acquisitionAllowed, !isConnected, let consentStore else { return }
    do {
      guard try consentStore.isAccepted() else { return }
    } catch {
      consentPersistenceFailed = true
      status = .consentStorageUnavailable
      return
    }
    await startConnection()
  }

  /// Calling with true is the explicit consent action for this local experiment;
  /// it is not provider approval. False revokes consent without creating a service.
  public func connect(localExperimentAuthorized: Bool) async {
    guard localExperimentAuthorized else {
      await disconnect()
      if !isConnected && !consentPersistenceFailed { status = .consentRequired }
      return
    }
    guard !Task.isCancelled, !isConnected else { return }
    guard !isRepairing, !isRequestingKeychainAccess, approvalTask == nil, refreshTask == nil else {
      status = .waitingForIdle
      return
    }
    guard persistConsent(true) else { return }
    await startConnection()
  }

  private func startConnection() async {
    guard !Task.isCancelled, !isConnected, !isRepairing, !isRequestingKeychainAccess,
      approvalTask == nil, refreshTask == nil
    else { return }
    generation = UUID()
    let expected = generation
    isConnected = true
    status = .connecting
    do {
      if service == nil { service = try makeService() }
    } catch DesktopThrottleStoreError.locked {
      isConnected = false
      // The disconnected UI must not retain an invisible startup approval.
      if persistConsent(false) { status = .storeInUse }
      return
    } catch {
      isConnected = false
      if persistConsent(false) { status = .storageUnavailable }
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
    revokeConsent()
    await approvalTask?.value
  }

  /// Synchronous revocation fences queued startup work and clears remembered
  /// consent before a provider toggle or UI action can return to the event loop.
  public func revokeConsent() {
    attemptedResume = true
    let persisted = persistConsent(false)
    generation = UUID()
    isConnected = false
    serviceApproved = false
    refreshTask?.cancel()
    keychainTask?.cancel()
    displayTask?.cancel()
    displayTask = nil
    isRefreshing = false
    lastResult = nil
    snapshot = nil
    nextAllowedAt = nil
    status = persisted ? .disconnected : .consentStorageUnavailable
    _ = scheduleApproval(DesktopAccessApproval())
  }

  private func persistConsent(_ accepted: Bool) -> Bool {
    do {
      try consentStore?.setAccepted(accepted)
      consentPersistenceFailed = false
      return true
    } catch {
      consentPersistenceFailed = true
      status = .consentStorageUnavailable
      return false
    }
  }

  /// No acquisition timer or source fallback. Recheck uses the service's durable
  /// admission rules; neither reconnect nor recheck replaces its throttle store.
  public func refresh(recheck: Bool = false) async {
    guard isConnected, serviceApproved, !isRepairing, !isRequestingKeychainAccess, !Task.isCancelled
    else { return }
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

  /// User-action-only OS permission flow. Startup, timers, wake and Recheck must
  /// never call this. A local permission grant is not a provider recheck permit.
  public func requestKeychainAccess() async {
    guard !Task.isCancelled, canRequestKeychainAccess else { return }
    isRequestingKeychainAccess = true
    status = .requestingKeychainAccess
    let expected = generation
    let authorize = authorizeKeychainAccess
    let task = Task { await authorize() }
    keychainTask = task
    defer {
      keychainTask = nil
      isRequestingKeychainAccess = false
    }
    let granted = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    guard generation == expected, isConnected else { return }
    guard !task.isCancelled, !Task.isCancelled else {
      await disconnect()
      return
    }
    guard granted else {
      status = .keychainPermissionRequired
      return
    }
    await setApproval(DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true))
    guard generation == expected, isConnected else { return }
    guard !Task.isCancelled else {
      await disconnect()
      return
    }
    lastResult = nil
    status = .ready
    isRequestingKeychainAccess = false
    await refresh()
  }

  /// Explicit offline repair is allowed without acquisition consent. It revokes
  /// any prior consent and stays disconnected until a new explicit connect call.
  /// Busy work is refused: cancellation is not proof a store owner has exited.
  /// A retained owner returns restartRequired instead of force-unlocking a file.
  @discardableResult
  public func repair() async -> RepairResult {
    guard !Task.isCancelled else { return .cancelled }
    guard !isRepairing, !isRequestingKeychainAccess, approvalTask == nil, refreshTask == nil else {
      status = .waitingForIdle
      return .busy
    }
    guard persistConsent(false) else {
      await disconnect()
      return .failed
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
    await scheduleApproval(approval)?.value
  }

  private func scheduleApproval(_ approval: DesktopAccessApproval) -> Task<Void, Never>? {
    guard let service else { return nil }
    let previous = approvalTask
    let id = UUID()
    let task = Task { [weak self] in
      await previous?.value
      await service.setApproval(approval)
      if self?.approvalID == id {
        self?.approvalID = nil
        self?.approvalTask = nil
      }
    }
    approvalID = id
    approvalTask = task
    return task
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
    guard isConnected, !isRepairing, !isRequestingKeychainAccess, let lastResult,
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
      case .permissionRequired: return .keychainPermissionRequired
      case .missingScope: return .accessDenied
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
    keychainTask?.cancel()
    displayTask?.cancel()
  }
}
