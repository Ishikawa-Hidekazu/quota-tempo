import Foundation

protocol DesktopCredentialReading: Sendable {
  func setApproval(_ approval: DesktopAccessApproval) async
  func load(now: Date) async throws -> DesktopCredentialLease
  func currentContext(for lease: DesktopCredentialLease, now: Date) async -> DesktopUsageContext?
}

extension DesktopCredentialReader: DesktopCredentialReading {}

struct DesktopUsageCandidateResult: Sendable {
  enum Disposition: Equatable, Sendable {
    // Apply the result, including clearing the display when observation is nil.
    case replaceDisplay
    // Preserve the display; metadata below is not an acquisition result. The
    // original refresh caller will receive the result without sharing cancellation.
    case unchangedInFlight
  }

  // Callers must check this before applying state, observation, or credentialError.
  let disposition: Disposition
  let state: DesktopUsageState
  let observation: DesktopUsageObservation?
  let credentialError: DesktopCredentialError?
  let nextAllowedAt: Date?
}

// Isolated candidate orchestration. No timer, UI, or shipped caller.
actor DesktopUsageCandidateService {
  typealias Fetch =
    @Sendable (DesktopUsageRequest, DesktopCredentialLease) async -> DesktopUsageReply
  private let reader: any DesktopCredentialReading
  private let fetch: Fetch
  private let clock: @Sendable () -> Date
  private let throttleStore: any DesktopThrottleStoring
  private var throttleLoaded = false
  private var persistenceFailed = false
  private var lastSavedRecord: DesktopThrottleRecord?
  private var approval = DesktopAccessApproval()
  private var approvalRevision = UUID()
  private var coordinator = DesktopUsageCoordinator()
  private var refreshID: UUID?
  private var task: Task<DesktopUsageCandidateResult, Never>?
  private var activeRefreshes = 0
  private var activeApprovalChanges = 0

  init(
    reader: any DesktopCredentialReading = DesktopCredentialReader(),
    clock: @escaping @Sendable () -> Date = Date.init,
    throttleStore: any DesktopThrottleStoring,
    fetch: @escaping Fetch = { request, lease in
      await DesktopUsageHTTPTransport().fetch(request: request, lease: lease)
    }
  ) {
    self.reader = reader
    self.clock = clock
    self.fetch = fetch
    self.throttleStore = throttleStore
  }

  func setApproval(_ approval: DesktopAccessApproval) async {
    activeApprovalChanges += 1
    defer { activeApprovalChanges -= 1 }
    self.approval = approval
    approvalRevision = UUID()
    task?.cancel()
    task = nil
    refreshID = nil
    coordinator.setPermission(approval.allowsAccess ? .allowed : .denied)
    await reader.setApproval(approval)
  }

  // Offline metadata only. Revocation cancels work but cannot prove that a
  // non-cooperative reader/fetch has returned or finished recording restrictions.
  func prepareForOfflineRepair() async -> Bool {
    guard !Task.isCancelled, !approval.allowsAccess, activeApprovalChanges == 0,
      activeRefreshes == 0,
      refreshID == nil, task == nil
    else { return false }
    // No successful throttle load means acquisition never started; invalid
    // storage can be handed to the offline recovery path without dropping waits.
    guard throttleLoaded else { return true }
    // Failed writes may leave a new provider wait only in memory. Never treat
    // equality with the previous checkpoint as proof of a successful commit.
    if persistenceFailed { return saveThrottle() }
    return saveChangedThrottle()
  }

  func refresh() async -> DesktopUsageCandidateResult {
    await refresh(userRequestedRecheck: false)
  }

  // Only an explicit user action reaches this path. It never shortens a stored
  // provider deadline and admits at most one recheck per persisted 15-minute floor.
  func recheckConnection() async -> DesktopUsageCandidateResult {
    await refresh(userRequestedRecheck: true)
  }

  private func refresh(userRequestedRecheck: Bool) async -> DesktopUsageCandidateResult {
    guard !Task.isCancelled else { return result() }
    do { try approval.requireAccess() } catch {
      return result(error: error as? DesktopCredentialError)
    }
    guard refreshID == nil else { return result(disposition: .unchangedInFlight) }
    let id = UUID()
    let revision = approvalRevision
    refreshID = id
    activeRefreshes += 1
    // The child covers protected reads as well as HTTP. Caller cancellation must
    // reach every awaited stage, including a reader that returns a lease anyway.
    let task = Task {
      await performRefresh(revision: revision, userRequestedRecheck: userRequestedRecheck)
    }
    self.task = task
    defer {
      activeRefreshes -= 1
      if refreshID == id {
        refreshID = nil
        self.task = nil
      }
    }
    let completed = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    // Approval can change after the child completes but before this actor resumes.
    guard !Task.isCancelled, revision == approvalRevision else { return result() }
    return completed
  }

  private func performRefresh(revision: UUID, userRequestedRecheck: Bool) async
    -> DesktopUsageCandidateResult
  {
    guard !Task.isCancelled, revision == approvalRevision else { return result() }
    guard loadThrottle(), !persistenceFailed || saveThrottle() else { return result() }
    let lease: DesktopCredentialLease
    do { lease = try await reader.load(now: clock()) } catch {
      guard !Task.isCancelled, revision == approvalRevision else { return result() }
      let failure = error as? DesktopCredentialError ?? .invalidStore
      switch failure {
      case .changedDuringRead, .unavailable, .keychainLocked:
        coordinator.suspendContext(now: clock())
      default:
        _ = coordinator.begin(context: nil, now: clock())
      }
      guard saveChangedThrottle() else { return result() }
      return result(error: failure)
    }
    guard !Task.isCancelled, revision == approvalRevision else { return result() }
    guard
      let request = coordinator.begin(
        context: lease.context, now: clock(), userRequestedRecheck: userRequestedRecheck)
    else {
      let observation = coordinator.currentObservation(context: lease.context, now: clock())
      guard saveChangedThrottle() else { return result() }
      return result(observation: observation)
    }
    // Persist the attempt before HTTP. Storage failure must not become a network
    // retry, including when another refresh, wake or consent change is queued.
    guard saveThrottle() else {
      coordinator.complete(request, reply: .networkFailure, context: nil, now: clock())
      return result()
    }
    guard !Task.isCancelled else {
      coordinator.complete(request, reply: .networkFailure, context: nil, now: clock())
      return result()
    }
    let reply = await fetch(request, lease)
    coordinator.recordServiceRestriction(request, reply: reply, now: clock())
    guard saveThrottle() else {
      coordinator.complete(request, reply: reply, context: nil, now: clock())
      return result()
    }
    var context: DesktopUsageContext?
    if !Task.isCancelled, revision == approvalRevision {
      context = await reader.currentContext(for: lease, now: clock())
    }
    // Recheck after the reader suspension too. A non-cooperative fetch/reader may
    // return success after cancellation, but must never admit that observation.
    if Task.isCancelled || revision != approvalRevision { context = nil }
    // Known 429/auth refusals remain meaningful without admitting any context.
    coordinator.complete(request, reply: reply, context: context, now: clock())
    guard saveThrottle() else { return result() }
    guard !Task.isCancelled, revision == approvalRevision else { return result() }
    guard let context else { return result() }
    return result(observation: coordinator.currentObservation(context: context, now: clock()))
  }

  private func loadThrottle() -> Bool {
    guard !throttleLoaded else { return true }
    do {
      if let record = try throttleStore.load() {
        guard coordinator.restoreThrottle(record, now: clock()) else {
          persistenceFailed = true
          return false
        }
        lastSavedRecord = record
      }
      throttleLoaded = true
      persistenceFailed = false
      return true
    } catch {
      persistenceFailed = true
      return false
    }
  }

  private func saveThrottle() -> Bool {
    do {
      let record = coordinator.throttleRecord(now: clock())
      try throttleStore.save(record)
      lastSavedRecord = record
      persistenceFailed = false
      return true
    } catch {
      persistenceFailed = true
      return false
    }
  }

  private func saveChangedThrottle() -> Bool {
    guard let lastSavedRecord else { return saveThrottle() }
    var candidate = coordinator.throttleRecord(now: clock())
    // Merely reading the clock is not a durable scheduling change.
    candidate.recordedAt = lastSavedRecord.recordedAt
    guard candidate != lastSavedRecord else { return true }
    return saveThrottle()
  }

  private func result(
    disposition: DesktopUsageCandidateResult.Disposition = .replaceDisplay,
    error: DesktopCredentialError? = nil, observation: DesktopUsageObservation? = nil
  ) -> DesktopUsageCandidateResult {
    DesktopUsageCandidateResult(
      disposition: disposition,
      state: persistenceFailed ? .persistenceUnavailable : coordinator.state,
      observation: persistenceFailed ? nil : observation,
      credentialError: error,
      nextAllowedAt: coordinator.nextAllowedAt)
  }
}
