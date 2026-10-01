import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

private let serviceNow = Date(timeIntervalSince1970: 1_900_000_000)
private func serviceClock() -> Date { serviceNow }

private final class SyntheticServiceClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = serviceNow

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    instant = instant.addingTimeInterval(interval)
  }
}

private actor SyntheticDesktopReader: DesktopCredentialReading {
  var lease: DesktopCredentialLease
  var stillCurrent = true
  var error: DesktopCredentialError?
  private(set) var loads = 0
  private(set) var contextReads = 0
  private(set) var loadWasCancelled = false
  private(set) var contextReadWasCancelled = false
  private let loadGate: SyntheticFetchGate?
  private let contextGate: SyntheticFetchGate?

  init(loadGate: SyntheticFetchGate? = nil, contextGate: SyntheticFetchGate? = nil) throws {
    self.loadGate = loadGate
    self.contextGate = contextGate
    lease = try DesktopCredentialLease(
      context: DesktopUsageContext(
        owner: DesktopIdentity.owner(
          account: "11111111-1111-4111-8111-111111111111",
          organization: "22222222-2222-4222-8222-222222222222"),
        generation: UUID(), expiresAt: serviceNow.addingTimeInterval(3600), hasProfileScope: true),
      token: Data("synthetic-service-token".utf8))
  }
  func setApproval(_ approval: DesktopAccessApproval) {}
  func load(now: Date) async throws -> DesktopCredentialLease {
    loads += 1
    if let loadGate { await loadGate.pause() }
    loadWasCancelled = Task.isCancelled
    if let error { throw error }
    return lease
  }
  func currentContext(for lease: DesktopCredentialLease, now: Date) async -> DesktopUsageContext? {
    contextReads += 1
    if let contextGate { await contextGate.pause() }
    contextReadWasCancelled = Task.isCancelled
    return stillCurrent ? self.lease.context : nil
  }
  func invalidate() { stillCurrent = false }
  func fail(_ error: DesktopCredentialError) { self.error = error }
  func recover() { error = nil }
  func renew(otherOwner: Bool = false) throws {
    let owner = try DesktopIdentity.owner(
      account: otherOwner
        ? "33333333-3333-4333-8333-333333333333" : "11111111-1111-4111-8111-111111111111",
      organization: "22222222-2222-4222-8222-222222222222")
    lease = try DesktopCredentialLease(
      context: DesktopUsageContext(
        owner: owner, generation: UUID(), expiresAt: serviceNow.addingTimeInterval(7200),
        hasProfileScope: true),
      token: Data("synthetic-renewed-token".utf8))
  }
}

