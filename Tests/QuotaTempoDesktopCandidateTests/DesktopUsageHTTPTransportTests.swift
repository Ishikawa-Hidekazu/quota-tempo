import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

@Suite(.serialized)
struct DesktopUsageHTTPTransportTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let account = "11111111-1111-4111-8111-111111111111"
  private let organization = "22222222-2222-4222-8222-222222222222"
  private let other = "33333333-3333-4333-8333-333333333333"

  @Test(
    "Transport diagnostics expose fixed stages, not response values",
    arguments: ["success", "profile", "metadata", "usage", "foreign", "network"])
  func boundedDiagnostics(_ scenario: String) async throws {
    let fixture = try fixture()
    let recorder = DiagnosticRecorder()
    let transport = DesktopUsageHTTPTransport(
      testProtocol: StubProtocol.self, now: { now }, diagnostic: { recorder.append($0) })
    let expected: [DesktopUsageHTTPTransport.Diagnostic]
    switch scenario {
    case "profile":
      StubProtocol.state.install([response(body: Data("private-synthetic-body".utf8))])
      expected = [.profileReceived, .profilePayloadInvalid]
    case "metadata":
      StubProtocol.state.install([response(body: profileBody(), headers: ["Age": "60"])])
      expected = [.profileReceived, .profileMetadataInvalid]
    case "usage":
      StubProtocol.state.install([profile(), response(body: Data("private-synthetic-body".utf8))])
      expected = [.profileReceived, .usageReceived, .usagePayloadMalformed]
    case "foreign":
      StubProtocol.state.install([profile(account: other)])
      expected = [.profileReceived, .profileIdentityMismatch]
    case "network":
      StubProtocol.state.install([.failure(.notConnectedToInternet)])
      expected = [.exchangeFailed]
    default:
      StubProtocol.state.install([profile(), response(body: usageBody())])
      expected = [.profileReceived, .usageReceived, .usageAccepted]
    }
    _ = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(recorder.events == expected)
    let output = recorder.events.map(\.rawValue).joined()
    #expect(!output.contains(account))
    #expect(!output.contains("private-synthetic"))
  }

  @Test("Profile and usage use the same synthetic lease and only the fixed GET endpoints")
  func successfulAcquisition() async throws {
    let fixture = try fixture()
    let body = usageBody()
    StubProtocol.state.install([profile(), response(body: body)])
    let result = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(let status, let owner, let date, let age, _, let received) = result else {
      Issue.record("Expected a validated quota response")
      return
    }
    #expect(status == 200)
    #expect(owner == fixture.request.context.owner)
    #expect(date == now)
    #expect(age == nil)
    #expect(received == body)
    let requests = StubProtocol.state.requests
    #expect(requests.map(\.path) == ["/api/oauth/profile", "/api/oauth/usage"])
    #expect(requests.allSatisfy { $0.fixedOrigin && $0.method == "GET" && !$0.hasBody })
    #expect(requests.allSatisfy { $0.expectedAuthorization })
    #expect(requests.allSatisfy { !$0.handlesCookies && !$0.hasCookie })
    #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData })
    #expect(requests.allSatisfy { $0.accept == "application/json" })
    #expect(requests.allSatisfy { $0.beta == "oauth-2025-04-20" })
    #expect(requests.allSatisfy { $0.userAgent == "QuotaTempo-DesktopCandidate/0.1" })
    #expect(
      requests.allSatisfy { $0.cacheControl == "no-store, no-cache" && $0.pragma == "no-cache" })
    #expect(requests.allSatisfy { $0.timeout > 0 && $0.timeout <= 30 })
    var coordinator = DesktopUsageCoordinator()
    coordinator.setPermission(.allowed)
    let admission = coordinator.begin(context: fixture.request.context, now: now)
    let request = try #require(admission)
    coordinator.complete(request, reply: result, context: fixture.request.context, now: now)
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.values.weekly.remainingPercent == 90)
  }

  @Test("Profile UUID matching is canonical and does not depend on letter casing")
  func canonicalProfileIdentity() async throws {
    let account = "abcdefab-abcd-4abc-8abc-abcdefabcdef"
    let organization = "fedcbafe-dcba-4fed-8fed-fedcbafedcba"
    let fixture = try fixture(account: account, organization: organization)
    StubProtocol.state.install([
      profile(account: account.uppercased(), organization: organization.uppercased()),
      response(body: usageBody()),
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == 200)
    #expect(StubProtocol.state.requests.count == 2)
  }

  @Test(
    "A different server account or organization prevents the usage request",
    arguments: [false, true])
  func rejectsForeignProfile(organizationOnly: Bool) async throws {
    let fixture = try fixture()
    StubProtocol.state.install([
      profile(
        account: organizationOnly ? account : other,
        organization: organizationOnly ? other : organization)
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(200, let owner, _, _, _, let body) = reply else {
      Issue.record("Expected an identity mismatch response")
      return
    }
    #expect(owner != fixture.request.context.owner)
    #expect(body.isEmpty)
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test(
    "Missing or malformed profile identity never reaches usage",
    arguments: [
      "{}", "[]", "null", "not-json", "{\"account\":{\"uuid\":\"bad\"},\"organization\":null}",
      "{\"account\":null,\"organization\":{}}",
    ])
  func malformedProfile(body: String) async throws {
    let fixture = try fixture()
    StubProtocol.state.install([response(body: Data(body.utf8))])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == 0)
    #expect(try responseBody(reply).isEmpty)
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test("Invalid UTF-8 profile responses are rejected")
  func invalidProfileEncoding() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([response(body: Data([0xFF, 0xFE]))])
    #expect(try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 0)
  }

  @Test("The exact lease context is required before any network work")
  func changedLeaseContext() async throws {
    let fixture = try fixture()
    let otherFixture = try self.fixture()
    StubProtocol.state.install([])
    let reply = await transport.fetch(request: fixture.request, lease: otherFixture.lease)
    #expect(try status(reply) == 0)
    #expect(StubProtocol.state.requests.isEmpty)
  }

  @Test("Expired and missing-scope contexts make no requests", arguments: [false, true])
  func ineligibleLease(expired: Bool) async throws {
    let fixture = try fixture(expiresAt: expired ? now : nil, hasScope: expired)
    StubProtocol.state.install([])
    #expect(try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 0)
    #expect(StubProtocol.state.requests.isEmpty)
  }

  @Test("Elapsed deadlines make no requests")
  func elapsedDeadline() async throws {
    let fixture = try fixture(deadline: now)
    StubProtocol.state.install([])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .timeout = reply else {
      Issue.record("An elapsed deadline must be a timeout")
      return
    }
    #expect(StubProtocol.state.requests.isEmpty)
  }

  @Test(
    "Non-200 profile statuses stop before usage and discard service bodies",
    arguments: [401, 403, 429, 500, 302, 204])
  func profileHTTPFailure(code: Int) async throws {
    let fixture = try fixture()
    StubProtocol.state.install([response(status: code, body: Data("private-server-error".utf8))])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == code)
    #expect(try responseBody(reply).isEmpty)
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test(
    "Non-200 usage statuses are preserved without their bodies", arguments: [401, 403, 429, 503])
  func usageHTTPFailure(code: Int) async throws {
    let fixture = try fixture()
    StubProtocol.state.install([
      profile(), response(status: code, body: Data("private-server-error".utf8)),
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == code)
    #expect(try responseBody(reply).isEmpty)
    #expect(StubProtocol.state.requests.count == 2)
  }

  @Test("429 Retry-After delta is measured conservatively at receipt", arguments: [false, true])
  func rateLimitDelta(onUsage: Bool) async throws {
    let fixture = try fixture()
    let limited = response(status: 429, headers: ["Retry-After": "120"])
    StubProtocol.state.install(onUsage ? [profile(), limited] : [limited])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(429, _, _, _, let retry, let body) = reply else {
      Issue.record("Expected rate limit response")
      return
    }
    #expect(retry == now.addingTimeInterval(120))
    #expect(body.isEmpty)
  }

  @Test(
    "Retry-After HTTP date cannot be shortened by server clock skew", arguments: [-120.0, 120.0])
  func rateLimitDate(clockSkew: Double) async throws {
    let fixture = try fixture()
    let server = now.addingTimeInterval(clockSkew)
    let absolute = server.addingTimeInterval(90)
    StubProtocol.state.install([
      response(status: 429, headers: ["Date": httpDate(server), "Retry-After": httpDate(absolute)])
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(429, _, _, _, let retry, _) = reply else {
      Issue.record("Expected rate limit response")
      return
    }
    #expect(retry == max(absolute, now.addingTimeInterval(90)))
  }

  @Test("Delta Retry-After also honors a server clock ahead of the local clock")
  func rateLimitDeltaWithSkew() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([
      response(
        status: 429, headers: ["Date": httpDate(now.addingTimeInterval(60)), "Retry-After": "120"])
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(429, _, _, _, let retry, _) = reply else {
      Issue.record("Expected rate limit response")
      return
    }
    #expect(retry == now.addingTimeInterval(180))
  }

  @Test(
    "Long parsed Retry-After deadlines must not silently become shorter retries",
    arguments: [false, true], ["86400", "604800", "31536000", "999999999999999"])
  func longRetryAfterIsNotCapped(onUsage: Bool, value: String) async throws {
    let fixture = try fixture()
    let limited = response(
      status: 429, body: Data("private-synthetic-error".utf8), headers: ["Retry-After": value])
    StubProtocol.state.install(onUsage ? [profile(), limited] : [limited])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(429, _, _, _, let retry, let body) = reply else {
      Issue.record("Expected an unshortened rate limit response")
      return
    }
    let seconds = try #require(TimeInterval(value))
    #expect(retry == now.addingTimeInterval(seconds))
    #expect(body.isEmpty)
    #expect(StubProtocol.state.requests.count == (onUsage ? 2 : 1))
  }

  @Test("Long absolute Retry-After deadlines are preserved", arguments: [false, true])
  func longAbsoluteRetryAfterIsNotCapped(onUsage: Bool) async throws {
    let fixture = try fixture()
    let expected = now.addingTimeInterval(365 * 86400)
    let limited = response(status: 429, headers: ["Retry-After": httpDate(expected)])
    StubProtocol.state.install(onUsage ? [profile(), limited] : [limited])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(429, _, _, _, let retry, let body) = reply else {
      Issue.record("Expected an unshortened absolute rate limit response")
      return
    }
    #expect(retry == expected)
    #expect(body.isEmpty)
  }

  @Test(
    "Malformed Retry-After preserves 429 for coordinator fallback",
    arguments: ["-1", "1.5", "NaN", "nonsense", "99999999999999999999"])
  func invalidRetryAfter(value: String) async throws {
    let fixture = try fixture()
    StubProtocol.state.install([response(status: 429, headers: ["Retry-After": value])])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(429, _, _, _, let retry, _) = reply else {
      Issue.record("Expected rate limit response")
      return
    }
    #expect(retry == nil)
  }

  @Test("A 429 without Date still honors a valid delay")
  func rateLimitMissingDate() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([
      response(status: 429, headers: ["Date": "invalid", "Retry-After": "60"])
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .response(429, _, let date, _, let retry, _) = reply else {
      Issue.record("Expected rate limit response")
      return
    }
    #expect(date == nil)
    #expect(retry == now.addingTimeInterval(60))
  }

  @Test(
    "Freshness metadata rejects cached, future, stale and malformed responses",
    arguments: [false, true])
  func invalidFreshness(onUsage: Bool) async throws {
    let fixture = try fixture()
    let headers: [[String: String]] = [
      ["Date": "invalid"],
      ["Date": httpDate(now.addingTimeInterval(6))],
      ["Date": httpDate(now.addingTimeInterval(-6))],
      ["Age": "1"], ["Age": "-1"], ["Age": "NaN"], ["Age": "0.0"], ["Age": ""],
    ]
    for header in headers {
      let invalid = response(body: onUsage ? usageBody() : profileBody(), headers: header)
      StubProtocol.state.install(onUsage ? [profile(), invalid] : [invalid])
      let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
      #expect(try status(reply) == 0)
      #expect(try responseBody(reply).isEmpty)
      #expect(StubProtocol.state.requests.count == (onUsage ? 2 : 1))
    }
  }

  @Test(
    "Both endpoints accept exactly five seconds of skew in either direction",
    arguments: [false, true], [-6.0, -5.0, -1.0, 0.0, 1.0, 5.0, 6.0])
  func symmetricFreshness(onUsage: Bool, skew: TimeInterval) async throws {
    let fixture = try fixture()
    let date = now.addingTimeInterval(skew)
    let shifted = response(
      body: onUsage ? usageBody() : profileBody(), headers: ["Date": httpDate(date)])
    StubProtocol.state.install(
      onUsage ? [profile(), shifted] : [shifted, response(body: usageBody())])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    let accepted = abs(skew) <= 5
    #expect(try status(reply) == (accepted ? 200 : 0))
    #expect(StubProtocol.state.requests.count == (accepted || onUsage ? 2 : 1))
    if accepted {
      guard case .response(200, _, let rawDate, _, _, _) = reply else {
        Issue.record("Expected accepted raw server Date")
        return
      }
      #expect(rawDate == (onUsage ? date : now))
    } else {
      #expect(try responseBody(reply).isEmpty)
    }
  }

  @Test(
    "Accepted future Date uses nonfuture capture for payload validation",
    arguments: [1.0, 5.0])
  func futureDateDoesNotAdvanceCapture(skew: TimeInterval) async throws {
    let fixture = try fixture()
    var coordinator = DesktopUsageCoordinator()
    coordinator.setPermission(.allowed)
    let started = coordinator.begin(context: fixture.request.context, now: now)
    let request = try #require(started)
    let date = now.addingTimeInterval(skew)
    let body = usageBody(resetAt: now.addingTimeInterval(1))
    StubProtocol.state.install([
      profile(), response(body: body, headers: ["Date": httpDate(date)]),
    ])
    let reply = await transport.fetch(request: request, lease: fixture.lease)
    guard case .response(200, _, let rawDate, _, _, let received) = reply else {
      Issue.record("Clock skew must not make an unelapsed reset appear elapsed")
      return
    }
    #expect(rawDate == date)
    #expect(received == body)
    coordinator.complete(request, reply: reply, context: request.context, now: now)
    #expect(coordinator.state == .current)
    #expect(coordinator.observation?.capturedAt == now)
    #expect(coordinator.currentObservation(context: request.context, now: now)?.capturedAt == now)
  }

  @Test("Normalizing capture does not revive an elapsed reset", arguments: [-1.0, 0.0])
  func futureDateStillRejectsElapsedReset(resetOffset: TimeInterval) async throws {
    let fixture = try fixture()
    StubProtocol.state.install([
      profile(),
      response(
        body: usageBody(resetAt: now.addingTimeInterval(resetOffset)),
        headers: ["Date": httpDate(now.addingTimeInterval(5))]),
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == 0)
    #expect(try responseBody(reply).isEmpty)
  }

  @Test("Usage metadata failures expose only specific fixed diagnostic stages")
  func usageMetadataDiagnostics() async throws {
    let fixture = try fixture()
    let cases: [(date: String?, age: String?, expected: DesktopUsageHTTPTransport.Diagnostic)] = [
      (nil, nil, .usageDateMissing),
      ("private-synthetic-date", nil, .usageDateMalformed),
      ("", nil, .usageDateMalformed),
      (httpDate(now), "1", .usageAgePositive),
      (httpDate(now), "999999999999999", .usageAgePositive),
      (httpDate(now), "-1", .usageAgeInvalid),
      (httpDate(now), "NaN", .usageAgeInvalid),
      (httpDate(now), "0.0", .usageAgeInvalid),
      (httpDate(now), "", .usageAgeInvalid),
      (httpDate(now), "private-synthetic-age", .usageAgeInvalid),
      (httpDate(now.addingTimeInterval(-6)), nil, .usageDateTooOld),
      (httpDate(now.addingTimeInterval(6)), nil, .usageDateFuture),
    ]
    for sample in cases {
      let recorder = DiagnosticRecorder()
      let transport = DesktopUsageHTTPTransport(
        testProtocol: StubProtocol.self, now: { now }, diagnostic: { recorder.append($0) })
      var metadata = headers(["X-Synthetic-Private": "private-synthetic-header"])
      metadata["Date"] = sample.date
      metadata["Age"] = sample.age
      StubProtocol.state.install([
        profile(),
        .response(status: 200, headers: metadata, chunks: [usageBody()], delay: 0, finish: true),
      ])
      let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
      #expect(try status(reply) == 0)
      #expect(try responseBody(reply).isEmpty)
      #expect(recorder.events == [.profileReceived, .usageReceived, sample.expected])
      let output = recorder.events.map(\.rawValue).joined()
      #expect(!output.contains("private-synthetic"))
      #expect(!output.contains(account))
      #expect(!output.contains(organization))
    }
  }

  @Test("Usage payload failures expose typed fixed stages without payload contents")
  func usagePayloadDiagnostics() async throws {
    let fixture = try fixture()
    let cases: [(body: Data, expected: DesktopUsageHTTPTransport.Diagnostic)] = [
      (Data("private-synthetic-body".utf8), .usagePayloadMalformed),
      (Data([0xFF, 0xFE]), .usagePayloadMalformed),
      (Data("[]".utf8), .usagePayloadMalformed),
      (Data("{}".utf8), .usageWeeklyUnavailable),
      (Data("{\"seven_day\":null}".utf8), .usageWeeklyUnavailable),
      (Data("{\"seven_day\":\"private-synthetic-weekly\"}".utf8), .usageWindowInvalid),
      (
        Data("{\"seven_day\":{\"utilization\":10,\"resets_at\":\"private-synthetic-reset\"}}".utf8),
        .usageWindowInvalid
      ),
      (usageBody(resetAt: now), .usageWindowInvalid),
    ]
    for sample in cases {
      let recorder = DiagnosticRecorder()
      let transport = DesktopUsageHTTPTransport(
        testProtocol: StubProtocol.self, now: { now }, diagnostic: { recorder.append($0) })
      StubProtocol.state.install([profile(), response(body: sample.body)])
      let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
      #expect(try status(reply) == 0)
      #expect(try responseBody(reply).isEmpty)
      #expect(recorder.events == [.profileReceived, .usageReceived, sample.expected])
      let output = recorder.events.map(\.rawValue).joined()
      #expect(!output.contains("private-synthetic"))
      #expect(!output.contains(account))
      #expect(!output.contains(organization))
    }
  }

  @Test("An explicit zero cache age is acceptable")
  func zeroAge() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([
      response(body: profileBody(), headers: ["Age": "0"]),
      response(body: usageBody(), headers: ["Age": "0"]),
    ])
    #expect(
      try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 200)
  }

  @Test("An unexpected MIME type is never parsed", arguments: [false, true])
  func wrongContentType(onUsage: Bool) async throws {
    let fixture = try fixture()
    let wrong = response(
      body: onUsage ? usageBody() : profileBody(), headers: ["Content-Type": "text/html"])
    StubProtocol.state.install(onUsage ? [profile(), wrong] : [wrong])
    #expect(try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 0)
  }

  @Test("Declared oversized bodies are rejected before collection", arguments: [false, true])
  func oversizedDeclaredBody(onUsage: Bool) async throws {
    let fixture = try fixture()
    let oversized = response(headers: ["Content-Length": "16385"])
    StubProtocol.state.install(onUsage ? [profile(), oversized] : [oversized])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == 0)
    #expect(try responseBody(reply).isEmpty)
  }

  @Test("Undeclared streaming bodies cannot exceed 16 KiB", arguments: [false, true])
  func oversizedStream(onUsage: Bool) async throws {
    let fixture = try fixture()
    let oversized = StubAction.response(
      status: 200, headers: headers(),
      chunks: [Data(repeating: 32, count: 8192), Data(repeating: 32, count: 8193)],
      delay: 0, finish: true)
    StubProtocol.state.install(onUsage ? [profile(), oversized] : [oversized])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == 0)
    #expect(try responseBody(reply).isEmpty)
    #expect(StubProtocol.state.requests.count == (onUsage ? 2 : 1))
  }

  @Test("Exactly 16 KiB remains within the response limit")
  func exactBodyLimit() async throws {
    let fixture = try fixture()
    var profile = profileBody()
    profile.append(Data(repeating: 32, count: 16384 - profile.count))
    var usage = usageBody()
    usage.append(Data(repeating: 32, count: 16384 - usage.count))
    StubProtocol.state.install([response(body: profile), response(body: usage)])
    #expect(
      try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 200)
  }

  @Test(
    "Malformed usage and missing resets are sanitized",
    arguments: ["{}", "not-json", "{\"seven_day\":null}"])
  func malformedUsage(value: String) async throws {
    let fixture = try fixture()
    StubProtocol.state.install([profile(), response(body: Data(value.utf8))])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == 0)
    #expect(try responseBody(reply).isEmpty)
  }

  @Test("All redirects are refused, including same-origin redirects", arguments: [false, true])
  func redirects(sameOrigin: Bool) async throws {
    let fixture = try fixture()
    let destination = URL(
      string: sameOrigin
        ? "https://api.anthropic.com/api/oauth/usage" : "https://example.invalid/collect")!
    StubProtocol.state.install([.redirect(destination)])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    #expect(try status(reply) == 0)
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test("Responses from an unexpected URL are refused")
  func wrongResponseURL() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([.foreignResponse])
    #expect(try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 0)
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test("Cookies and cacheable responses are not reused")
  func noCookiesOrCache() async throws {
    let fixture = try fixture()
    let cacheHeaders = ["Set-Cookie": "synthetic=fixture; Path=/", "Cache-Control": "max-age=3600"]
    StubProtocol.state.install([
      response(body: profileBody(), headers: cacheHeaders),
      response(body: usageBody(), headers: cacheHeaders),
      response(body: profileBody(), headers: cacheHeaders),
      response(body: usageBody(), headers: cacheHeaders),
    ])
    let transport = transport
    #expect(
      try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 200)
    #expect(
      try status(await transport.fetch(request: fixture.request, lease: fixture.lease)) == 200)
    #expect(StubProtocol.state.requests.count == 4)
    #expect(StubProtocol.state.requests.allSatisfy { !$0.hasCookie && !$0.handlesCookies })
  }

  @Test("Underlying transport errors never return descriptions or response bytes")
  func networkFailure() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([.failure(.cannotConnectToHost)])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .networkFailure = reply else {
      Issue.record("Expected a sanitized network failure")
      return
    }
  }

  @Test("An underlying URLSession timeout remains a timeout")
  func networkTimeout() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([.failure(.timedOut)])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .timeout = reply else {
      Issue.record("Expected a sanitized timeout")
      return
    }
  }

  @Test("The total deadline bounds a stalled profile body")
  func stalledProfileDeadline() async throws {
    let fixture = try fixture(deadline: now.addingTimeInterval(0.3))
    StubProtocol.state.install([
      .response(status: 200, headers: headers(), chunks: [], delay: 0, finish: false)
    ])
    let start = ContinuousClock.now
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .timeout = reply else {
      Issue.record("Expected timeout for stalled profile")
      return
    }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test("Profile time is deducted from the usage deadline")
  func sharedDeadline() async throws {
    let fixture = try fixture(deadline: now.addingTimeInterval(1))
    StubProtocol.state.install([
      .response(status: 200, headers: headers(), chunks: [profileBody()], delay: 0.1, finish: true),
      .response(status: 200, headers: headers(), chunks: [], delay: 0, finish: false),
    ])
    let reply = await transport.fetch(request: fixture.request, lease: fixture.lease)
    guard case .timeout = reply else {
      Issue.record("Expected timeout for stalled usage")
      return
    }
    let requests = StubProtocol.state.requests
    #expect(requests.count == 2)
    if requests.count == 2 { #expect(requests[1].timeout < requests[0].timeout - 0.05) }
  }

  @Test("Cancellation before admission makes no requests")
  func cancelledBeforeStart() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([])
    let transport = transport
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await transport.fetch(request: fixture.request, lease: fixture.lease)
    }
    let reply = await task.value
    guard case .networkFailure = reply else {
      Issue.record("Expected cancellation to be sanitized")
      return
    }
    #expect(StubProtocol.state.requests.isEmpty)
  }

  @Test("Cancellation interrupts a stalled exchange without waiting for the deadline")
  func cancelledDuringRequest() async throws {
    let fixture = try fixture()
    StubProtocol.state.install([
      .response(status: 200, headers: headers(), chunks: [], delay: 0, finish: false)
    ])
    let transport = transport
    let task = Task { await transport.fetch(request: fixture.request, lease: fixture.lease) }
    for _ in 0..<100 {
      if !StubProtocol.state.requests.isEmpty { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let start = ContinuousClock.now
    task.cancel()
    let reply = await task.value
    guard case .networkFailure = reply else {
      Issue.record("Expected cancellation to be sanitized")
      return
    }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(StubProtocol.state.requests.count == 1)
  }

  private var transport: DesktopUsageHTTPTransport {
    DesktopUsageHTTPTransport(testProtocol: StubProtocol.self, now: { now })
  }

  private func fixture(
    account: String? = nil, organization: String? = nil, expiresAt: Date? = nil,
    hasScope: Bool = true, deadline: Date? = nil
  ) throws -> (request: DesktopUsageRequest, lease: DesktopCredentialLease) {
    let context = DesktopUsageContext(
      owner: try DesktopIdentity.owner(
        account: account ?? self.account, organization: organization ?? self.organization),
      generation: UUID(), expiresAt: expiresAt ?? now.addingTimeInterval(3600),
      hasProfileScope: hasScope)
    let request = DesktopUsageRequest(
      id: UUID(), context: context, startedAt: now, deadline: deadline ?? now.addingTimeInterval(30)
    )
    let lease = try DesktopCredentialLease(
      context: context, token: Data("synthetic-fixture-only".utf8))
    return (request, lease)
  }

  private func profile(account: String? = nil, organization: String? = nil) -> StubAction {
    response(body: profileBody(account: account, organization: organization))
  }

  private func profileBody(account: String? = nil, organization: String? = nil) -> Data {
    Data(
      "{\"account\":{\"uuid\":\"\(account ?? self.account)\"},\"organization\":{\"uuid\":\"\(organization ?? self.organization)\"}}"
        .utf8)
  }

  private func usageBody(resetAt: Date? = nil) -> Data {
    let reset = (resetAt ?? now.addingTimeInterval(86400)).formatted(.iso8601)
    return Data("{\"seven_day\":{\"utilization\":10,\"resets_at\":\"\(reset)\"}}".utf8)
  }

  private func headers(_ overrides: [String: String] = [:]) -> [String: String] {
    ["Date": httpDate(now), "Content-Type": "application/json"].merging(overrides) { _, new in new }
  }

  private func response(status: Int = 200, body: Data = Data(), headers: [String: String] = [:])
    -> StubAction
  {
    .response(
      status: status, headers: self.headers(headers), chunks: [body], delay: 0, finish: true)
  }

  private func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }

  private func status(_ reply: DesktopUsageReply) throws -> Int {
    guard case .response(let status, _, _, _, _, _) = reply else {
      throw FixtureError.unexpectedReply
    }
    return status
  }

  private func responseBody(_ reply: DesktopUsageReply) throws -> Data {
    guard case .response(_, _, _, _, _, let body) = reply else {
      throw FixtureError.unexpectedReply
    }
    return body
  }

  private enum FixtureError: Error { case unexpectedReply }
}

