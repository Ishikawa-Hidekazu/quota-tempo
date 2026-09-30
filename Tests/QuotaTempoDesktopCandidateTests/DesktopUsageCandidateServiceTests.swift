import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

private let serviceNow = Date(timeIntervalSince1970: 1_900_000_000)
private func serviceClock() -> Date { serviceNow }

private actor SyntheticDesktopReader: DesktopCredentialReading {
  let lease: DesktopCredentialLease
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

private func successfulReply(_ request: DesktopUsageRequest) -> DesktopUsageReply {
  let reset = ISO8601DateFormatter().string(from: serviceNow.addingTimeInterval(604_700))
  return .response(
    status: 200, profileOwner: request.context.owner, serverDate: serviceNow,
    cacheAge: 0, retryAfter: nil,
    body: Data("{\"seven_day\":{\"utilization\":25,\"resets_at\":\"\(reset)\"}}".utf8))
}

@Suite("Desktop candidate service")
struct DesktopUsageCandidateServiceTests {
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
      DesktopCredentialError.permissionRequired, .unsafePath, .expired, .ambiguousIdentity,
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

  @Test func duplicateRefreshDoesNotCreateAnotherRequest() async throws {
    let reader = try SyntheticDesktopReader()
    let gate = SyntheticFetchGate()
    let counter = SyntheticFetchCounter()
    let service = DesktopUsageCandidateService(reader: reader, clock: serviceClock) {
      request, _ in
      await counter.increment()
      await gate.pause()
      return successfulReply(request)
    }
    await service.setApproval(DesktopAccessApproval(userConsented: true, providerApproved: true))
    let pending = Task { await service.refresh() }
    await gate.waitForEntry()
    let overlapping = await service.refresh()
    #expect(overlapping.observation == nil)
    #expect(await counter.count == 1)
    await gate.release()
    #expect(await pending.value.state == .current)
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
    await service.setApproval(DesktopAccessApproval())
    await gate.release()
    let result = await pending.value
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