private actor SyntheticFetchCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private actor SyntheticFetchGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  private var started = false
  func pause() async {
    started = true
    entered?.resume()
    entered = nil
    await withCheckedContinuation { continuation = $0 }
  }
  func waitForEntry() async {
    if !started { await withCheckedContinuation { entered = $0 } }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private func successfulReply(_ request: DesktopUsageRequest, utilization: Int = 25)
  -> DesktopUsageReply
{
  let reset = ISO8601DateFormatter().string(from: request.startedAt.addingTimeInterval(604_700))
  return .response(
    status: 200, profileOwner: request.context.owner, serverDate: request.startedAt,
    cacheAge: 0, retryAfter: nil,
    body: Data("{\"seven_day\":{\"utilization\":\(utilization),\"resets_at\":\"\(reset)\"}}".utf8))
}

@Suite("Desktop candidate service")
struct DesktopUsageCandidateServiceTests {
  @Test(arguments: [DesktopCredentialError.changedDuringRead, .keychainLocked, .unavailable])
  func temporaryReadFailureQuarantinesUntilSameOwnerIsVerified(error: DesktopCredentialError)
    async throws
  {
    let reader = try SyntheticDesktopReader()
    let clock = SyntheticServiceClock()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(
      reader: reader, clock: { clock.now() },
      fetch: { request, _ in
        await counter.increment()
        return successfulReply(request)
      })
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = await service.refresh()
    #expect(first.observation != nil)
    clock.advance(by: 30)
    await reader.fail(error)
    let unavailable = await service.refresh()
    #expect(unavailable.observation == nil)
    #expect(unavailable.credentialError == error)
    await reader.recover()
    clock.advance(by: 30)
    let recovered = await service.refresh()
    #expect(recovered.observation == first.observation)
    #expect(recovered.state == .current)
    #expect(await counter.count == 1)
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(recovered, now: clock.now()))
    #expect(snapshot.weekly?.remainingPercent == 75)
    #expect(snapshot.capturedAt == serviceNow)
  }

  @Test(arguments: [429, 500, 200])
  func recoveredIdentityPreservesUnresolvedFetchFailure(status: Int) async throws {
    let reader = try SyntheticDesktopReader()
    let clock = SyntheticServiceClock()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(
      reader: reader, clock: { clock.now() },
      fetch: { request, _ in
        await counter.increment()
        if request.startedAt == serviceNow { return successfulReply(request) }
        return .response(
          status: status, profileOwner: request.context.owner, serverDate: request.startedAt,
          cacheAge: 0, retryAfter: serviceNow.addingTimeInterval(7200), body: Data())
      })
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = await service.refresh()
    clock.advance(by: 300)
    let failed = await service.refresh()
    #expect(failed.observation == first.observation)
    #expect(failed.state != .current)
    clock.advance(by: 10)
    await reader.fail(.changedDuringRead)
    #expect(await service.refresh().observation == nil)
    clock.advance(by: 10)
    #expect(await service.refresh().observation == nil)
    await reader.recover()
    clock.advance(by: 10)
    let recovered = await service.refresh()
    #expect(recovered.state == failed.state)
    #expect(recovered.observation == first.observation)
    #expect(recovered.nextAllowedAt == failed.nextAllowedAt)
    #expect(await counter.count == 2)
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(recovered, now: clock.now()))
    #expect(snapshot.errorCode != nil)
    #expect(snapshot.capturedAt == serviceNow)
  }

  @Test(arguments: [true, false])
  func quarantinedValuesCannotCrossOwnerOrFreshnessBoundary(changedOwner: Bool) async throws {
    let reader = try SyntheticDesktopReader()
    let clock = SyntheticServiceClock()
    let service = DesktopUsageCandidateService(
      reader: reader, clock: { clock.now() },
      fetch: { request, _ in
        request.startedAt == serviceNow ? successfulReply(request) : .networkFailure
      })
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    #expect(await service.refresh().observation != nil)
    clock.advance(by: 30)
    await reader.fail(.changedDuringRead)
    #expect(await service.refresh().observation == nil)
    await reader.recover()
    if changedOwner { try await reader.renew(otherOwner: true) }
    clock.advance(by: changedOwner ? 30 : 901)
    #expect(await service.refresh().observation == nil)
  }

  @Test func sameOwnerRenewalDuringFetchRejectsReplyButKeepsPriorVerifiedObservation() async throws
  {
    let reader = try SyntheticDesktopReader()
    let clock = SyntheticServiceClock()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(
      reader: reader, clock: { clock.now() },
      fetch: { request, _ in
        await counter.increment()
        if request.startedAt > serviceNow { try? await reader.renew() }
        return successfulReply(request, utilization: request.startedAt == serviceNow ? 25 : 90)
      })
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = await service.refresh()
    clock.advance(by: 300)
    let changed = await service.refresh()
    #expect(changed.state == .contextChanged)
    #expect(changed.observation == first.observation)
    #expect(changed.nextAllowedAt == clock.now().addingTimeInterval(60))
    let snapshot = try #require(DesktopPreviewPresentation.snapshot(changed, now: clock.now()))
    #expect(snapshot.weekly?.remainingPercent == 75)
    #expect(snapshot.capturedAt == serviceNow)
    #expect(await counter.count == 2)
  }

  @Test func explicitLocalExperimentDoesNotImplyProviderApproval() async throws {
    let reader = try SyntheticDesktopReader()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { request, _ in
      await counter.increment()
      return successfulReply(request)
    }
    let approval = DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true)
    #expect(!approval.providerApproved)
    await service.setApproval(approval)
    #expect(await service.refresh().state == .current)
    #expect(await counter.count == 1)
    await service.setApproval(DesktopAccessApproval(localExperimentAuthorized: true))
    #expect(await service.refresh().credentialError == .consentRequired)
    #expect(await counter.count == 1)
  }

  @Test func preCancelledCallerDoesNotReadCredentialsOrStartHTTP() async throws {
    let reader = try SyntheticDesktopReader()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { request, _ in
      await counter.increment()
      return successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await service.refresh()
    }
    let result = await pending.value
    #expect(result.observation == nil)
    #expect(result.credentialError == nil)
    #expect(await reader.loads == 0)
    #expect(await reader.contextReads == 0)
    #expect(await counter.count == 0)
  }

  @Test func callerCancellationDuringCredentialLoadNeverStartsHTTP() async throws {
    let gate = SyntheticFetchGate()
    let reader = try SyntheticDesktopReader(loadGate: gate)
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { request, _ in
      await counter.increment()
      return successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    pending.cancel()
    await gate.release()
    let result = await pending.value
    #expect(result.observation == nil)
    #expect(result.credentialError == nil)
    #expect(await reader.loads == 1)
    #expect(await reader.loadWasCancelled)
    #expect(await reader.contextReads == 0)
    #expect(await counter.count == 0)
  }

  @Test func callerCancellationReachesFetchAndRejectsItsSuccessfulReply() async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { request, _ in
      await counter.increment()
      await gate.pause()
      #expect(Task.isCancelled)
      return successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    pending.cancel()
    await gate.release()
    let result = await pending.value
    #expect(result.observation == nil)
    #expect(result.state != .current)
    #expect(await reader.contextReads == 0)
    let repeated = await service.refresh()
    #expect(repeated.observation == nil)
    #expect(await counter.count == 1)
  }

  @Test func callerCancellationDuringPostFetchIdentityReadRejectsSuccess() async throws {
    let gate = SyntheticFetchGate()
    let reader = try SyntheticDesktopReader(contextGate: gate)
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { request, _ in
      successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    pending.cancel()
    await gate.release()
    let result = await pending.value
    #expect(result.observation == nil)
    #expect(result.state != .current)
    #expect(await reader.contextReads == 1)
    #expect(await reader.contextReadWasCancelled)
  }

  @Test func callerCancelled429RetainsServiceDelayWithoutIdentityRead() async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { _, _ in
      await counter.increment()
      await gate.pause()
      #expect(Task.isCancelled)
      return .response(
        status: 429, profileOwner: nil, serverDate: serviceNow, cacheAge: nil,
        retryAfter: serviceNow.addingTimeInterval(7200), body: Data())
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    pending.cancel()
    await gate.release()
    let cancelled = await pending.value
    #expect(cancelled.observation == nil)
    #expect(cancelled.nextAllowedAt == serviceNow.addingTimeInterval(7200))
    #expect(await reader.contextReads == 0)
    let repeated = await service.refresh()
    #expect(repeated.observation == nil)
    #expect(repeated.nextAllowedAt == serviceNow.addingTimeInterval(7200))
    #expect(await counter.count == 1)
  }

  @Test(arguments: [401, 403])
  func callerCancelledAuthenticationRefusalStillBlocksTheSameLease(status: Int) async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { _, _ in
      await counter.increment()
      await gate.pause()
      #expect(Task.isCancelled)
      return .response(
        status: status, profileOwner: nil, serverDate: serviceNow, cacheAge: nil,
        retryAfter: nil, body: Data())
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    pending.cancel()
    await gate.release()
    #expect(await pending.value.observation == nil)
    #expect(await reader.contextReads == 0)
    let repeated = await service.refresh()
    #expect(repeated.observation == nil)
    #expect(repeated.state == (status == 401 ? .waitingForDesktopRenewal : .accessDenied))
    #expect(await counter.count == 1)
  }

  @Test func noFileOrNetworkBeforeBothApprovals() async throws {
    let reader = try SyntheticDesktopReader()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { _, _ in
      await counter.increment()
      return .networkFailure
    }
    #expect(await service.refresh().credentialError == .consentRequired)
    await service.setApproval(DesktopAccessApproval(userConsented: true))
    #expect(await service.refresh().credentialError == .providerApprovalRequired)
    #expect(await reader.loads == 0)
    #expect(await counter.count == 0)
  }

  @Test func verifiedResponseBecomesObservationAndAutomaticRepeatIsThrottled() async throws {
    let reader = try SyntheticDesktopReader()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) {
      request, _ in
      await counter.increment()
      return successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = await service.refresh()
    #expect(first.state == .current)
    #expect(first.observation?.values.weekly.remainingPercent == 75)
    #expect(first.nextAllowedAt == serviceNow.addingTimeInterval(300))
    let second = await service.refresh()
    #expect(second.observation == first.observation)
    #expect(await counter.count == 1)
  }

  @Test func postRequestIdentityChangeDiscardsEvenSuccessfulResponse() async throws {
    let reader = try SyntheticDesktopReader()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) {
      request, _ in
      await reader.invalidate()
      return successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let result = await service.refresh()
    #expect(result.observation == nil)
    #expect(result.state == .identityUnavailable)
  }

  @Test func credentialErrorsNeverStartHTTP() async throws {
    for error in [
      DesktopCredentialError.permissionRequired, .keychainLocked, .unsafePath, .expired,
      .ambiguousIdentity,
    ] {
      let reader = try SyntheticDesktopReader()
      await reader.fail(error)
      let counter = SyntheticFetchCounter()
      let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { _, _ in
        await counter.increment()
        return .networkFailure
      }
      await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
      let result = await service.refresh()
      #expect(result.credentialError == error)
      #expect(result.observation == nil)
      #expect(await counter.count == 0)
    }
  }

  @Test(arguments: [true, false])
  func duplicateRefreshReportsUnchangedInFlight(succeeds: Bool) async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) {
      request, _ in
      await counter.increment()
      await gate.pause()
      return succeeds ? successfulReply(request) : .networkFailure
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    let overlapping = await service.refresh()
    #expect(overlapping.disposition == .unchangedInFlight)
    #expect(overlapping.state == .requesting)
    #expect(overlapping.observation == nil)
    #expect(overlapping.credentialError == nil)
    #expect(await counter.count == 1)
    #expect(await reader.loads == 1)
    #expect(await reader.contextReads == 0)
    await gate.release()
    let completed = await pending.value
    #expect(completed.disposition == .replaceDisplay)
    #expect(completed.state == (succeeds ? .current : .temporaryFailure))
    #expect((completed.observation != nil) == succeeds)
    #expect(await counter.count == 1)
  }

  @Test(arguments: [true, false])
  func overlapPreservesPriorObservationUntilAcquisitionCompletes(succeeds: Bool) async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let counter = SyntheticFetchCounter()
    let clock = SyntheticServiceClock()
    let service = DesktopUsageCandidateService(
      reader: reader, clock: { clock.now() },
      fetch: { request, _ in
        await counter.increment()
        if request.startedAt == serviceNow { return successfulReply(request) }
        await gate.pause()
        return succeeds ? successfulReply(request, utilization: 40) : .networkFailure
      })
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let first = await service.refresh()
    #expect(first.disposition == .replaceDisplay)
    let initialObservation = try #require(first.observation)
    var displayed: DesktopUsageObservation? = initialObservation
    clock.advance(by: 300)

    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    let overlapping = await service.refresh()
    #expect(overlapping.disposition == .unchangedInFlight)
    #expect(overlapping.observation == nil)
    switch overlapping.disposition {
    case .replaceDisplay: displayed = overlapping.observation
    case .unchangedInFlight: break
    }
    #expect(displayed == initialObservation)
    #expect(await counter.count == 2)
    #expect(await reader.loads == 2)
    #expect(await reader.contextReads == 1)

    await gate.release()
    let completed = await pending.value
    #expect(completed.disposition == .replaceDisplay)
    #expect(completed.state == (succeeds ? .current : .temporaryFailure))
    switch completed.disposition {
    case .replaceDisplay: displayed = completed.observation
    case .unchangedInFlight: break
    }
    #expect(displayed?.values.weekly.remainingPercent == (succeeds ? 60 : 75))
    #expect(displayed?.capturedAt == (succeeds ? clock.now() : serviceNow))
    let cached = await service.refresh()
    #expect(cached.disposition == .replaceDisplay)
    #expect(cached.observation == displayed)
    #expect(await counter.count == 2)
  }

  @Test(arguments: [DesktopCredentialError.permissionRequired, .expired])
  func overlapDuringCredentialFailureDoesNotHideTerminalError(error: DesktopCredentialError)
    async throws
  {
    let gate = SyntheticFetchGate()
    let reader = try SyntheticDesktopReader(loadGate: gate)
    await reader.fail(error)
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { _, _ in
      await counter.increment()
      return .networkFailure
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    let overlapping = await service.refresh()
    #expect(overlapping.disposition == .unchangedInFlight)
    #expect(overlapping.observation == nil)
    #expect(overlapping.credentialError == nil)
    await gate.release()
    let completed = await pending.value
    #expect(completed.disposition == .replaceDisplay)
    #expect(completed.credentialError == error)
    #expect(completed.observation == nil)
    #expect(await reader.loads == 1)
    #expect(await counter.count == 0)
  }

  @Test func revocationCancelsFetchAndRejectsItsResult() async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) {
      request, _ in
      await gate.pause()
      #expect(Task.isCancelled)
      return successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    #expect(await service.refresh().disposition == .unchangedInFlight)
    await service.setApproval(DesktopAccessApproval())
    let denied = await service.refresh()
    #expect(denied.disposition == .replaceDisplay)
    #expect(denied.state == .permissionDenied)
    #expect(denied.credentialError == .consentRequired)
    #expect(denied.observation == nil)
    await gate.release()
    let result = await pending.value
    #expect(result.disposition == .replaceDisplay)
    #expect(result.observation == nil)
    #expect(result.state == .permissionDenied)
  }

  @Test func cancelled429StillEnforcesDelayAfterOptIn() async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) { _, _ in
      await counter.increment()
      await gate.pause()
      return .response(
        status: 429, profileOwner: nil, serverDate: serviceNow, cacheAge: nil,
        retryAfter: serviceNow.addingTimeInterval(7200), body: Data())
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    await service.setApproval(DesktopAccessApproval())
    await gate.release()
    _ = await pending.value
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let result = await service.refresh()
    #expect(result.nextAllowedAt == serviceNow.addingTimeInterval(7200))
    #expect(await counter.count == 1)
  }
}