private final class DiagnosticRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [DesktopUsageHTTPTransport.Diagnostic] = []
  func append(_ value: DesktopUsageHTTPTransport.Diagnostic) {
    lock.lock()
    defer { lock.unlock() }
    values.append(value)
  }
  var events: [DesktopUsageHTTPTransport.Diagnostic] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private enum StubAction: Sendable {
  case response(
    status: Int, headers: [String: String], chunks: [Data], delay: TimeInterval, finish: Bool)
  case redirect(URL)
  case foreignResponse
  case failure(URLError.Code)
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
  static let state = StubState()
  private let workLock = NSLock()
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let action = Self.state.next(request)
    if case .response(_, _, _, let delay, _) = action, delay > 0 {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in deliver(action) }
    } else {
      deliver(action)
    }
  }

  private func deliver(_ action: StubAction) {
    workLock.lock()
    let active = !stopped
    workLock.unlock()
    guard active, let client, let url = request.url else { return }
    switch action {
    case .response(let status, let headers, let chunks, _, let finish):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
      for chunk in chunks { client.urlProtocol(self, didLoad: chunk) }
      if finish { client.urlProtocolDidFinishLoading(self) }
    case .redirect(let destination):
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": destination.absoluteString])!
      var redirected = request
      redirected.url = destination
      client.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
    case .foreignResponse:
      let response = HTTPURLResponse(
        url: URL(string: "https://example.invalid/unexpected")!, statusCode: 200,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocolDidFinishLoading(self)
    case .failure(let code):
      client.urlProtocol(
        self,
        didFailWithError: URLError(
          code, userInfo: [NSLocalizedDescriptionKey: "synthetic-private-description"]))
    }
  }

  override func stopLoading() {
    workLock.lock()
    stopped = true
    workLock.unlock()
  }
}

