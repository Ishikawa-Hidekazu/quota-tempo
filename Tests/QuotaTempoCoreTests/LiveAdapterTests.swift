import Foundation
import Testing

@testable import QuotaTempoCore

@Suite("Live adapter boundaries", .serialized)
struct LiveAdapterTests {
  private let now = Date(timeIntervalSince1970: 1_789_300_800)
  private let codexExecutable = URL(fileURLWithPath: "/mock/codex")

  @Test("Provider-disabled mode blocks every acquisition trigger")
  func providerDisabledBlocksAllTriggers() {
    let gate = ProviderAcquisitionGate(enabled: false)
    var invocationCount = 0
    for trigger in [
      ProviderAcquisitionTrigger.launch,
      .menuOpen,
      .scheduledRefresh,
      .systemWake,
      .explicitRefresh,
    ] {
      #expect(!gate.performIfAllowed(trigger) { invocationCount += 1 })
    }
    #expect(invocationCount == 0)
  }

  @Test("Automatic refresh is low-frequency and slower than both adapter guards")
  func automaticRefreshSchedule() {
    #expect(ProviderRefreshSchedule.interval == 900)
    #expect(ProviderRefreshSchedule.interval > CodexRateLimitAdapter.minimumRefreshInterval)
    #expect(ProviderRefreshSchedule.interval > ClaudeAutomaticAdapter.minimumRefreshInterval)
  }

  @Test("Codex classifies windows by duration and normalizes remaining capacity")
  func codexSuccess() {
    let runner = FakeRunner(result: .success(Self.codexResponse))
    let snapshot = CodexRateLimitAdapter(runner: runner, executable: self.codexExecutable)
      .refresh(previous: nil, now: self.now)
    #expect(snapshot.source == .codexAppServer)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.weekly?.remainingPercent == 66)
    #expect(snapshot.weekly?.durationSeconds == 604_800)
    #expect(snapshot.fiveHour?.remainingPercent == 80)
    #expect(snapshot.fiveHour?.durationSeconds == 18_000)
    #expect(snapshot.capturedAt == self.now)
    #expect(snapshot.lastAttemptAt == self.now)
    #expect(snapshot.errorCode == nil)
  }

