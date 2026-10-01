import Foundation

struct DesktopUsageHTTPTransport: Sendable {
  enum Diagnostic: String, Sendable {
    case profileReceived, profileMetadataInvalid, profilePayloadInvalid, profileIdentityInvalid
    case profileIdentityMismatch, usageReceived, usagePayloadInvalid
    case usageDateMissing, usageDateMalformed, usageAgePositive, usageAgeInvalid
    case usageDateTooOld, usageDateFuture, usageClockInvalid
    case usagePayloadTooLarge, usagePayloadMalformed, usageWeeklyUnavailable, usageWindowInvalid
    case usageResetInvalid, usageAccepted, exchangeFailed
  }

  private let testProtocol: URLProtocol.Type?
  private let now: @Sendable () -> Date
  private let diagnostic: @Sendable (Diagnostic) -> Void

  init(diagnostic: @escaping @Sendable (Diagnostic) -> Void = { _ in }) {
    testProtocol = nil
    now = Date.init
    self.diagnostic = diagnostic
  }

  // This changes only the in-memory protocol implementation, never either URL.
  init(
    testProtocol: URLProtocol.Type, now: @escaping @Sendable () -> Date = Date.init,
    diagnostic: @escaping @Sendable (Diagnostic) -> Void = { _ in }
  ) {
    self.testProtocol = testProtocol
    self.now = now
    self.diagnostic = diagnostic
  }

  func fetch(request: DesktopUsageRequest, lease: DesktopCredentialLease) async -> DesktopUsageReply
  {
    let started = now()
    guard request.context == lease.context, request.context.owner.isValid,
      request.context.hasProfileScope, validDate(started), validDate(request.startedAt),
      validDate(request.deadline), validDate(request.context.expiresAt),
      request.startedAt <= started, request.context.expiresAt > started
    else { return Self.invalidResponse }
    let remaining = min(
      request.deadline.timeIntervalSince(started),
      request.startedAt.addingTimeInterval(DesktopUsageCoordinator.requestTimeout)
        .timeIntervalSince(started),
      request.context.expiresAt.timeIntervalSince(started))
    guard remaining > 0 else { return .timeout }
    let deadline = ContinuousClock.now.advanced(by: .seconds(remaining))

    // Both calls use this immutable lease. The caller must independently reread
    // its current Desktop context before submitting the result to the coordinator.
    let profileResult = await send(
      .profile, lease: lease, request: request, deadline: deadline)
    guard case .received(let profile) = profileResult else {
      diagnostic(.exchangeFailed)
      return profileResult.failureReply
    }
    diagnostic(.profileReceived)
    guard profile.status == 200 else { return profile.reply(owner: nil) }
    guard profile.freshnessFailure(since: request.startedAt) == nil else {
      diagnostic(.profileMetadataInvalid)
      return Self.invalidResponse
    }
    guard String(data: profile.body, encoding: .utf8) != nil,
      let decoded = try? JSONDecoder().decode(Profile.self, from: profile.body)
    else {
      diagnostic(.profilePayloadInvalid)
      return Self.invalidResponse
    }
    guard
      let owner = try? DesktopIdentity.owner(
        account: decoded.account.uuid, organization: decoded.organization.uuid)
    else {
      diagnostic(.profileIdentityInvalid)
      return Self.invalidResponse
    }
    guard owner == request.context.owner else {
      diagnostic(.profileIdentityMismatch)
      return .response(
        status: 200, profileOwner: owner, serverDate: profile.serverDate,
        cacheAge: profile.cacheAge, retryAfter: nil, body: Data())
    }

    let usageResult = await send(
      .usage, lease: lease, request: request, deadline: deadline)
    guard case .received(let usage) = usageResult else {
      diagnostic(.exchangeFailed)
      return usageResult.failureReply
    }
    diagnostic(.usageReceived)
    guard usage.status == 200 else { return usage.reply(owner: owner) }
    guard !Task.isCancelled else { return .networkFailure }
    let completedAt = now()
    guard validDate(completedAt), completedAt >= request.startedAt,
      completedAt >= usage.receivedAt
    else {
      diagnostic(.usageClockInvalid)
      return Self.invalidResponse
    }
    guard completedAt < request.deadline, ContinuousClock.now < deadline,
      completedAt < request.context.expiresAt
    else { return .timeout }
    if let failure = usage.freshnessFailure(since: request.startedAt) {
      diagnostic(failure.usageDiagnostic)
      return Self.invalidResponse
    }
    guard let serverDate = usage.serverDate else { return Self.invalidResponse }
    // Preserve the raw Date for coordinator validation, but never validate windows
    // against a future capture time inside the accepted clock-skew allowance.
    let capturedAt = min(serverDate, completedAt)
    let values: DesktopUsageValues
    do {
      values = try DesktopUsagePayloadDecoder.decode(usage.body, observedAt: capturedAt)
    } catch let error as DesktopUsagePayloadError {
      switch error {
      case .inputTooLarge: diagnostic(.usagePayloadTooLarge)
      case .invalidPayload: diagnostic(.usagePayloadMalformed)
      case .unavailableWeekly: diagnostic(.usageWeeklyUnavailable)
      case .invalidWindow: diagnostic(.usageWindowInvalid)
      }
      return Self.invalidResponse
    } catch {
      diagnostic(.usagePayloadInvalid)
      return Self.invalidResponse
    }
    guard let reset = values.weekly.resetAt, reset > completedAt else {
      diagnostic(.usageResetInvalid)
      return Self.invalidResponse
    }
    diagnostic(.usageAccepted)
    return usage.reply(owner: owner)
  }