private final class StubState: @unchecked Sendable {
  struct Request: Sendable {
    let path: String
    let method: String?
    let fixedOrigin: Bool
    let hasBody: Bool
    let expectedAuthorization: Bool
    let handlesCookies: Bool
    let hasCookie: Bool
    let cachePolicy: URLRequest.CachePolicy
    let accept: String?
    let beta: String?
    let userAgent: String?
    let cacheControl: String?
    let pragma: String?
    let timeout: TimeInterval
  }

  private let lock = NSLock()
  private var actions: [StubAction] = []
  private var observed: [Request] = []

  var requests: [Request] {
    lock.lock()
    defer { lock.unlock() }
    return observed
  }

  func install(_ actions: [StubAction]) {
    lock.lock()
    defer { lock.unlock() }
    self.actions = actions
    observed = []
  }

  func next(_ request: URLRequest) -> StubAction {
    lock.lock()
    defer { lock.unlock() }
    observed.append(
      Request(
        path: request.url?.path ?? "", method: request.httpMethod,
        fixedOrigin: request.url?.scheme == "https" && request.url?.host == "api.anthropic.com"
          && request.url?.port == nil && request.url?.query == nil && request.url?.fragment == nil,
        hasBody: request.httpBody != nil || request.httpBodyStream != nil,
        expectedAuthorization: request.value(forHTTPHeaderField: "Authorization")
          == "Bearer synthetic-fixture-only",
        handlesCookies: request.httpShouldHandleCookies,
        hasCookie: request.value(forHTTPHeaderField: "Cookie") != nil,
        cachePolicy: request.cachePolicy, accept: request.value(forHTTPHeaderField: "Accept"),
        beta: request.value(forHTTPHeaderField: "anthropic-beta"),
        userAgent: request.value(forHTTPHeaderField: "User-Agent"),
        cacheControl: request.value(forHTTPHeaderField: "Cache-Control"),
        pragma: request.value(forHTTPHeaderField: "Pragma"),
        timeout: request.timeoutInterval))
    // Missing fixtures fail in memory; they can never fall through to real networking.
    return actions.isEmpty ? .failure(.resourceUnavailable) : actions.removeFirst()
  }
}