  @Test("Codex replaces an earlier window with the provider-reported window after a reset")
  func codexRefreshAdoptsChangedWindow() {
    let previous = self.snapshot(source: .codexAppServer)
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(result: .success(Self.codexResponse)),
      executable: self.codexExecutable
    ).refresh(previous: previous, now: self.now)
    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)

    #expect(snapshot.weekly?.resetAt != previous.weekly?.resetAt)
    #expect(snapshot.weekly?.resetAt == Date(timeIntervalSince1970: 1_789_905_600))
    #expect(snapshot.weekly?.remainingPercent == 66)
    #expect(plan.targetNow == 100)
    #expect(plan.vsTarget == -34)
  }

  @Test("Codex hides percentages when the provider reports access restrictions")
  func codexAccessRestrictionsFailClosed() {
    let payloads = [
      #"{"id":2,"result":{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1789308000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789905600}}}}"#,
      #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1789308000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789905600},"spendControlReached":true}}}"#,
      #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1789308000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789905600},"rateLimitReachedType":"workspace_member_credits_depleted"}}}"#,
    ]

    for payload in payloads {
      let snapshot = CodexRateLimitAdapter(
        runner: FakeRunner(
          result: .success(
            BoundedProcessResult(
              stdout: Data("\(payload)\n".utf8),
              stderr: Data(),
              exitCode: 0
            )
          )
        ),
        executable: self.codexExecutable
      ).refresh(previous: self.snapshot(source: .codexAppServer), now: self.now)
      #expect(snapshot.weekly == nil)
      #expect(snapshot.fiveHour == nil)
      #expect(snapshot.sourceState == .accessRestricted)
      #expect(snapshot.errorCode == .usageRestricted)
      #expect(QuotaPlanner.evaluate(snapshot, now: self.now).status == .unavailable)
    }
  }

  @Test("Codex app-server request uses the documented initialized notification shape")
  func codexProtocolRequest() {
    let lines = String(decoding: CodexRateLimitAdapter.protocolRequest, as: UTF8.self)
      .split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[0].contains(#""version":"0.1.2""#))
    #expect(lines[1] == #"{"method":"initialized"}"#)
    #expect(lines[2] == #"{"method":"account/rateLimits/read","id":2}"#)
  }

  @Test("Codex timeout preserves a previous normalized snapshot")
  func codexTimeoutPreservesPrevious() {
    let previous = self.snapshot(source: .codexAppServer)
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(result: .failure(BoundedProcessError.timeout)),
      executable: self.codexExecutable
    ).refresh(previous: previous, now: self.now)
    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.lastAttemptAt == self.now)
    #expect(snapshot.sourceState == .attemptTimedOut)
    #expect(snapshot.errorCode == .timeout)
  }

  @Test("Codex first failure records only attempt time, not a synthetic capture")
  func codexFirstFailureHasNoCaptureTime() {
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(result: .failure(BoundedProcessError.timeout)),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(snapshot.capturedAt == nil)
    #expect(snapshot.lastAttemptAt == self.now)
    #expect(QuotaPlanner.evaluate(snapshot, now: self.now).capturedAt == nil)
  }

  @Test("Codex launch and input failures expose actionable stable causes")
  func codexProcessAvailabilityFailures() {
    let cases: [(BoundedProcessError, AcquisitionErrorCode)] = [
      (.launchFailed, .launchFailed),
      (.inputWriteFailed, .temporaryFailure),
    ]
    for (processError, expectedError) in cases {
      let snapshot = CodexRateLimitAdapter(
        runner: FakeRunner(result: .failure(processError)),
        executable: self.codexExecutable
      ).refresh(previous: nil, now: self.now)
      #expect(snapshot.sourceState == .attemptFailed)
      #expect(snapshot.errorCode == expectedError)
    }
  }

  @Test("Codex refresh trigger honors the five-minute last-attempt boundary")
  func codexRefreshTrigger() {
    #expect(CodexRateLimitAdapter.shouldRefresh(lastAttemptAt: nil, now: self.now))
    #expect(
      !CodexRateLimitAdapter.shouldRefresh(
        lastAttemptAt: self.now.addingTimeInterval(-299), now: self.now))
    #expect(
      CodexRateLimitAdapter.shouldRefresh(
        lastAttemptAt: self.now.addingTimeInterval(-300), now: self.now))
  }

  @Test("Codex malformed and oversized output fail closed")
  func codexFailures() {
    let malformed = CodexRateLimitAdapter(
      runner: FakeRunner(
        result: .success(
          BoundedProcessResult(stdout: Data("{}\n".utf8), stderr: Data(), exitCode: 0))),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(malformed.weekly == nil)
    #expect(malformed.sourceState == .attemptFailed)
    #expect(malformed.errorCode == .protocolIncompatible)

    let oversized = CodexRateLimitAdapter(
      runner: FakeRunner(result: .failure(BoundedProcessError.outputLimitExceeded)),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(oversized.errorCode == .outputLimitExceeded)
  }

  @Test("Foundation process runner enforces timeout and combined output limit")
  func boundedProcessRunner() throws {
    let shell = URL(fileURLWithPath: "/bin/sh")
    let timeoutRunner = FoundationBoundedProcessRunner(timeout: 0.1, outputLimit: 1_024)
    #expect(throws: BoundedProcessError.timeout) {
      try timeoutRunner.run(executable: shell, arguments: ["-c", "sleep 2"], stdin: Data())
    }

    let outputRunner = FoundationBoundedProcessRunner(timeout: 2, outputLimit: 64)
    #expect(throws: BoundedProcessError.outputLimitExceeded) {
      try outputRunner.run(
        executable: shell,
        arguments: ["-c", "printf '%0100d' 0"],
        stdin: Data()
      )
    }
  }

  @Test("Foundation process runner applies caller safety environment overrides")
  func boundedProcessRunnerEnvironmentOverrides() throws {
    let runner = FoundationBoundedProcessRunner(
      timeout: 2,
      outputLimit: 1_024,
      environmentOverrides: ["QUOTA_TEMPO_TEST_FLAG": "disabled"]
    )
    let result = try runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [],
      stdin: Data()
    )
    #expect(
      String(decoding: result.stdout, as: UTF8.self).contains("QUOTA_TEMPO_TEST_FLAG=disabled"))
  }

  @Test("Foundation process runner handles an early child exit without crashing")
  func boundedProcessRunnerEarlyExit() throws {
    let runner = FoundationBoundedProcessRunner(timeout: 2, outputLimit: 1_024)
    do {
      let result = try runner.run(
        executable: URL(fileURLWithPath: "/usr/bin/false"),
        arguments: [],
        stdin: Data(repeating: 0x41, count: 1_048_576)
      )
      #expect(result.exitCode != 0)
    } catch let error as BoundedProcessError {
      #expect(error == .inputWriteFailed)
    }
  }

  @Test("App-exit cleanup terminates every registered provider process tree")
  func boundedProcessRunnerGlobalCleanup() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("provider-process")
    let marker = root.appendingPathComponent("pid")
    try Data(
      """
      #!/bin/sh
      printf '%s' "$$" > "$1"
      sleep 30
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let completed = DispatchSemaphore(value: 0)
    let runner = FoundationBoundedProcessRunner(timeout: 10, outputLimit: 1_024)
    DispatchQueue.global(qos: .utility).async {
      _ = try? runner.run(
        executable: script,
        arguments: [marker.path],
        stdin: Data()
      )
      completed.signal()
    }

    let markerDeadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: marker.path), Date() < markerDeadline {
      usleep(10_000)
    }
    let pidText = try String(contentsOf: marker, encoding: .utf8)
    let pid = try #require(pid_t(pidText))

    FoundationBoundedProcessRunner.terminateAllRunningProcesses()
    #expect(completed.wait(timeout: .now() + 2) == .success)
    #expect(kill(pid, 0) != 0)
  }

  @Test("Foundation process runner bounds a blocked stdin write by the wall-clock timeout")
  func boundedProcessRunnerTimesOutBlockedInput() {
    let runner = FoundationBoundedProcessRunner(timeout: 0.2, outputLimit: 1_024)
    let startedAt = Date()
    #expect(throws: BoundedProcessError.timeout) {
      try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 30"],
        stdin: Data(repeating: 0x41, count: 1_048_576)
      )
    }
    #expect(Date().timeIntervalSince(startedAt) < 1.5)
  }

  @Test("Foundation process runner does not wait for a descendant holding pipe descriptors")
  func boundedProcessRunnerDoesNotWaitForDescendantPipe() throws {
    let runner = FoundationBoundedProcessRunner(timeout: 1, outputLimit: 1_024)
    let startedAt = Date()
    let result = try runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "sleep 3 & printf complete"],
      stdin: Data()
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout == Data("complete".utf8))
    #expect(Date().timeIntervalSince(startedAt) < 2.5)
  }

  @Test("Foundation process runner preserves ordered output at process exit")
  func boundedProcessRunnerPreservesOrderedOutput() throws {
    let runner = FoundationBoundedProcessRunner(timeout: 2, outputLimit: 64 * 1_024)
    let expected = (0..<2_000).map { String(format: "%04d", $0) }.joined(separator: "\n") + "\n"
    for _ in 0..<10 {
      let result = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "i=0; while [ $i -lt 2000 ]; do printf '%04d\\n' \"$i\"; i=$((i + 1)); done",
        ],
        stdin: Data()
      )
      #expect(result.exitCode == 0)
      #expect(result.stdout == Data(expected.utf8))
    }
  }

  @Test("Foundation process runner terminates descendants after timeout")
  func boundedProcessRunnerTerminatesDescendants() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("descendant-pid")
    let runner = FoundationBoundedProcessRunner(timeout: 0.2, outputLimit: 1_024)
    #expect(throws: BoundedProcessError.timeout) {
      try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "sleep 30 & child=$!; printf '%s' \"$child\" > '\(pidFile.path)'; wait",
        ],
        stdin: Data()
      )
    }
    let descendantPID = try #require(
      Int32(String(contentsOf: pidFile, encoding: .utf8))
    )
    let deadline = Date().addingTimeInterval(1)
    while kill(descendantPID, 0) == 0, Date() < deadline {
      usleep(10_000)
    }
    let isTerminated = kill(descendantPID, 0) != 0 && errno == ESRCH
    if !isTerminated { _ = kill(descendantPID, SIGKILL) }
    #expect(isTerminated)
  }

  @Test("Codex process runner keeps stdin open until response two arrives")
  func codexRunnerClosesInputAfterResponse() throws {
    let shell = URL(fileURLWithPath: "/bin/sh")
    let runner = FoundationBoundedProcessRunner(
      timeout: 2,
      outputLimit: 1_024,
      closeInputAfterResponseID: 2
    )
    let result = try runner.run(
      executable: shell,
      arguments: [
        "-c",
        "IFS= read -r first; IFS= read -r second; IFS= read -r third; "
          + "printf '{\"id\":2,\"result\":{}}\\n'; "
          + "if IFS= read -r trailing; then exit 9; fi",
      ],
      stdin: CodexRateLimitAdapter.protocolRequest
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout == Data("{\"id\":2,\"result\":{}}\n".utf8))
  }

  @Test("Codex response detection scans each output line once")
  func codexRunnerDetectsResponseAfterManyNotifications() throws {
    let runner = FoundationBoundedProcessRunner(
      timeout: 2,
      outputLimit: 256 * 1_024,
      closeInputAfterResponseID: 2
    )
    let result = try runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        "IFS= read -r first; IFS= read -r second; IFS= read -r third; "
          + "i=0; while [ $i -lt 3000 ]; do printf '{\"method\":\"note\",\"params\":{\"i\":%d}}\\n' \"$i\"; i=$((i + 1)); done; "
          + "printf '{\"id\":2,\"result\":{}}\\n'; "
          + "if IFS= read -r trailing; then exit 9; fi",
      ],
      stdin: CodexRateLimitAdapter.protocolRequest
    )
    #expect(result.exitCode == 0)
    let response = Data("{\"id\":2,\"result\":{}}\n".utf8)
    #expect(result.stdout.suffix(response.count) == response)
  }

  @Test("Codex response-triggered input close is serialized with nonblocking writes")
  func codexRunnerSerializesResponseCloseAndInputWrite() throws {
    let runner = FoundationBoundedProcessRunner(
      timeout: 1,
      outputLimit: 1_024,
      closeInputAfterResponseID: 2
    )
    for _ in 0..<50 {
      let result = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf '{\"id\":2,\"result\":{}}\\n'; sleep 0.01"],
        stdin: Data(repeating: 0x41, count: 1_048_576)
      )
      #expect(result.exitCode == 0)
      #expect(result.stdout == Data("{\"id\":2,\"result\":{}}\n".utf8))
    }
  }

  @Test("Codex missing duration or reset is not normalized")
  func codexMissingWindowMetadata() {
    let data = Data(
      """
      {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":null,"resetsAt":null},"secondary":null}}}
      """.utf8
    )
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(
        result: .success(BoundedProcessResult(stdout: data, stderr: Data(), exitCode: 0))),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.errorCode == .protocolIncompatible)
  }

  @Test("Codex falls back from an empty named bucket to the official legacy snapshot")
  func codexEmptyNamedBucketFallback() {
    let data = Data(
      """
      {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":null}},"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1789308000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789905600}}}}
      """.utf8
    )
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(
        result: .success(BoundedProcessResult(stdout: data, stderr: Data(), exitCode: 0))),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.weekly?.remainingPercent == 66)
    #expect(snapshot.fiveHour?.remainingPercent == 80)
  }

  @Test("Codex falls back when a recognized named bucket window is invalid")
  func codexInvalidNamedBucketFallback() {
    let data = Data(
      """
      {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":null},"secondary":null}},"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1789308000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789905600}}}}
      """.utf8
    )
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(
        result: .success(BoundedProcessResult(stdout: data, stderr: Data(), exitCode: 0))),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.weekly?.remainingPercent == 66)
    #expect(snapshot.fiveHour?.remainingPercent == 80)
  }

  @Test("Codex falls back when the named bucket omits the weekly window")
  func codexPartialNamedBucketFallback() {
    let data = Data(
      """
      {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1789308000},"secondary":null}},"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1789308000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789905600}}}}
      """.utf8
    )
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(
        result: .success(BoundedProcessResult(stdout: data, stderr: Data(), exitCode: 0))),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.weekly?.remainingPercent == 66)
    #expect(snapshot.fiveHour?.remainingPercent == 75)
  }

  @Test("Codex rejects a decimal percentage outside the official integer contract")
  func codexDecimalPercentFailsClosed() {
    let data = Data(
      """
      {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12.5,"windowDurationMins":10080,"resetsAt":1789905600},"secondary":null}}}
      """.utf8
    )
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(
        result: .success(BoundedProcessResult(stdout: data, stderr: Data(), exitCode: 0))),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .protocolIncompatible)
  }

  @Test("Codex resolver supports a user-local nvm installation")
  func codexResolverSupportsNVM() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let older = root.appendingPathComponent(".nvm/versions/node/v20.1.0/bin/codex")
    let newer = root.appendingPathComponent(".nvm/versions/node/v22.2.0/bin/codex")
    for executable in [older, newer] {
      try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("#!/usr/bin/env node\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
      )
    }
    #expect(
      CodexCLIExecutableResolver.resolve(
        homeDirectory: root,
        applicationDirectories: [],
        systemExecutables: []
      ) == newer)
  }

  @Test("Codex resolver returns the executable behind a user-local symlink")
  func codexResolverResolvesUserLocalSymlink() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent(".nvm/versions/node/v22.2.0/bin/codex")
    let link = root.appendingPathComponent(".local/bin/codex")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/usr/bin/env node\n".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(
      CodexCLIExecutableResolver.resolve(
        homeDirectory: root,
        applicationDirectories: [],
        systemExecutables: []
      ) == target.standardizedFileURL)
  }

  @Test("Codex resolver supports the executable bundled with the official desktop app")
  func codexResolverSupportsDesktopApp() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let executable = applications.appendingPathComponent(
      "ChatGPT.app/Contents/Resources/codex")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let packageManagerExecutable = root.appendingPathComponent("homebrew/bin/codex")
    try FileManager.default.createDirectory(
      at: packageManagerExecutable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: packageManagerExecutable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: packageManagerExecutable.path)

    #expect(
      CodexCLIExecutableResolver.resolve(
        homeDirectory: root,
        applicationDirectories: [applications],
        systemExecutables: [packageManagerExecutable],
        desktopTrustCheck: { _, _ in true }
      ) == executable.standardizedFileURL)
  }

  @Test("Codex resolver prefers a verified desktop executable over user-local candidates")
  func codexResolverPrefersVerifiedDesktop() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let desktop = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex")
    let userLocal = root.appendingPathComponent(".local/bin/codex")
    for executable in [desktop, userLocal] {
      try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("#!/bin/sh\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    let candidates = CodexCLIExecutableResolver.resolveCandidates(
      homeDirectory: root,
      applicationDirectories: [applications],
      systemExecutables: [],
      desktopTrustCheck: { _, _ in true }
    )

    #expect(candidates.map(\.source) == [.desktopBundled, .userLocal])
    #expect(candidates.first?.executable == desktop.standardizedFileURL)
  }

  @Test("Codex resolver rejects an untrusted or symlink-escaped desktop bundle")
  func codexResolverRejectsUntrustedDesktop() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let bundle = applications.appendingPathComponent("ChatGPT.app", isDirectory: true)
    let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
    let escapedResources = root.appendingPathComponent("escaped", isDirectory: true)
    try FileManager.default.createDirectory(at: escapedResources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: resources.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: escapedResources)
    let executable = resources.appendingPathComponent("codex")
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    #expect(
      !CodexDesktopTrustVerifier.hasDirectNestedExecutable(
        bundleURL: bundle,
        executableURL: executable
      ))
    #expect(
      CodexCLIExecutableResolver.resolveCandidates(
        homeDirectory: root,
        applicationDirectories: [applications],
        systemExecutables: [],
        desktopTrustCheck: { bundle, executable in
          CodexDesktopTrustVerifier.hasDirectNestedExecutable(
            bundleURL: bundle,
            executableURL: executable
          )
        }
      ).isEmpty)
  }

  @Test("Codex desktop trust pins the Apple Developer ID requirement for outer and nested code")
  func codexDesktopTrustPinsRequirements() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
    let executable = bundle.appendingPathComponent("Contents/Resources/codex")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: executable)

    let trusted = CodexDesktopTrustVerifier.isTrusted(
      bundleURL: bundle,
      executableURL: executable
    ) { url, requirement, validatesNestedCode in
      if url == bundle,
        requirement == CodexDesktopTrustVerifier.outerRequirement,
        validatesNestedCode
      {
        return .init(identifier: "com.openai.codex", teamIdentifier: "2DC432GLL2")
      }
      if url == executable,
        requirement == CodexDesktopTrustVerifier.nestedRequirement,
        !validatesNestedCode
      {
        return .init(identifier: "codex", teamIdentifier: "2DC432GLL2")
      }
      return nil
    }
    #expect(trusted)

    let wrongTeam = CodexDesktopTrustVerifier.isTrusted(
      bundleURL: bundle,
      executableURL: executable
    ) { url, _, _ in
      .init(
        identifier: url == bundle ? "com.openai.codex" : "codex",
        teamIdentifier: "WRONGTEAM"
      )
    }
    #expect(!wrongTeam)
  }

  @Test("Codex falls back by capability and never falls back after an access restriction")
  func codexCapabilityFallbackAndRestrictionBoundary() {
    let first = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/old-codex"),
      source: .userLocal
    )
    let second = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/desktop-codex"),
      source: .desktopBundled
    )
    let fallbackRunner = ExecutableResultRunner(results: [
      first.executable: .success(
        BoundedProcessResult(stdout: Data("{}\n".utf8), stderr: Data(), exitCode: 0)),
      second.executable: .success(Self.codexResponse),
    ])
    let snapshot = CodexRateLimitAdapter(
      runner: fallbackRunner,
      versionRunner: FakeRunner(
        result: .success(
          BoundedProcessResult(
            stdout: Data("codex-cli 0.133.0\n".utf8), stderr: Data(), exitCode: 0))),
      candidates: [first, second]
    ).refresh(previous: nil, now: self.now)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.codexExecutableSource == .desktopBundled)
    #expect(fallbackRunner.invocations == [first.executable, second.executable])

    let restrictedRunner = ExecutableResultRunner(results: [
      first.executable: .success(
        BoundedProcessResult(
          stdout: Data(#"{"id":2,"result":{"ordinaryUsageAllowed":false}}"#.utf8),
          stderr: Data(),
          exitCode: 0
        )),
      second.executable: .success(Self.codexResponse),
    ])
    let restricted = CodexRateLimitAdapter(
      runner: restrictedRunner,
      candidates: [first, second]
    ).refresh(previous: nil, now: self.now)
    #expect(restricted.errorCode == .usageRestricted)
    #expect(restrictedRunner.invocations == [first.executable])
  }

  @Test("Codex probes version only after failure and classifies a known-old CLI")
  func codexKnownOldVersionClassification() {
    let appServerRunner = RecordingRunner(
      result: .success(
        BoundedProcessResult(stdout: Data("{}\n".utf8), stderr: Data(), exitCode: 0)))
    let versionRunner = RecordingRunner(
      result: .success(
        BoundedProcessResult(
          stdout: Data("codex-cli 0.133.0\n".utf8), stderr: Data(), exitCode: 0)))
    let snapshot = CodexRateLimitAdapter(
      runner: appServerRunner,
      versionRunner: versionRunner,
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.errorCode == .versionTooOld)
    #expect(snapshot.codexExecutableVersion == "0.133.0")
    #expect(versionRunner.invocationCount == 1)
    #expect(versionRunner.lastArguments == ["--version"])

    let successVersionRunner = RecordingRunner(
      result: .failure(BoundedProcessError.launchFailed))
    _ = CodexRateLimitAdapter(
      runner: FakeRunner(result: .success(Self.codexResponse)),
      versionRunner: successVersionRunner,
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)
    #expect(successVersionRunner.invocationCount == 0)
  }

  @Test("Codex does not call an unproven intermediate version known-old")
  func codexUnknownIntermediateVersionClassification() {
    let snapshot = CodexRateLimitAdapter(
      runner: FakeRunner(
        result: .success(
          BoundedProcessResult(stdout: Data("{}\n".utf8), stderr: Data(), exitCode: 0))),
      versionRunner: FakeRunner(
        result: .success(
          BoundedProcessResult(
            stdout: Data("codex-cli 0.134.0\n".utf8), stderr: Data(), exitCode: 0))),
      executable: self.codexExecutable
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.errorCode == .protocolIncompatible)
    #expect(snapshot.codexExecutableVersion == "0.134.0")
  }

  @Test("Codex version extraction is bounded by safe integer parsing")
  func codexVersionExtraction() {
    #expect(CodexSemanticVersion.extract(from: "codex-cli v0.153.4-beta")?.description == "0.153.4")
    #expect(CodexSemanticVersion.extract(from: "0.133.0 then 0.153.4")?.description == "0.133.0")
    #expect(CodexSemanticVersion.extract(from: "100000.1.2") == nil)
    #expect(
      CodexSemanticVersion.extract(from: String(repeating: "9", count: 4_096) + ".1.2") == nil)
    #expect(
      CodexSemanticVersion.extract(from: String(decoding: [0xFF, 0xFE], as: UTF8.self)) == nil)
  }

  @Test("Codex bounds candidate attempts and probes one final candidate version")
  func codexBoundsCandidateAttempts() {
    let candidates = (0..<4).map {
      CodexExecutableCandidate(
        executable: URL(fileURLWithPath: "/mock/codex-\($0)"),
        source: .userLocal
      )
    }
    let runner = ExecutableResultRunner(
      results: Dictionary(
        uniqueKeysWithValues: candidates.map {
          ($0.executable, .failure(BoundedProcessError.launchFailed))
        }
      ))
    let versionRunner = RecordingRunner(
      result: .success(
        BoundedProcessResult(
          stdout: Data("codex-cli 0.153.4\n".utf8),
          stderr: Data(),
          exitCode: 0
        )))

    let snapshot = CodexRateLimitAdapter(
      runner: runner,
      versionRunner: versionRunner,
      candidates: candidates
    ).refresh(previous: nil, now: self.now)

    #expect(runner.invocations == Array(candidates.prefix(3)).map(\.executable))
    #expect(versionRunner.invocationCount == 1)
    #expect(snapshot.errorCode == .launchFailed)
    #expect(snapshot.codexExecutableVersion == "0.153.4")
  }

  @Test("Codex final failure uses a stable severity priority")
  func codexFinalFailurePriority() {
    let temporary = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/temporary"), source: .desktopBundled)
    let protocolFailure = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/protocol"), source: .userLocal)
    let timedOut = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/timeout"), source: .packageManager)
    let runner = ExecutableResultRunner(results: [
      temporary.executable: .success(
        BoundedProcessResult(stdout: Data(), stderr: Data(), exitCode: 1)),
      protocolFailure.executable: .success(
        BoundedProcessResult(stdout: Data("{}\n".utf8), stderr: Data(), exitCode: 0)),
      timedOut.executable: .failure(.timeout),
    ])

    let snapshot = CodexRateLimitAdapter(
      runner: runner,
      versionRunner: FakeRunner(result: .failure(.launchFailed)),
      candidates: [temporary, protocolFailure, timedOut]
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.errorCode == .timeout)
    #expect(snapshot.sourceState == .attemptTimedOut)
    #expect(snapshot.codexExecutableSource == .packageManager)
  }

  @Test("Codex preserves an output safety ceiling over other candidate failures")
  func codexOutputLimitFailurePriority() {
    let outputLimited = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/output-limited"), source: .desktopBundled)
    let timedOut = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/timed-out"), source: .userLocal)
    let launchFailed = CodexExecutableCandidate(
      executable: URL(fileURLWithPath: "/mock/launch-failed"), source: .packageManager)
    let runner = ExecutableResultRunner(results: [
      outputLimited.executable: .failure(.outputLimitExceeded),
      timedOut.executable: .failure(.timeout),
      launchFailed.executable: .failure(.launchFailed),
    ])

    let snapshot = CodexRateLimitAdapter(
      runner: runner,
      versionRunner: FakeRunner(
        result: .success(
          BoundedProcessResult(
            stdout: Data("codex-cli 0.133.0\n".utf8), stderr: Data(), exitCode: 0))),
      candidates: [outputLimited, timedOut, launchFailed]
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.errorCode == .outputLimitExceeded)
    #expect(snapshot.codexExecutableSource == .desktopBundled)
    #expect(snapshot.codexExecutableVersion == "0.133.0")
  }

  @Test("Codex reports a missing source without launching or probing")
  func codexReportsMissingSource() {
    let appRunner = RecordingRunner(result: .failure(.launchFailed))
    let versionRunner = RecordingRunner(result: .failure(.launchFailed))
    let snapshot = CodexRateLimitAdapter(
      runner: appRunner,
      versionRunner: versionRunner,
      candidates: []
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.errorCode == .sourceNotInstalled)
    #expect(appRunner.invocationCount == 0)
    #expect(versionRunner.invocationCount == 0)
  }

  @Test("Codex failure provenance describes only the current attempt")
  func codexFailureProvenanceIsCurrent() {
    let previous = ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: self.now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 60,
        durationSeconds: 604_800,
        resetAt: self.now.addingTimeInterval(300_000)
      ),
      fiveHour: nil,
      lastAttemptAt: self.now.addingTimeInterval(-60),
      sourceState: .observationSucceeded,
      errorCode: nil,
      codexExecutableSource: .desktopBundled,
      codexExecutableVersion: "0.153.4"
    )
    let missing = CodexRateLimitAdapter(
      runner: FakeRunner(result: .failure(.launchFailed)),
      candidates: []
    ).refresh(previous: previous, now: self.now)
    #expect(missing.weekly == previous.weekly)
    #expect(missing.codexExecutableSource == nil)
    #expect(missing.codexExecutableVersion == nil)

    let failed = CodexRateLimitAdapter(
      runner: FakeRunner(result: .failure(.launchFailed)),
      versionRunner: FakeRunner(result: .failure(.launchFailed)),
      candidates: [
        CodexExecutableCandidate(
          executable: self.codexExecutable,
          source: .packageManager
        )
      ]
    ).refresh(previous: previous, now: self.now)
    #expect(failed.weekly == previous.weekly)
    #expect(failed.codexExecutableSource == CodexExecutableSource.packageManager)
    #expect(failed.codexExecutableVersion == nil)
  }

  @Test("Codex adapter launches the resolved executable directly")
  func codexUsesResolvedExecutable() {
    let runner = RecordingRunner(result: .success(Self.codexResponse))
    _ = CodexRateLimitAdapter(runner: runner, executable: self.codexExecutable)
      .refresh(previous: nil, now: self.now)
    #expect(runner.lastExecutable == self.codexExecutable)
    #expect(runner.lastArguments == ["app-server", "--stdio"])
  }

  @Test("Claude accepts only documented windows and marks a local observation")
  func claudeSuccess() throws {
    let data = Data(
      """
      {"rate_limits":{"five_hour":{"used_percentage":25.5,"resets_at":1789308000},"seven_day":{"used_percentage":40,"resets_at":1789905600}},"transcript_path":"ignored"}
      """.utf8
    )
    let snapshot = try ClaudeStatusLineBridge.normalize(data, receivedAt: self.now)
    #expect(snapshot.source == .claudeStatusLine)
    #expect(snapshot.weekly?.remainingPercent == 60)
    #expect(snapshot.fiveHour?.remainingPercent == 74.5)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.lastAttemptAt == nil)
    let persisted = String(decoding: try NormalizedSnapshotCodec.encode(snapshot), as: UTF8.self)
    #expect(!persisted.contains("transcript"))
  }

  @Test("Claude missing windows and malformed values fail closed")
  func claudeFailures() {
    #expect(throws: ClaudeBridgeError.noRateLimitWindow) {
      try ClaudeStatusLineBridge.normalize(Data("{}".utf8), receivedAt: self.now)
    }
    #expect(throws: ClaudeBridgeError.invalidInput) {
      try ClaudeStatusLineBridge.normalize(
        Data("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":101,\"resets_at\":1}}}".utf8),
        receivedAt: self.now
      )
    }
  }

  @Test("Claude bridge rejects oversized stdin with a stable metadata-only code")
  func claudeOversizedInput() {
    let data = Data(repeating: 0x41, count: ClaudeStatusLineBridge.maximumInputBytes + 1)
    #expect(throws: ClaudeBridgeError.inputTooLarge) {
      try ClaudeStatusLineBridge.normalize(data, receivedAt: self.now)
    }
    #expect(ClaudeBridgeError.inputTooLarge.stableCode == "input_too_large")
  }

  @Test("Bounded stdin reader accumulates partial reads and enforces the total limit")
  func boundedInputReader() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let exactURL = root.appendingPathComponent("exact")
    let oversizedURL = root.appendingPathComponent("oversized")
    try Data("abcdef".utf8).write(to: exactURL)
    try Data("abcdefg".utf8).write(to: oversizedURL)

    let exact = try FileHandle(forReadingFrom: exactURL)
    defer { try? exact.close() }
    #expect(try BoundedInputReader.read(from: exact, limit: 6, chunkSize: 2) == Data("abcdef".utf8))

    let oversized = try FileHandle(forReadingFrom: oversizedURL)
    defer { try? oversized.close() }
    #expect(throws: ClaudeBridgeError.inputTooLarge) {
      try BoundedInputReader.read(from: oversized, limit: 6, chunkSize: 2)
    }
  }

  @Test("Claude automatic adapter uses a fresh complete local cache without launching CLI")
  func claudeAutomaticFreshCache() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try Data(#"{"samples":[]}"#.utf8).write(to: history)
    try self.cacheJSON(
      fetchedAt: self.now.addingTimeInterval(-120),
      fiveHourUsed: 25,
      weeklyUsed: 40
    ).write(to: cache)
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeLocalCache)
    #expect(snapshot.weekly?.remainingPercent == 60)
    #expect(snapshot.fiveHour?.remainingPercent == 75)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.lastAttemptAt == self.now)
    #expect(runner.invocationCount == 0)
  }

  @Test("Claude Desktop-only observation succeeds without a Claude Code cache")
  func claudeAutomaticDefaultDisablesCLI() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 22, 37)]).write(to: history)
    let runner = RecordingRunner(result: .success(self.claudeControlResponse()))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 63)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.errorCode == nil)
    #expect(runner.invocationCount == 0)
  }

  @Test("Claude Desktop observation succeeds when the Claude Code cache has no usage yet")
  func claudeAutomaticAllowsEmptyOptionalCache() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 22, 37)]).write(to: history)
    try Data("{}".utf8).write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 63)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.errorCode == nil)
  }

  @Test("Claude Desktop observation still reports a malformed optional cache")
  func claudeAutomaticReportsMalformedOptionalCache() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 22, 37)]).write(to: history)
    try Data("{".utf8).write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 63)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .invalidResponse)
  }

  @Test("Claude empty local sources are unavailable rather than malformed")
  func claudeAutomaticClassifiesEmptyLocalSources() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try Data(#"{"samples":[]}"#.utf8).write(to: history)
    try Data("{}".utf8).write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.capturedAt == nil)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .sourceUnavailable)
  }

  @Test("Claude automatic adapter does not replace a newer snapshot with an older fresh cache")
  func claudeAutomaticKeepsNewerPreviousOnLocalSuccess() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("missing-history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.cacheJSON(
      fetchedAt: self.now.addingTimeInterval(-120),
      fiveHourUsed: 25,
      weeklyUsed: 40
    ).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: self.now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 61,
        durationSeconds: 604_800,
        resetAt: self.now.addingTimeInterval(300_000)
      ),
      sourceState: .observationSucceeded
    )
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: previous, now: self.now)

    #expect(snapshot.source == previous.source)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(runner.invocationCount == 0)
  }

  @Test("Claude automatic adapter preserves utilization when a reset is unusable")
  func claudeAutomaticDropsOnlyExpiredWindow() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("missing-history.json")
    let cache = root.appendingPathComponent("claude.json")
    let formatter = ISO8601DateFormatter()
    let data = try JSONSerialization.data(withJSONObject: [
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(self.now.addingTimeInterval(-120).timeIntervalSince1970 * 1_000),
        "utilization": [
          "five_hour": [
            "utilization": 25,
            "resets_at": formatter.string(from: self.now.addingTimeInterval(-1)),
          ],
          "seven_day": [
            "utilization": 40,
            "resets_at": formatter.string(from: self.now.addingTimeInterval(300_000)),
          ],
        ],
      ]
    ])
    try data.write(to: cache)
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeLocalCache)
    #expect(snapshot.weekly?.remainingPercent == 60)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.fiveHour?.remainingPercent == 75)
    #expect(snapshot.fiveHour?.resetAt == nil)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(runner.invocationCount == 0)
  }

  @Test("Claude preserves weekly remaining when reset exceeds the planning window")
  func claudeAutomaticDegradesFarResetToUnknown() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("missing-history.json")
    let cache = root.appendingPathComponent("claude.json")
    let formatter = ISO8601DateFormatter()
    let data = try JSONSerialization.data(withJSONObject: [
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(self.now.addingTimeInterval(-120).timeIntervalSince1970 * 1_000),
        "utilization": [
          "seven_day": [
            "utilization": 10,
            "resets_at": formatter.string(from: self.now.addingTimeInterval(606_600)),
          ]
        ],
      ]
    ])
    try data.write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)
    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)

    #expect(snapshot.weekly?.remainingPercent == 90)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(plan.weeklyRemaining == 90)
    #expect(plan.targetNow == nil)
    #expect(plan.status == .resetUnknown)
  }

  @Test("Claude automatic adapter runs a bounded hook-free non-persistent CLI probe")
  func claudeAutomaticCLIProbe() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("missing-history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    let runner = RecordingRunner(result: .success(self.claudeControlResponse()))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeCLI)
    #expect(snapshot.weekly?.remainingPercent == 57)
    #expect(snapshot.fiveHour?.remainingPercent == 54)
    #expect(runner.invocationCount == 1)
    #expect(runner.lastExecutable == URL(fileURLWithPath: "/mock/claude"))
    #expect(runner.lastArguments?.first == "-p")
    #expect(runner.lastArguments?.contains("--no-session-persistence") == true)
    #expect(runner.lastArguments?.contains("--safe-mode") == true)
    #expect(runner.lastArguments?.contains("--tools") == true)
    let toolsIndex = try #require(runner.lastArguments?.firstIndex(of: "--tools"))
    #expect(runner.lastArguments?[toolsIndex + 1] == "")
    #expect(runner.lastArguments?.contains("--no-chrome") == true)
    #expect(runner.lastArguments?.contains(#"{"disableAllHooks":true}"#) == true)
    #expect(runner.lastStdin == ClaudeAutomaticAdapter.cliRequest)
    #expect(runner.observedCurrentDirectoryExisted)
    #expect(
      runner.lastCurrentDirectory?.standardizedFileURL.path
        == root.appendingPathComponent("probe").path)
    #expect(
      runner.lastCurrentDirectory.map { FileManager.default.fileExists(atPath: $0.path) } == true)
  }

  @Test("Claude CLI resolver finds and resolves the user-local installation")
  func claudeCLIResolverUsesKnownUserLocalPath() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude-real")
    let bin = root.appendingPathComponent(".local/bin")
    let link = bin.appendingPathComponent("claude")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

    #expect(
      ClaudeCLIExecutableResolver.resolve(homeDirectory: root)
        == executable.resolvingSymlinksInPath())
  }

  @Test("Claude automatic adapter fails closed when no CLI executable is available")
  func claudeAutomaticMissingCLIFallsBackWithoutLaunch() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 22, 37)]).write(to: history)
    let runner = RecordingRunner(result: .success(self.claudeControlResponse()))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .sourceUnavailable)
    #expect(runner.invocationCount == 0)
  }

  @Test("Claude automatic adapter merges newer Desktop utilization with compatible cache reset")
  func claudeAutomaticMergesLocalSources() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 22, 37)]).write(to: history)
    try self.cacheJSON(
      fetchedAt: self.now.addingTimeInterval(-600),
      fiveHourUsed: 25,
      weeklyUsed: 40
    ).write(to: cache)
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeLocalMerged)
    #expect(snapshot.capturedAt == self.now.addingTimeInterval(-60))
    #expect(snapshot.weekly?.remainingPercent == 63)
    #expect(snapshot.fiveHour?.remainingPercent == 78)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.fiveHour?.resetAt != nil)
    #expect(runner.invocationCount == 0)
  }

  @Test("Claude automatic adapter keeps a newer observation's own reset")
  func claudeAutomaticKeepsNewerLocalReset() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("missing-history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.cacheJSON(
      fetchedAt: self.now.addingTimeInterval(-60),
      fiveHourUsed: 20,
      weeklyUsed: 35
    ).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: self.now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 64,
        durationSeconds: 604_800,
        resetAt: self.now.addingTimeInterval(100_000)
      ),
      fiveHour: QuotaWindow(
        remainingPercent: 79,
        durationSeconds: 18_000,
        resetAt: self.now.addingTimeInterval(5_000)
      ),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: previous, now: self.now)

    #expect(snapshot.capturedAt == self.now.addingTimeInterval(-60))
    #expect(snapshot.weekly?.remainingPercent == 65)
    #expect(snapshot.weekly?.resetAt == self.now.addingTimeInterval(300_000))
    #expect(snapshot.fiveHour?.remainingPercent == 80)
    #expect(snapshot.fiveHour?.resetAt == self.now.addingTimeInterval(10_000))
  }

  @Test("Claude automatic adapter reuses a compatible reset from an older cache")
  func claudeAutomaticMergesOlderCacheReset() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 20, 35)]).write(to: history)
    try self.cacheJSON(
      fetchedAt: self.now.addingTimeInterval(-960),
      fiveHourUsed: 21,
      weeklyUsed: 36
    ).write(to: cache)
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeLocalMerged)
    #expect(snapshot.weekly?.remainingPercent == 65)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(QuotaPlanner.evaluate(snapshot, now: self.now).targetNow != nil)
    #expect(runner.invocationCount == 0)
  }

  @Test("Claude projects one weekly reset from the last confirmed window")
  func claudeAutomaticProjectsOneWeeklyReset() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    let confirmedReset = self.now.addingTimeInterval(-3_600)
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 20, 25)]).write(to: history)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeLocalCache,
      capturedAt: confirmedReset.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 70,
        durationSeconds: 604_800,
        resetAt: confirmedReset
      ),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: previous, now: self.now)
    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)

    #expect(snapshot.weekly?.remainingPercent == 75)
    #expect(snapshot.weekly?.resetAt == confirmedReset.addingTimeInterval(604_800))
    #expect(snapshot.weekly?.isResetEstimated == true)
    #expect(plan.targetNow != nil)
    #expect(plan.targetIsEstimated)
  }

  @Test("Claude does not project a weekly reset when remaining did not increase")
  func claudeAutomaticRejectsStaleWeeklyProjection() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    let confirmedReset = self.now.addingTimeInterval(-3_600)
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 20, 96)]).write(to: history)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeLocalCache,
      capturedAt: confirmedReset.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 4,
        durationSeconds: 604_800,
        resetAt: confirmedReset
      ),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: previous, now: self.now)
    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)

    #expect(snapshot.weekly?.remainingPercent == 4)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.weekly?.isResetEstimated == false)
    #expect(plan.status == .resetUnknown)
    #expect(plan.targetNow == nil)
  }

  @Test("Claude never chains an estimated weekly reset into another estimate")
  func claudeAutomaticDoesNotChainWeeklyProjection() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    let expiredEstimate = self.now.addingTimeInterval(-3_600)
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 20, 25)]).write(to: history)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeDesktopHistory,
      capturedAt: expiredEstimate.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 70,
        durationSeconds: 604_800,
        resetAt: expiredEstimate,
        resetAtIsEstimated: true
      ),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: previous, now: self.now)

    #expect(snapshot.weekly?.remainingPercent == 75)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(!snapshot.weekly!.isResetEstimated)
    #expect(QuotaPlanner.evaluate(snapshot, now: self.now).targetNow == nil)
  }

  @Test("Claude automatic adapter does not merge reset from an incompatible window")
  func claudeAutomaticRejectsIncompatibleResetMerge() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-60), 20, 35)]).write(to: history)
    try self.cacheJSON(
      fetchedAt: self.now.addingTimeInterval(-700_000),
      fiveHourUsed: 21,
      weeklyUsed: 36
    ).write(to: cache)
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 65)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .sourceUnavailable)
    #expect(runner.invocationCount == 1)
  }

  @Test("Claude automatic adapter does not make an older missing window look fresh")
  func claudeAutomaticDoesNotFillMissingWindowFromOlderCache() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(self.now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000),
          "u": ["fh": 20],
        ]
      ]
    ]).write(to: history)
    try self.cacheJSON(
      fetchedAt: self.now.addingTimeInterval(-600),
      fiveHourUsed: 21,
      weeklyUsed: 36
    ).write(to: cache)
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.source == .claudeLocalMerged)
    #expect(snapshot.fiveHour?.remainingPercent == 80)
    #expect(snapshot.fiveHour?.resetAt != nil)
    #expect(snapshot.weekly == nil)
    #expect(runner.invocationCount == 1)
  }

  @Test("Claude automatic adapter falls back to Desktop history without guessing reset")
  func claudeAutomaticHistoryFallback() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    try self.historyJSON(
      samples: [
        (self.now.addingTimeInterval(-600), 10, 20),
        (self.now.addingTimeInterval(-60), 22, 37),
      ]
    ).write(to: history)
    let runner = RecordingRunner(result: .failure(.launchFailed))

    let snapshot = ClaudeAutomaticAdapter(
      runner: runner,
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: self.now)
    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)

    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.remainingPercent == 63)
    #expect(snapshot.fiveHour?.remainingPercent == 78)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(plan.weeklyRemaining == 63)
    #expect(plan.targetNow == nil)
    #expect(plan.vsTarget == nil)
    #expect(plan.status == .resetUnknown)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .sourceUnavailable)
    #expect(runner.invocationCount == 1)
  }

  @Test("Claude automatic adapter failure does not replace a newer previous snapshot")
  func claudeAutomaticFailureKeepsNewerPrevious() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    try self.historyJSON(samples: [(self.now.addingTimeInterval(-7_200), 22, 37)]).write(
      to: history)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: self.now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 61,
        durationSeconds: 604_800,
        resetAt: self.now.addingTimeInterval(300_000)
      ),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.timeout)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: previous, now: self.now)

    #expect(snapshot.source == previous.source)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.lastAttemptAt == self.now)
    #expect(snapshot.sourceState == .attemptTimedOut)
    #expect(snapshot.errorCode == .timeout)
  }

  @Test("Claude automatic adapter rejects malformed local values and preserves last good data")
  func claudeAutomaticFailurePreservesPrevious() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.historyJSON(samples: [(self.now, 120, 140)]).write(to: history)
    try Data(#"{"cachedUsageUtilization":{"fetchedAtMs":0}}"#.utf8).write(to: cache)
    let previous = ProviderSnapshot(
      provider: .claude,
      source: .claudeCLI,
      capturedAt: self.now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 61,
        durationSeconds: 604_800,
        resetAt: self.now.addingTimeInterval(300_000)
      ),
      sourceState: .observationSucceeded
    )

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.outputLimitExceeded)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache,
      cliFallbackEnabled: true,
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: previous, now: self.now)

    #expect(snapshot.weekly == previous.weekly)
    #expect(snapshot.capturedAt == previous.capturedAt)
    #expect(snapshot.lastAttemptAt == self.now)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .outputLimitExceeded)
  }

  @Test("Claude local reader rejects symlink and oversized inputs")
  func claudeLocalReaderSafety() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real.json")
    let link = root.appendingPathComponent("linked.json")
    try Data("{}".utf8).write(to: real)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let reader = FileBoundedLocalDataReader()
    #expect(throws: ClaudeAutomaticAdapterError.unsafePath) {
      try reader.read(from: link, limit: 1_024)
    }
    #expect(throws: ClaudeAutomaticAdapterError.inputTooLarge) {
      try reader.read(from: real, limit: 1)
    }
  }

  @Test("Claude automatic adapter rejects pre-Unix timestamps without persisting them")
  func claudeAutomaticRejectsPreUnixTimestamp() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    try Data(#"{"samples":[{"t":-62167219200000,"u":{"fh":20,"sd":25}}]}"#.utf8)
      .write(to: history)

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.capturedAt == nil)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .invalidResponse)
    #expect(throws: Never.self) {
      _ = try NormalizedSnapshotCodec.encode(snapshot)
    }
  }

  @Test("Claude automatic adapter rejects a pre-Unix cache timestamp")
  func claudeAutomaticRejectsPreUnixCacheTimestamp() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("missing-history.json")
    let cache = root.appendingPathComponent("claude.json")
    try self.cacheJSON(
      fetchedAt: Date(timeIntervalSince1970: -1),
      fiveHourUsed: 20,
      weeklyUsed: 25
    ).write(to: cache)

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: nil,
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.capturedAt == nil)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .invalidResponse)
  }

  @Test("Claude automatic adapter exposes safe local read failure categories")
  func claudeAutomaticReportsLocalReadFailure() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real-history.json")
    let link = root.appendingPathComponent("history.json")
    try self.historyJSON(samples: [(self.now, 20, 25)]).write(to: real)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: nil,
      historyURL: link,
      cacheURL: root.appendingPathComponent("missing-cache.json")
    ).refresh(previous: nil, now: self.now)

    #expect(snapshot.capturedAt == nil)
    #expect(snapshot.sourceState == .attemptFailed)
    #expect(snapshot.errorCode == .unsafePath)
  }

  @Test("Claude normalized storage excludes source-only account and response fields")
  func claudeAutomaticStorageIsMetadataOnly() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let cache = root.appendingPathComponent("missing-cache.json")
    try self.historyJSON(samples: [(self.now, 12, 34)], organization: "private-org-id")
      .write(to: history)
    let snapshot = ClaudeAutomaticAdapter(
      runner: RecordingRunner(result: .failure(.launchFailed)),
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: history,
      cacheURL: cache
    ).refresh(previous: nil, now: self.now)
    let persisted = String(decoding: try NormalizedSnapshotCodec.encode(snapshot), as: UTF8.self)
    #expect(!persisted.contains("private-org-id"))
    #expect(!persisted.contains("rate_limits"))
    #expect(!persisted.contains("request_id"))
  }

  @Test("Atomic store keeps only normalized provider metadata")
  func atomicStore() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NormalizedSnapshotStore(directory: root)
    let snapshot = self.snapshot(source: .claudeStatusLine)
    try store.save(snapshot)
    #expect(try store.load(.claude) == snapshot)
    let text = try String(contentsOf: store.url(for: .claude), encoding: .utf8)
    #expect(!text.contains("credential"))
    #expect(!text.contains("transcript"))
    let directoryMode = try #require(
      FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    )
    let fileMode = try #require(
      FileManager.default.attributesOfItem(atPath: store.url(for: .claude).path)[.posixPermissions]
        as? NSNumber
    )
    #expect(directoryMode.intValue == 0o700)
    #expect(fileMode.intValue == 0o600)
  }

  @Test("Reloading the normalized store advances freshness without a provider call")
  func normalizedStoreReloadAdvancesFreshness() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NormalizedSnapshotStore(directory: root)
    try store.save(self.snapshot(source: .claudeStatusLine))
    let recent = try #require(
      store.scenario(now: self.now).snapshots.first { $0.provider == .claude })
    #expect(QuotaPlanner.evaluate(recent, now: self.now).freshness == .recent)
    let staleNow = self.now.addingTimeInterval(1_301)
    let stale = try #require(
      store.scenario(now: staleNow).snapshots.first { $0.provider == .claude })
    #expect(QuotaPlanner.evaluate(stale, now: staleNow).freshness == .stale)
  }

  @Test("Transient save failure remains visible across store reloads")
  func transientSaveFailureOverlay() throws {
    let base = self.snapshot(source: .codexAppServer)
    let failed = AcquisitionRecords.preservingFailure(
      previous: base,
      provider: .codex,
      source: .codexAppServer,
      attemptedAt: self.now,
      state: .attemptFailed,
      error: .atomicWriteFailed
    )
    let scenario = FixtureScenario(
      id: "stored",
      now: self.now.addingTimeInterval(-60),
      snapshots: [base]
    )
    let overlaid = SnapshotScenarioOverlay.apply(
      [.codex: failed],
      to: scenario,
      now: self.now
    )
    #expect(overlaid.now == self.now)
    #expect(overlaid.snapshots == [failed])
    #expect(overlaid.snapshots[0].errorCode == .atomicWriteFailed)
  }

  @Test("Transient snapshot is the current refresh input ahead of stored data")
  func transientSnapshotIsCurrentRefreshInput() {
    let stored = self.snapshot(source: .codexAppServer)
    let transient = AcquisitionRecords.preservingFailure(
      previous: ProviderSnapshot(
        provider: .codex,
        source: .codexAppServer,
        capturedAt: self.now,
        weekly: QuotaWindow(
          remainingPercent: 55,
          durationSeconds: 604_800,
          resetAt: self.now.addingTimeInterval(300_000)
        ),
        lastAttemptAt: self.now,
        sourceState: .observationSucceeded
      ),
      provider: .codex,
      source: .codexAppServer,
      attemptedAt: self.now,
      state: .attemptFailed,
      error: .atomicWriteFailed
    )

    let current = SnapshotScenarioOverlay.currentSnapshot(
      for: .codex,
      stored: stored,
      overrides: [.codex: transient]
    )

    #expect(current == transient)
    #expect(current?.capturedAt == self.now)
    #expect(current?.lastAttemptAt == self.now)
  }

  @Test("Empty normalized store marks both providers as never observed")
  func emptyStoreUsesNeverObservedState() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshots = NormalizedSnapshotStore(directory: root).scenario(now: self.now).snapshots

    #expect(snapshots.count == 2)
    #expect(snapshots.allSatisfy { $0.sourceState == .neverObserved })
  }

  @Test("Atomic write failure does not replace an existing snapshot")
  func atomicFailure() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let originalStore = NormalizedSnapshotStore(directory: root)
    let original = self.snapshot(source: .codexAppServer)
    try originalStore.save(original)
    let failing = NormalizedSnapshotStore(directory: root, writer: FailingWriter())
    #expect(throws: (any Error).self) { try failing.save(self.snapshot(source: .codexAppServer)) }
    #expect(try originalStore.load(.codex) == original)
  }

  @Test("Atomic writer rejects a symlink in the selected output ancestry")
  func atomicWriterRejectsSymlinkAncestor() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    let link = root.appendingPathComponent("linked")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let output = link.appendingPathComponent("nested/codex.json")
    #expect(throws: SnapshotStoreError.unsafeOutput) {
      try FileAtomicDataWriter().write(Data("{}".utf8), to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("nested").path))
  }

  @Test("Claude lifecycle coexists, rolls back, and uninstalls in an isolated config")
  func claudeLifecycle() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appendingPathComponent("settings.json")
    let install = root.appendingPathComponent("quota-tempo")
    let bridge = root.appendingPathComponent("QuotaTempoBridge")
    let output = root.appendingPathComponent("data/claude.json")
    let original = Data(
      "{\"statusLine\":{\"type\":\"command\",\"command\":\"printf existing\",\"padding\":2},\"theme\":\"dark\"}"
        .utf8)
    try original.write(to: settings)
    try Data("bridge".utf8).write(to: bridge)
    let lifecycle = ClaudeStatusLineLifecycle(
      settingsURL: settings,
      installationDirectory: install,
      bridgeExecutable: bridge,
      snapshotURL: output
    )

    #expect(throws: ClaudeLifecycleError.consentRequired) { try lifecycle.activate(consent: false) }
    try lifecycle.activate(consent: true)
    #expect(try lifecycle.status() == .active)
    let wrapper = try String(contentsOf: lifecycle.wrapperURL, encoding: .utf8)
    let wrapperData = try Data(contentsOf: lifecycle.wrapperURL)
    #expect(wrapper.contains("ingest-claude"))
    #expect(wrapper.contains("printf existing"))
    #expect(!wrapperData.contains(0))
    #expect(wrapper.contains(#"/usr/bin/printf '\036'"#))
    #expect(FileManager.default.fileExists(atPath: lifecycle.backupURL.path))
    let ownershipBackup = try String(contentsOf: lifecycle.backupURL, encoding: .utf8)
    #expect(ownershipBackup.contains("statusLine"))
    #expect(!ownershipBackup.contains("theme"))
    let activeSettings = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    )
    let activeStatusLine = try #require(activeSettings["statusLine"] as? [String: Any])
    #expect(activeStatusLine["padding"] as? Int == 2)

    var externallyUpdated = activeSettings
    externallyUpdated["theme"] = "light"
    externallyUpdated["newSetting"] = true
    try JSONSerialization.data(withJSONObject: externallyUpdated).write(to: settings)

    try lifecycle.rollback()
    let rolledBack = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    )
    #expect(rolledBack["theme"] as? String == "light")
    #expect(rolledBack["newSetting"] as? Bool == true)
    let restoredStatusLine = try #require(rolledBack["statusLine"] as? [String: Any])
    #expect(restoredStatusLine["command"] as? String == "printf existing")
    #expect(restoredStatusLine["padding"] as? Int == 2)
    #expect(try lifecycle.status() == .backupOnly)

    try lifecycle.uninstall()
    #expect(try lifecycle.status() == .inactive)
  }

  @Test("Claude rollback fails closed when status-line ownership drifts")
  func claudeLifecycleOwnershipDrift() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appendingPathComponent("settings.json")
    let install = root.appendingPathComponent("quota-tempo")
    let bridge = root.appendingPathComponent("bridge")
    try Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"original\"}}".utf8).write(
      to: settings)
    try Data().write(to: bridge)
    let lifecycle = ClaudeStatusLineLifecycle(
      settingsURL: settings,
      installationDirectory: install,
      bridgeExecutable: bridge,
      snapshotURL: root.appendingPathComponent("claude.json")
    )
    try lifecycle.activate(consent: true)
    let drifted = Data(
      "{\"theme\":\"dark\",\"statusLine\":{\"type\":\"command\",\"command\":\"other\"}}".utf8)
    try drifted.write(to: settings)
    #expect(throws: ClaudeLifecycleError.ownershipDrift) { try lifecycle.rollback() }
    #expect(throws: ClaudeLifecycleError.ownershipDrift) { try lifecycle.uninstall() }
    #expect(try Data(contentsOf: settings) == drifted)
    #expect(FileManager.default.fileExists(atPath: lifecycle.backupURL.path))
  }

  @Test("Claude lifecycle reports a stable error when settings are missing")
  func claudeLifecycleMissingSettings() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appendingPathComponent("settings.json")
    let install = root.appendingPathComponent("quota-tempo")
    let lifecycle = ClaudeStatusLineLifecycle(
      settingsURL: settings,
      installationDirectory: install,
      bridgeExecutable: root.appendingPathComponent("bridge"),
      snapshotURL: root.appendingPathComponent("claude.json")
    )

    #expect(throws: ClaudeLifecycleError.missingSettings) {
      try lifecycle.activate(consent: true)
    }
    #expect(ClaudeLifecycleError.missingSettings.stableCode == "missing_settings")

    try Data("{}".utf8).write(to: settings)
    try lifecycle.activate(consent: true)
    try FileManager.default.removeItem(at: settings)
    #expect(throws: ClaudeLifecycleError.missingSettings) { try lifecycle.rollback() }
    #expect(throws: ClaudeLifecycleError.missingSettings) { try lifecycle.uninstall() }
    #expect(FileManager.default.fileExists(atPath: lifecycle.wrapperURL.path))
    #expect(FileManager.default.fileExists(atPath: lifecycle.backupURL.path))
  }

  @Test("Installed Claude wrapper rejects oversized input before forwarding")
  func claudeWrapperRejectsOversizedInput() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appendingPathComponent("settings.json")
    let install = root.appendingPathComponent("quota-tempo")
    let marker = root.appendingPathComponent("previous-invoked")
    let snapshot = root.appendingPathComponent("claude.json")
    let previous = "/usr/bin/touch '\(marker.path)'"
    let settingsData = try JSONSerialization.data(withJSONObject: [
      "statusLine": ["type": "command", "command": previous]
    ])
    try settingsData.write(to: settings)
    let lifecycle = ClaudeStatusLineLifecycle(
      settingsURL: settings,
      installationDirectory: install,
      bridgeExecutable: URL(fileURLWithPath: "/usr/bin/false"),
      snapshotURL: snapshot
    )
    try lifecycle.activate(consent: true)

    let result = try FoundationBoundedProcessRunner(timeout: 2, outputLimit: 1_024).run(
      executable: lifecycle.wrapperURL,
      arguments: [],
      stdin: Data(repeating: 0x41, count: ClaudeStatusLineBridge.maximumInputBytes + 1)
    )
    #expect(result.exitCode == 2)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(!FileManager.default.fileExists(atPath: snapshot.path))
  }

  @Test("Installed Claude wrapper forwards the exact bounded payload")
  func claudeWrapperForwardsExactPayload() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appendingPathComponent("settings.json")
    let install = root.appendingPathComponent("quota-tempo")
    let forwarded = root.appendingPathComponent("forwarded.json")
    let snapshot = root.appendingPathComponent("claude.json")
    let previous = "/bin/cat > '\(forwarded.path)'"
    let settingsData = try JSONSerialization.data(withJSONObject: [
      "statusLine": ["type": "command", "command": previous]
    ])
    try settingsData.write(to: settings)
    let lifecycle = ClaudeStatusLineLifecycle(
      settingsURL: settings,
      installationDirectory: install,
      bridgeExecutable: URL(fileURLWithPath: "/usr/bin/false"),
      snapshotURL: snapshot
    )
    try lifecycle.activate(consent: true)
    let payload = Data(#"{"rate_limits":{"seven_day":{"used_percentage":40}}}"#.utf8)

    let result = try FoundationBoundedProcessRunner(timeout: 5, outputLimit: 1_024).run(
      executable: lifecycle.wrapperURL,
      arguments: [],
      stdin: payload
    )

    #expect(result.exitCode == 0)
    #expect(try Data(contentsOf: forwarded) == payload)
  }

  @Test("Claude uninstall preserves unmanaged files in the installation directory")
  func claudeUninstallPreservesUnmanagedFiles() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appendingPathComponent("settings.json")
    let install = root.appendingPathComponent("quota-tempo")
    let bridge = root.appendingPathComponent("bridge")
    let unmanaged = install.appendingPathComponent("keep.txt")
    try Data("{}".utf8).write(to: settings)
    try Data().write(to: bridge)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: unmanaged)
    let lifecycle = ClaudeStatusLineLifecycle(
      settingsURL: settings,
      installationDirectory: install,
      bridgeExecutable: bridge,
      snapshotURL: root.appendingPathComponent("claude.json")
    )
    try lifecycle.activate(consent: true)
    try lifecycle.uninstall()
    #expect(FileManager.default.fileExists(atPath: unmanaged.path))
  }

  @Test("Claude activation rejects symlink-selected paths and rolls back write failure")
  func claudeLifecycleFailures() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real.json")
    let link = root.appendingPathComponent("settings.json")
    let bridge = root.appendingPathComponent("bridge")
    try Data("{}".utf8).write(to: real)
    try Data().write(to: bridge)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let unsafe = ClaudeStatusLineLifecycle(
      settingsURL: link,
      installationDirectory: root.appendingPathComponent("install"),
      bridgeExecutable: bridge,
      snapshotURL: root.appendingPathComponent("claude.json")
    )
    #expect(throws: ClaudeLifecycleError.unsafePath) { try unsafe.activate(consent: true) }

    try FileManager.default.removeItem(at: link)
    let original = Data("{\"theme\":\"dark\"}".utf8)
    try original.write(to: link)
    let failed = ClaudeStatusLineLifecycle(
      settingsURL: link,
      installationDirectory: root.appendingPathComponent("failed-install"),
      bridgeExecutable: bridge,
      snapshotURL: root.appendingPathComponent("claude.json"),
      writer: CountingFailWriter(failAt: 3)
    )
    #expect(throws: ClaudeLifecycleError.writeFailed) { try failed.activate(consent: true) }
    #expect(try Data(contentsOf: link) == original)
    #expect(!FileManager.default.fileExists(atPath: failed.wrapperURL.path))
  }

  private func snapshot(source: SnapshotSource) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: source == .claudeStatusLine ? .claude : .codex,
      source: source,
      capturedAt: self.now.addingTimeInterval(-600),
      weekly: QuotaWindow(
        remainingPercent: 60,
        durationSeconds: 604_800,
        resetAt: self.now.addingTimeInterval(300_000)
      ),
      sourceState: .observationSucceeded
    )
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("quota-tempo-tests-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static let codexResponse = BoundedProcessResult(
    stdout: Data(
      """
      {"id":1,"result":{"userAgent":"test"}}
      {"method":"account/rateLimits/updated","params":{}}
      {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1789308000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789905600}}}}
      """.utf8
    ),
    stderr: Data(),
    exitCode: 0
  )

  private func historyJSON(
    samples: [(Date, Double, Double)],
    organization: String = "ignored-org"
  ) -> Data {
    let rows = samples.map { sample in
      [
        "t": Int64(sample.0.timeIntervalSince1970 * 1_000),
        "org": organization,
        "u": ["fh": sample.1, "sd": sample.2],
      ] as [String: Any]
    }
    return try! JSONSerialization.data(withJSONObject: ["version": 2, "samples": rows])
  }

  private func cacheJSON(fetchedAt: Date, fiveHourUsed: Double, weeklyUsed: Double) -> Data {
    let formatter = ISO8601DateFormatter()
    return try! JSONSerialization.data(withJSONObject: [
      "cachedUsageUtilization": [
        "fetchedAtMs": Int64(fetchedAt.timeIntervalSince1970 * 1_000),
        "utilization": [
          "five_hour": [
            "utilization": fiveHourUsed,
            "resets_at": formatter.string(from: self.now.addingTimeInterval(10_000)),
          ],
          "seven_day": [
            "utilization": weeklyUsed,
            "resets_at": formatter.string(from: self.now.addingTimeInterval(300_000)),
          ],
        ],
      ]
    ])
  }

  private func claudeControlResponse() -> BoundedProcessResult {
    let formatter = ISO8601DateFormatter()
    let fiveHourReset = formatter.string(from: self.now.addingTimeInterval(10_000))
    let weeklyReset = formatter.string(from: self.now.addingTimeInterval(300_000))
    return BoundedProcessResult(
      stdout: Data(
        """
        {"type":"system","subtype":"init"}
        {"type":"control_response","response":{"request_id":"quota-tempo-usage","subtype":"success","response":{"rate_limits":{"five_hour":{"utilization":46,"resets_at":"\(fiveHourReset)"},"seven_day":{"utilization":43,"resets_at":"\(weeklyReset)"}}}}}
        """.utf8
      ),
      stderr: Data(),
      exitCode: 0
    )
  }
}

private struct FakeRunner: BoundedProcessRunning {
  let result: Result<BoundedProcessResult, BoundedProcessError>
  func run(
    executable: URL,
    arguments: [String],
    stdin: Data,
    currentDirectory: URL?
  ) throws -> BoundedProcessResult {
    try self.result.get()
  }
}

private final class ExecutableResultRunner: BoundedProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let results: [URL: Result<BoundedProcessResult, BoundedProcessError>]
  private(set) var invocations: [URL] = []

  init(results: [URL: Result<BoundedProcessResult, BoundedProcessError>]) {
    self.results = results
  }

  func run(
    executable: URL,
    arguments: [String],
    stdin: Data,
    currentDirectory: URL?
  ) throws -> BoundedProcessResult {
    self.lock.lock()
    self.invocations.append(executable)
    let result = self.results[executable]
    self.lock.unlock()
    guard let result else { throw BoundedProcessError.launchFailed }
    return try result.get()
  }
}

private final class RecordingRunner: BoundedProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<BoundedProcessResult, BoundedProcessError>
  private(set) var invocationCount = 0
  private(set) var lastExecutable: URL?
  private(set) var lastArguments: [String]?
  private(set) var lastStdin: Data?
  private(set) var lastCurrentDirectory: URL?
  private(set) var observedCurrentDirectoryExisted = false

  init(result: Result<BoundedProcessResult, BoundedProcessError>) {
    self.result = result
  }

  func run(
    executable: URL,
    arguments: [String],
    stdin: Data,
    currentDirectory: URL?
  ) throws -> BoundedProcessResult {
    self.lock.lock()
    self.invocationCount += 1
    self.lastExecutable = executable
    self.lastArguments = arguments
    self.lastStdin = stdin
    self.lastCurrentDirectory = currentDirectory
    self.observedCurrentDirectoryExisted =
      currentDirectory.map {
        FileManager.default.fileExists(atPath: $0.path)
      } ?? false
    self.lock.unlock()
    return try self.result.get()
  }
}

private struct FailingWriter: AtomicDataWriting {
  func write(_ data: Data, to url: URL) throws { throw TestFailure.expected }
}

private final class CountingFailWriter: AtomicDataWriting, @unchecked Sendable {
  private var count = 0
  private let failAt: Int
  private let lock = NSLock()
  init(failAt: Int) { self.failAt = failAt }
  func write(_ data: Data, to url: URL) throws {
    self.lock.lock()
    self.count += 1
    let shouldFail = self.count == self.failAt
    self.lock.unlock()
    if shouldFail { throw TestFailure.expected }
    try FileAtomicDataWriter().write(data, to: url)
  }
}

private enum TestFailure: Error { case expected }