  private func send(
    _ endpoint: Endpoint, lease: DesktopCredentialLease,
    request: DesktopUsageRequest, deadline: ContinuousClock.Instant
  ) async -> ExchangeResult {
    guard !Task.isCancelled else { return .networkFailure }
    let current = now()
    guard validDate(current), current >= request.startedAt,
      current < request.context.expiresAt
    else { return .invalid }
    let duration = ContinuousClock.now.duration(to: deadline)
    let remaining = min(duration.seconds, request.deadline.timeIntervalSince(current))
    guard remaining > 0 else { return .timeout }
    var httpRequest = URLRequest(
      url: endpoint.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: remaining)
    httpRequest.httpMethod = "GET"
    httpRequest.httpShouldHandleCookies = false
    httpRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    httpRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    httpRequest.setValue("QuotaTempo-DesktopCandidate/0.1", forHTTPHeaderField: "User-Agent")
    httpRequest.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
    httpRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
    httpRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    lease.authorize(&httpRequest)
    guard httpRequest.url == endpoint.url, httpRequest.httpMethod == "GET",
      httpRequest.httpBody == nil, httpRequest.httpBodyStream == nil,
      httpRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
    else { return .invalid }
    let exchange = Exchange(endpoint: endpoint, testProtocol: testProtocol, now: now)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        exchange.start(
          httpRequest, timeout: remaining, deadline: deadline, continuation: continuation)
      }
    } onCancel: {
      exchange.cancel()
    }
  }

  private static var invalidResponse: DesktopUsageReply {
    .response(
      status: 0, profileOwner: nil, serverDate: nil, cacheAge: nil,
      retryAfter: nil, body: Data())
  }

  private func validDate(_ date: Date) -> Bool {
    date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0
  }

  private struct Profile: Decodable {
    struct Identity: Decodable { let uuid: String }
    let account: Identity
    let organization: Identity
  }

  private enum Endpoint: Sendable {
    case profile, usage

    var url: URL {
      switch self {
      case .profile: URL(string: "https://api.anthropic.com/api/oauth/profile")!
      case .usage: URL(string: "https://api.anthropic.com/api/oauth/usage")!
      }
    }

    var maximumBytes: Int { 16 * 1024 }
  }

  private enum ExchangeResult: Sendable {
    case received(Response)
    case invalid, networkFailure, timeout

    var failureReply: DesktopUsageReply {
      switch self {
      case .timeout: .timeout
      case .networkFailure: .networkFailure
      case .invalid, .received: DesktopUsageHTTPTransport.invalidResponse
      }
    }
  }

  private enum FreshnessFailure: Sendable {
    case dateMissing, dateMalformed, agePositive, ageInvalid, dateTooOld, dateFuture, invalidClock

    var usageDiagnostic: Diagnostic {
      switch self {
      case .dateMissing: .usageDateMissing
      case .dateMalformed: .usageDateMalformed
      case .agePositive: .usageAgePositive
      case .ageInvalid: .usageAgeInvalid
      case .dateTooOld: .usageDateTooOld
      case .dateFuture: .usageDateFuture
      case .invalidClock: .usageClockInvalid
      }
    }
  }

  private struct Response: Sendable {
    private static let clockSkew: TimeInterval = 5

    let status: Int
    let serverDate: Date?
    let cacheAge: TimeInterval?
    let metadataFailure: FreshnessFailure?
    let retryAfter: HTTPDate.RetryAfter
    var receivedAt: Date
    var body = Data()

    init(_ response: HTTPURLResponse, receivedAt: Date) {
      status = response.statusCode
      self.receivedAt = receivedAt
      let rawDate = response.value(forHTTPHeaderField: "Date")
      serverDate = HTTPDate.parse(rawDate)
      let rawAge = response.value(forHTTPHeaderField: "Age")
      cacheAge = HTTPDate.deltaSeconds(rawAge)
      if rawDate == nil {
        metadataFailure = .dateMissing
      } else if serverDate == nil {
        metadataFailure = .dateMalformed
      } else if rawAge != nil && cacheAge == nil {
        metadataFailure = .ageInvalid
      } else if let cacheAge, cacheAge > 0 {
        metadataFailure = .agePositive
      } else {
        metadataFailure = nil
      }
      retryAfter = HTTPDate.retryAfter(
        response.value(forHTTPHeaderField: "Retry-After"),
        receivedAt: receivedAt, serverDate: serverDate)
    }

    func freshnessFailure(since startedAt: Date) -> FreshnessFailure? {
      if let metadataFailure { return metadataFailure }
      guard let serverDate else { return .dateMalformed }
      guard receivedAt.timeIntervalSince1970.isFinite, receivedAt >= startedAt else {
        return .invalidClock
      }
      guard serverDate >= startedAt.addingTimeInterval(-Self.clockSkew),
        receivedAt.timeIntervalSince(serverDate)
          <= DesktopUsageCoordinator.requestTimeout + Self.clockSkew
      else { return .dateTooOld }
      guard serverDate <= receivedAt.addingTimeInterval(Self.clockSkew) else {
        return .dateFuture
      }
      return nil
    }

    func reply(owner: DesktopUsageOwner?) -> DesktopUsageReply {
      if status == 429, case .unsupported = retryAfter { return .unsupportedRateLimit }
      return .response(
        status: status, profileOwner: owner, serverDate: serverDate,
        cacheAge: cacheAge, retryAfter: retryAfter.date, body: status == 200 ? body : Data())
    }
  }

  private enum HTTPDate {
    enum RetryAfter: Sendable {
      case absentOrMalformed, unsupported
      case deadline(Date)
      var date: Date? {
        if case .deadline(let date) = self { return date }
        return nil
      }
    }
    static func parse(_ value: String?) -> Date? {
      guard let value, value.utf8.count == 29 else { return nil }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
      formatter.isLenient = false
      guard let date = formatter.date(from: value),
        date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0,
        formatter.string(from: date) == value
      else { return nil }
      return date
    }

    static func deltaSeconds(_ value: String?) -> TimeInterval? {
      guard let value, !value.isEmpty, value.utf8.count <= 15,
        value.utf8.allSatisfy({ (48...57).contains($0) }),
        let result = TimeInterval(value), result.isFinite
      else { return nil }
      return result
    }

    static func retryAfter(_ value: String?, receivedAt: Date, serverDate: Date?) -> RetryAfter {
      guard let value, !value.isEmpty else { return .absentOrMalformed }
      guard receivedAt.timeIntervalSince1970.isFinite else { return .unsupported }
      let deadline: Date
      if value.utf8.allSatisfy({ (48...57).contains($0) }) {
        // Do not let an overflowing integer look like an absent header. Long
        // legitimate waits are preserved; unsupported waits disable auto-retry.
        guard let seconds = TimeInterval(value), seconds.isFinite,
          seconds <= DesktopUsageCoordinator.maximumSupportedServiceWait
        else { return .unsupported }
        deadline = max(receivedAt, serverDate ?? receivedAt).addingTimeInterval(seconds)
      } else {
        guard let absolute = parse(value) else { return .absentOrMalformed }
        let delay = max(0, absolute.timeIntervalSince(serverDate ?? receivedAt))
        deadline = max(absolute, receivedAt.addingTimeInterval(delay))
      }
      guard deadline.timeIntervalSince1970.isFinite,
        deadline.timeIntervalSince(receivedAt)
          <= DesktopUsageCoordinator.maximumSupportedServiceWait
      else { return .unsupported }
      return .deadline(deadline)
    }
  }

  // URLSession delivers chunks; only bounded successful bodies are retained.
  // The lock also covers cancellation before start and callbacks after completion.
  private final class Exchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let endpoint: Endpoint
    private let testProtocol: URLProtocol.Type?
    private let now: @Sendable () -> Date
    private var continuation: CheckedContinuation<ExchangeResult, Never>?
    private var terminal: ExchangeResult?
    private var response: Response?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: Task<Void, Never>?

    init(
      endpoint: Endpoint, testProtocol: URLProtocol.Type?, now: @escaping @Sendable () -> Date
    ) {
      self.endpoint = endpoint
      self.testProtocol = testProtocol
      self.now = now
    }

    func start(
      _ request: URLRequest, timeout: TimeInterval, deadline: ContinuousClock.Instant,
      continuation: CheckedContinuation<ExchangeResult, Never>
    ) {
      lock.lock()
      if let terminal {
        lock.unlock()
        continuation.resume(returning: terminal)
        return
      }
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.urlCredentialStorage = nil
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      configuration.timeoutIntervalForRequest = timeout
      configuration.timeoutIntervalForResource = timeout
      configuration.waitsForConnectivity = false
      configuration.httpMaximumConnectionsPerHost = 1
      configuration.httpAdditionalHeaders = nil
      if let testProtocol { configuration.protocolClasses = [testProtocol] }
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
      let task = session.dataTask(with: request)
      self.session = session
      self.task = task
      timer = Task { [weak self] in
        do {
          try await Task.sleep(until: deadline, clock: .continuous)
          self?.finish(.timeout)
        } catch {}
      }
      lock.unlock()
      if ContinuousClock.now < deadline {
        task.resume()
      } else {
        finish(.timeout)
      }
    }

    func cancel() { finish(.networkFailure) }

    private func finish(_ result: ExchangeResult) {
      lock.lock()
      guard terminal == nil else {
        lock.unlock()
        return
      }
      terminal = result
      let continuation = continuation
      let task = task
      let session = session
      let timer = timer
      self.continuation = nil
      self.task = nil
      self.session = nil
      self.timer = nil
      response = nil
      lock.unlock()
      timer?.cancel()
      task?.cancel()
      session?.invalidateAndCancel()
      continuation?.resume(returning: result)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      guard let http = response as? HTTPURLResponse, http.url == endpoint.url else {
        completionHandler(.cancel)
        finish(.invalid)
        return
      }
      let received = Response(http, receivedAt: now())
      guard http.statusCode == 200 else {
        // Never collect service error bodies, including identity and auth failures.
        completionHandler(.cancel)
        finish(.received(received))
        return
      }
      guard http.mimeType?.lowercased() == "application/json",
        http.expectedContentLength <= endpoint.maximumBytes
      else {
        completionHandler(.cancel)
        finish(.invalid)
        return
      }
      lock.lock()
      let active = terminal == nil && self.response == nil
      if active { self.response = received }
      lock.unlock()
      completionHandler(active ? .allow : .cancel)
      if !active { finish(.invalid) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      lock.lock()
      guard terminal == nil else {
        lock.unlock()
        return
      }
      guard var response, data.count <= endpoint.maximumBytes - response.body.count else {
        lock.unlock()
        finish(.invalid)
        return
      }
      response.body.append(data)
      self.response = response
      lock.unlock()
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      if let error {
        finish((error as? URLError)?.code == .timedOut ? .timeout : .networkFailure)
        return
      }
      lock.lock()
      var response = response
      response?.receivedAt = now()
      lock.unlock()
      finish(response.map(ExchangeResult.received) ?? .invalid)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
      finish(.invalid)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask,
      willCacheResponse proposedResponse: CachedURLResponse,
      completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (
          URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
      Self.answer(challenge, completionHandler: completionHandler)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (
          URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
      Self.answer(challenge, completionHandler: completionHandler)
    }

    private static func answer(
      _ challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (
          URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
      // Keep the platform TLS trust evaluation; never offer saved HTTP credentials.
      if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
        completionHandler(.performDefaultHandling, nil)
      } else {
        completionHandler(.cancelAuthenticationChallenge, nil)
      }
    }
  }
}

extension Duration {
  fileprivate var seconds: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
