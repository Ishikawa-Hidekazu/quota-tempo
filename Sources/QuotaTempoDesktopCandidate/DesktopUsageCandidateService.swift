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

// Isolated candidate orchestration. No timer, persistence, UI, or shipped caller.
actor DesktopUsageCandidateService {
  typealias Fetch =
    @Sendable (DesktopUsageRequest, DesktopCredentialLease) async -> DesktopUsageReply
  private let reader: any DesktopCredentialReading
  private let fetch: Fetch
  private let clock: @Sendable () -> Date
  private var approval = DesktopAccessApproval()
  private var approvalRevision = UUID()
  private var coordinator = DesktopUsageCoordinator()
  private var refreshID: UUID?
  private var task: Task<DesktopUsageCandidateResult, Never>?

  init(
    reader: any DesktopCredentialReading = DesktopCredentialReader(),
    clock: @escaping @Sendable () -> Date = Date.init,
    fetch: @escaping Fetch = { request, lease in
      await DesktopUsageHTTPTransport().fetch(request: request, lease: lease)
    }
  ) {
    self.reader = reader
    self.clock = clock
    self.fetch = fetch
  }

  func setApproval(_ approval: DesktopAccessApproval) async {
    self.approval = approval
    approvalRevision = UUID()
    task?.cancel()
    task = nil
    refreshID = nil
    coordinator.setPermission(approval.allowsAccess ? .allowed : .denied)
    await reader.setApproval(approval)
  }

  func refresh() async -> DesktopUsageCandidateResult {
    guard !Task.isCancelled else { return result() }
    do { try approval.requireAccess() } catch {
      return result(error: error as? DesktopCredentialError)
    }
    guard refreshID == nil else { return result(disposition: .unchangedInFlight) }
    let id = UUID()
    let revision = approvalRevision
    refreshID = id
    // The child covers protected reads as well as HTTP. Caller cancellation must
    // reach every awaited stage, including a reader that returns a lease anyway.
    let task = Task { await performRefresh(revision: revision) }
    self.task = task
    defer {
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

  private func performRefresh(revision: UUID) async -> DesktopUsageCandidateResult {
    guard !Task.isCancelled, revision == approvalRevision else { return result() }
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
      return result(error: failure)
    }
    guard !Task.isCancelled, revision == approvalRevision else { return result() }
    guard let request = coordinator.begin(context: lease.context, now: clock()) else {
      return result(
        observation: coordinator.currentObservation(context: lease.context, now: clock()))
    }
    guard !Task.isCancelled else {
      coordinator.complete(request, reply: .networkFailure, context: nil, now: clock())
      return result()
    }
    let reply = await fetch(request, lease)
    var context: DesktopUsageContext?
    if !Task.isCancelled, revision == approvalRevision {
      context = await reader.currentContext(for: lease, now: clock())
    }
    // Recheck after the reader suspension too. A non-cooperative fetch/reader may
    // return success after cancellation, but must never admit that observation.
    if Task.isCancelled || revision != approvalRevision { context = nil }
    // Known 429/auth refusals remain meaningful without admitting any context.
    coordinator.complete(request, reply: reply, context: context, now: clock())
    guard !Task.isCancelled, revision == approvalRevision else { return result() }
    guard let context else { return result() }
    return result(observation: coordinator.currentObservation(context: context, now: clock()))
  }

  private func result(
    disposition: DesktopUsageCandidateResult.Disposition = .replaceDisplay,
    error: DesktopCredentialError? = nil, observation: DesktopUsageObservation? = nil
  ) -> DesktopUsageCandidateResult {
    DesktopUsageCandidateResult(
      disposition: disposition, state: coordinator.state, observation: observation,
      credentialError: error,
      nextAllowedAt: coordinator.nextAllowedAt)
  }
}
