import Darwin
import Foundation
import Security

public struct BoundedProcessResult: Sendable, Equatable {
  public let stdout: Data
  public let stderr: Data
  public let exitCode: Int32

  public init(stdout: Data, stderr: Data, exitCode: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public enum BoundedProcessError: Error, Equatable {
  case timeout
  case outputLimitExceeded
  case launchFailed
  case inputWriteFailed
}

public protocol BoundedProcessRunning: Sendable {
  func run(
    executable: URL,
    arguments: [String],
    stdin: Data,
    currentDirectory: URL?
  ) throws -> BoundedProcessResult
}

extension BoundedProcessRunning {
  public func run(
    executable: URL,
    arguments: [String],
    stdin: Data
  ) throws -> BoundedProcessResult {
    try self.run(
      executable: executable,
      arguments: arguments,
      stdin: stdin,
      currentDirectory: nil
    )
  }
}

private final class ProcessCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stdout = Data()
  private var stderr = Data()
  private var exceeded = false
  private let limit: Int

  init(limit: Int) { self.limit = limit }

  func append(_ data: Data, stderr: Bool) -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    let remaining = max(self.limit + 1 - self.stdout.count - self.stderr.count, 0)
    let bounded = data.prefix(remaining)
    if stderr { self.stderr.append(bounded) } else { self.stdout.append(bounded) }
    self.exceeded = self.stdout.count + self.stderr.count > self.limit
    return self.exceeded
  }

  func result() -> (Data, Data, Bool) {
    self.lock.lock()
    defer { self.lock.unlock() }
    return (self.stdout, self.stderr, self.exceeded)
  }

}

private final class ProcessInputCloser: @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false

  func close(_ handle: FileHandle) {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard !self.closed else { return }
    self.closed = true
    try? handle.close()
  }

  func write(
    _ handle: FileHandle,
    from baseAddress: UnsafeRawPointer,
    count: Int
  ) -> Int? {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard !self.closed else { return nil }
    return Darwin.write(handle.fileDescriptor, baseAddress, count)
  }
}

final class RunningProcessRegistry: @unchecked Sendable {
  static let shared = RunningProcessRegistry()

  private let lock = NSLock()
  private var processes: [pid_t: Process] = [:]

  func register(_ process: Process) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.processes[process.processIdentifier] = process
  }

  func unregister(_ process: Process) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.processes.removeValue(forKey: process.processIdentifier)
  }

  func snapshot() -> [Process] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return Array(self.processes.values)
  }
}

private final class JSONResponseDetector {
  private let responseID: Int
  private var buffer = Data()
  private var lineStart = 0

  init(responseID: Int) {
    self.responseID = responseID
  }

  func append(_ data: Data) -> Bool {
    self.buffer.append(data)
    while lineStart < self.buffer.endIndex,
      let newline = self.buffer[lineStart...].firstIndex(of: 0x0A)
    {
      let line = self.buffer[self.lineStart..<newline]
      self.lineStart = self.buffer.index(after: newline)
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let responseID = object["id"] as? NSNumber
      else { continue }
      if responseID.intValue == self.responseID
        && (object["result"] != nil || object["error"] != nil)
      {
        return true
      }
    }
    if self.lineStart >= 65_536 {
      self.buffer.removeSubrange(self.buffer.startIndex..<self.lineStart)
      self.lineStart = 0
    }
    return false
  }
}

private final class ProcessPipeCollector: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.ishikawa.quotatempo.process-output")
  private let stdoutHandle: FileHandle
  private let stderrHandle: FileHandle
  private let capture: ProcessCapture
  private let inputCloser: ProcessInputCloser
  private let inputHandle: FileHandle
  private let closeInputAfterResponseID: Int?
  private let onOutputLimit: @Sendable () -> Void
  private let responseDetector: JSONResponseDetector?
  private var stdoutSource: DispatchSourceRead?
  private var stderrSource: DispatchSourceRead?
  private let finishLock = NSLock()
  private var finished = false

  init(
    stdoutHandle: FileHandle,
    stderrHandle: FileHandle,
    capture: ProcessCapture,
    inputCloser: ProcessInputCloser,
    inputHandle: FileHandle,
    closeInputAfterResponseID: Int?,
    onOutputLimit: @escaping @Sendable () -> Void
  ) {
    self.stdoutHandle = stdoutHandle
    self.stderrHandle = stderrHandle
    self.capture = capture
    self.inputCloser = inputCloser
    self.inputHandle = inputHandle
    self.closeInputAfterResponseID = closeInputAfterResponseID
    self.onOutputLimit = onOutputLimit
    self.responseDetector = closeInputAfterResponseID.map(JSONResponseDetector.init)
  }

  func start() -> Bool {
    guard
      Self.setNonBlocking(self.stdoutHandle.fileDescriptor),
      Self.setNonBlocking(self.stderrHandle.fileDescriptor)
    else { return false }

    let stdoutSource = DispatchSource.makeReadSource(
      fileDescriptor: self.stdoutHandle.fileDescriptor,
      queue: self.queue
    )
    let stderrSource = DispatchSource.makeReadSource(
      fileDescriptor: self.stderrHandle.fileDescriptor,
      queue: self.queue
    )
    stdoutSource.setEventHandler { [weak self] in self?.drain(stdout: true) }
    stderrSource.setEventHandler { [weak self] in self?.drain(stdout: false) }
    stdoutSource.setCancelHandler { [stdoutHandle = self.stdoutHandle] in
      try? stdoutHandle.close()
    }
    stderrSource.setCancelHandler { [stderrHandle = self.stderrHandle] in
      try? stderrHandle.close()
    }
    self.stdoutSource = stdoutSource
    self.stderrSource = stderrSource
    stdoutSource.resume()
    stderrSource.resume()
    return true
  }

  func finish() {
    self.finishLock.lock()
    guard !self.finished else {
      self.finishLock.unlock()
      return
    }
    self.finished = true
    self.finishLock.unlock()

    self.queue.sync {
      self.drain(stdout: true)
      self.drain(stdout: false)
      self.stdoutSource?.setEventHandler {}
      self.stderrSource?.setEventHandler {}
      self.stdoutSource?.cancel()
      self.stderrSource?.cancel()
      self.stdoutSource = nil
      self.stderrSource = nil
    }
  }

  private func drain(stdout: Bool) {
    let descriptor = stdout ? self.stdoutHandle.fileDescriptor : self.stderrHandle.fileDescriptor
    while true {
      var buffer = [UInt8](repeating: 0, count: 8_192)
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        if self.capture.append(Data(buffer.prefix(count)), stderr: !stdout) {
          self.onOutputLimit()
          return
        }
        if stdout, self.responseDetector?.append(Data(buffer.prefix(count))) == true {
          self.inputCloser.close(self.inputHandle)
        }
      } else if count == 0 {
        return
      } else if errno != EINTR {
        return
      }
    }
  }

  private static func setNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }
}

public struct FoundationBoundedProcessRunner: BoundedProcessRunning {
  public let timeout: TimeInterval
  public let outputLimit: Int
  public let closeInputAfterResponseID: Int?
  public let environmentOverrides: [String: String]
  public let terminationGrace: TimeInterval

  public init(
    timeout: TimeInterval = 5,
    outputLimit: Int = 1_048_576,
    closeInputAfterResponseID: Int? = nil,
    environmentOverrides: [String: String] = [:],
    terminationGrace: TimeInterval = 0.3
  ) {
    self.timeout = timeout
    self.outputLimit = outputLimit
    self.closeInputAfterResponseID = closeInputAfterResponseID
    self.environmentOverrides = environmentOverrides
    self.terminationGrace = terminationGrace
  }

  public func run(
    executable: URL,
    arguments: [String],
    stdin: Data,
    currentDirectory: URL?
  ) throws -> BoundedProcessResult {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let capture = ProcessCapture(limit: self.outputLimit)
    let inputCloser = ProcessInputCloser()
    let finished = DispatchSemaphore(value: 0)
    let deadline = DispatchTime.now() + self.timeout
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    guard Self.setNonBlocking(input.fileHandleForWriting.fileDescriptor) else {
      throw BoundedProcessError.launchFailed
    }

    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    let executableDirectory = executable.deletingLastPathComponent().path
    var environment = [
      "HOME": NSHomeDirectory(),
      "PATH": "\(executableDirectory):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "TMPDIR": NSTemporaryDirectory(),
      "LANG": "en_US.UTF-8",
    ]
    environment.merge(self.environmentOverrides) { _, override in override }
    process.environment = environment

    let collector = ProcessPipeCollector(
      stdoutHandle: output.fileHandleForReading,
      stderrHandle: errors.fileHandleForReading,
      capture: capture,
      inputCloser: inputCloser,
      inputHandle: input.fileHandleForWriting,
      closeInputAfterResponseID: self.closeInputAfterResponseID
    ) {
      if process.isRunning {
        Self.terminateTree(process, grace: self.terminationGrace)
      }
    }
    guard collector.start() else { throw BoundedProcessError.launchFailed }
    defer { collector.finish() }
    process.terminationHandler = { _ in finished.signal() }

    do { try process.run() } catch {
      inputCloser.close(input.fileHandleForWriting)
      throw BoundedProcessError.launchFailed
    }
    RunningProcessRegistry.shared.register(process)
    defer { RunningProcessRegistry.shared.unregister(process) }
    do {
      try Self.writeInput(
        stdin,
        to: input.fileHandleForWriting,
        until: deadline,
        process: process,
        inputCloser: inputCloser
      )
    } catch let error as BoundedProcessError {
      Self.terminateTree(process, grace: self.terminationGrace)
      inputCloser.close(input.fileHandleForWriting)
      _ = finished.wait(timeout: .now() + 1)
      throw error
    } catch {
      Self.terminateTree(process, grace: self.terminationGrace)
      inputCloser.close(input.fileHandleForWriting)
      _ = finished.wait(timeout: .now() + 1)
      throw BoundedProcessError.inputWriteFailed
    }
    if self.closeInputAfterResponseID == nil { inputCloser.close(input.fileHandleForWriting) }

    if finished.wait(timeout: deadline) == .timedOut {
      Self.terminateTree(process, grace: self.terminationGrace)
      inputCloser.close(input.fileHandleForWriting)
      _ = finished.wait(timeout: .now() + 1)
      throw BoundedProcessError.timeout
    }

    inputCloser.close(input.fileHandleForWriting)
    collector.finish()
    let captured = capture.result()
    if captured.2 { throw BoundedProcessError.outputLimitExceeded }
    return BoundedProcessResult(
      stdout: captured.0, stderr: captured.1, exitCode: process.terminationStatus)
  }

  private static func writeInput(
    _ data: Data,
    to handle: FileHandle,
    until deadline: DispatchTime,
    process: Process,
    inputCloser: ProcessInputCloser
  ) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        guard
          let written = inputCloser.write(
            handle,
            from: baseAddress.advanced(by: offset),
            count: bytes.count - offset
          )
        else { return }
        if written > 0 {
          offset += written
          continue
        }
        if written < 0, errno == EINTR { continue }
        if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          guard process.isRunning else { throw BoundedProcessError.inputWriteFailed }
          let now = DispatchTime.now().uptimeNanoseconds
          let end = deadline.uptimeNanoseconds
          guard now < end else { throw BoundedProcessError.timeout }
          let remainingMicroseconds = max(Int((end - now) / 1_000), 1)
          usleep(useconds_t(min(remainingMicroseconds, 5_000)))
          continue
        }
        throw BoundedProcessError.inputWriteFailed
      }
    }
  }

  private static func setNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }

  public static func terminateAllRunningProcesses() {
    for process in RunningProcessRegistry.shared.snapshot() {
      self.terminateTree(process, grace: 0.3)
    }
    FoundationClaudeUsagePTYProbe.cleanupRegisteredSessions()
  }

  static func terminateTree(_ process: Process, grace: TimeInterval) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    let descendants = Self.descendantPIDs(of: pid)
    for descendant in descendants { _ = kill(descendant, SIGTERM) }
    if process.isRunning { process.terminate() }

    let deadline = Date().addingTimeInterval(max(grace, 0))
    while process.isRunning && Date() < deadline {
      usleep(10_000)
    }

    let remaining = Set(descendants + Self.descendantPIDs(of: pid))
    for descendant in remaining where kill(descendant, 0) == 0 {
      _ = kill(descendant, SIGKILL)
    }
    if process.isRunning { _ = kill(pid, SIGKILL) }
  }

  static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    var pending = [rootPID]
    var seen = Set<pid_t>()
    while let parent = pending.popLast() {
      for child in self.directChildPIDs(of: parent) where seen.insert(child).inserted {
        result.append(child)
        pending.append(child)
      }
    }
    return result.reversed()
  }

  private static func directChildPIDs(of parentPID: pid_t) -> [pid_t] {
    let requiredBytes = proc_listchildpids(parentPID, nil, 0)
    guard requiredBytes > 0 else { return [] }
    var children = [pid_t](
      repeating: 0,
      count: Int(requiredBytes) / MemoryLayout<pid_t>.stride
    )
    let readBytes = children.withUnsafeMutableBytes { buffer in
      proc_listchildpids(parentPID, buffer.baseAddress, Int32(buffer.count))
    }
    guard readBytes > 0 else { return [] }
    return Array(children.prefix(Int(readBytes) / MemoryLayout<pid_t>.stride))
  }

}

public struct CodexExecutableCandidate: Equatable, Sendable {
  public let executable: URL
  public let source: CodexExecutableSource

  public init(executable: URL, source: CodexExecutableSource) {
    self.executable = executable
    self.source = source
  }
}

public enum CodexDesktopTrustVerifier {
  public static let expectedTeamIdentifier = "2DC432GLL2"
  public static let allowedBundleIdentifiers = Set(["com.openai.codex"])
  static let outerRequirement =
    #"anchor apple generic and identifier "com.openai.codex" and certificate leaf[subject.OU] = "2DC432GLL2""#
  static let nestedRequirement =
    #"anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2""#

  struct CodeIdentity: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
  }

  typealias RequirementEvaluator = @Sendable (URL, String, Bool) -> CodeIdentity?

  public static func isTrusted(bundleURL: URL, executableURL: URL) -> Bool {
    self.isTrusted(
      bundleURL: bundleURL,
      executableURL: executableURL,
      requirementEvaluator: self.evaluateRequirement
    )
  }

  static func isTrusted(
    bundleURL: URL,
    executableURL: URL,
    requirementEvaluator: RequirementEvaluator
  ) -> Bool {
    guard self.hasDirectNestedExecutable(bundleURL: bundleURL, executableURL: executableURL),
      let bundleInfo = requirementEvaluator(bundleURL, self.outerRequirement, true),
      self.allowedBundleIdentifiers.contains(bundleInfo.identifier),
      bundleInfo.teamIdentifier == self.expectedTeamIdentifier,
      let executableInfo = requirementEvaluator(executableURL, self.nestedRequirement, false),
      executableInfo.identifier == "codex",
      executableInfo.teamIdentifier == self.expectedTeamIdentifier
    else { return false }
    return true
  }

  static func hasDirectNestedExecutable(bundleURL: URL, executableURL: URL) -> Bool {
    let bundle = bundleURL.standardizedFileURL
    let expected = bundle.appendingPathComponent("Contents/Resources/codex").standardizedFileURL
    guard executableURL.standardizedFileURL == expected else { return false }

    let components = [
      bundle,
      bundle.appendingPathComponent("Contents", isDirectory: true),
      bundle.appendingPathComponent("Contents/Resources", isDirectory: true),
      expected,
    ]
    return components.allSatisfy { url in
      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }
  }

  private static func evaluateRequirement(
    at url: URL,
    requirementText: String,
    validateNestedCode: Bool
  ) -> CodeIdentity? {
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        == errSecSuccess,
      let requirement
    else { return nil }

    var validationFlags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
    if validateNestedCode { validationFlags |= kSecCSCheckNestedCode }
    guard
      SecStaticCodeCheckValidity(
        staticCode,
        SecCSFlags(rawValue: validationFlags),
        requirement
      ) == errSecSuccess
    else { return nil }

    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [String: Any],
      let identifier = values[kSecCodeInfoIdentifier as String] as? String,
      let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
    else { return nil }
    return CodeIdentity(identifier: identifier, teamIdentifier: teamIdentifier)
  }
}

public enum CodexCLIExecutableResolver {
  public static func resolveCandidates(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    applicationDirectories: [URL]? = nil,
    systemExecutables: [URL]? = nil,
    desktopTrustCheck: @Sendable (URL, URL) -> Bool = CodexDesktopTrustVerifier.isTrusted,
    fileManager: FileManager = .default
  ) -> [CodexExecutableCandidate] {
    var result: [CodexExecutableCandidate] = []
    let appRoots =
      applicationDirectories ?? [
        homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/Applications", isDirectory: true),
      ]
    for appRoot in appRoots {
      for appName in ["ChatGPT.app", "Codex.app"] {
        let bundle = appRoot.appendingPathComponent(appName, isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/Resources/codex")
        guard self.isUsable(executable, fileManager: fileManager),
          desktopTrustCheck(bundle, executable)
        else { continue }
        result.append(
          CodexExecutableCandidate(
            executable: executable.standardizedFileURL,
            source: .desktopBundled
          ))
      }
    }

    var userLocal = [
      homeDirectory.appendingPathComponent(".local/bin/codex"),
      homeDirectory.appendingPathComponent(".volta/bin/codex"),
      homeDirectory.appendingPathComponent(".asdf/shims/codex"),
    ]
    let nvmRoot = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
    if let versions = try? fileManager.contentsOfDirectory(
      at: nvmRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      userLocal.append(
        contentsOf: versions.sorted {
          $0.lastPathComponent.compare(
            $1.lastPathComponent,
            options: .numeric
          ) == .orderedDescending
        }.map { $0.appendingPathComponent("bin/codex") }
      )
    }
    result.append(
      contentsOf: self.usableCandidates(userLocal, source: .userLocal, fileManager: fileManager))

    let systemCandidates =
      systemExecutables ?? [
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
        URL(fileURLWithPath: "/usr/bin/codex"),
      ]
    for candidate in self.usableCandidates(
      systemCandidates,
      source: .packageManager,
      fileManager: fileManager
    ) {
      let source: CodexExecutableSource =
        candidate.executable.path == "/usr/bin/codex" ? .system : .packageManager
      result.append(CodexExecutableCandidate(executable: candidate.executable, source: source))
    }

    var seen = Set<URL>()
    return result.filter { seen.insert($0.executable).inserted }
  }

  public static func resolve(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    applicationDirectories: [URL]? = nil,
    systemExecutables: [URL]? = nil,
    desktopTrustCheck: @Sendable (URL, URL) -> Bool = CodexDesktopTrustVerifier.isTrusted,
    fileManager: FileManager = .default
  ) -> URL? {
    self.resolveCandidates(
      homeDirectory: homeDirectory,
      applicationDirectories: applicationDirectories,
      systemExecutables: systemExecutables,
      desktopTrustCheck: desktopTrustCheck,
      fileManager: fileManager
    ).first?.executable
  }

  private static func usableCandidates(
    _ urls: [URL],
    source: CodexExecutableSource,
    fileManager: FileManager
  ) -> [CodexExecutableCandidate] {
    urls.compactMap { candidate in
      guard self.isUsable(candidate, fileManager: fileManager) else { return nil }
      return CodexExecutableCandidate(
        executable: candidate.resolvingSymlinksInPath().standardizedFileURL,
        source: source
      )
    }
  }

  private static func isUsable(_ candidate: URL, fileManager: FileManager) -> Bool {
    guard fileManager.fileExists(atPath: candidate.path) else { return false }
    let resolved = candidate.resolvingSymlinksInPath()
    guard
      let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
      values.isRegularFile == true,
      fileManager.isExecutableFile(atPath: resolved.path)
    else { return false }
    return true
  }
}

public struct CodexSemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(_ value: String) {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      let major = Int(components[0]),
      let minor = Int(components[1]),
      let patch = Int(components[2]),
      major >= 0,
      minor >= 0,
      patch >= 0
    else { return nil }
    self.init(major: major, minor: minor, patch: patch)
  }

  public var description: String { "\(self.major).\(self.minor).\(self.patch)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  static func extract(from value: String) -> CodexSemanticVersion? {
    let pattern = #"(?<![0-9])([0-9]+)\.([0-9]+)\.([0-9]+)(?![0-9])"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ),
      let majorRange = Range(match.range(at: 1), in: value),
      let minorRange = Range(match.range(at: 2), in: value),
      let patchRange = Range(match.range(at: 3), in: value)
    else { return nil }
    guard
      (1...5).contains(value[majorRange].utf8.count),
      (1...5).contains(value[minorRange].utf8.count),
      (1...5).contains(value[patchRange].utf8.count),
      let major = Int(value[majorRange]),
      let minor = Int(value[minorRange]),
      let patch = Int(value[patchRange])
    else { return nil }
    return CodexSemanticVersion(
      major: major,
      minor: minor,
      patch: patch
    )
  }
}

private struct CodexCandidateFailure {
  let candidate: CodexExecutableCandidate
  let error: AcquisitionErrorCode
}

public struct CodexRateLimitAdapter: Sendable {
  public static let minimumRefreshInterval: TimeInterval = 5 * 60
  public static let maximumCandidateAttempts = 3
  public static let maximumKnownIncompatibleVersion = CodexSemanticVersion(
    major: 0, minor: 133, patch: 0)
  private let runner: any BoundedProcessRunning
  private let versionRunner: any BoundedProcessRunning
  private let candidates: [CodexExecutableCandidate]

  public init(
    runner: any BoundedProcessRunning = FoundationBoundedProcessRunner(
      closeInputAfterResponseID: 2),
    versionRunner: any BoundedProcessRunning = FoundationBoundedProcessRunner(
      timeout: 2,
      outputLimit: 4_096
    ),
    candidates: [CodexExecutableCandidate] = CodexCLIExecutableResolver.resolveCandidates()
  ) {
    self.runner = runner
    self.versionRunner = versionRunner
    self.candidates = Array(candidates.prefix(Self.maximumCandidateAttempts))
  }

  public init(
    runner: any BoundedProcessRunning,
    versionRunner: any BoundedProcessRunning = FoundationBoundedProcessRunner(
      timeout: 2,
      outputLimit: 4_096
    ),
    executable: URL?
  ) {
    self.init(
      runner: runner,
      versionRunner: versionRunner,
      candidates: executable.map {
        [CodexExecutableCandidate(executable: $0, source: .userLocal)]
      } ?? []
    )
  }

  public func refresh(previous: ProviderSnapshot?, now: Date) -> ProviderSnapshot {
    guard !self.candidates.isEmpty else {
      return self.failure(
        previous,
        now: now,
        state: .attemptFailed,
        error: .sourceNotInstalled,
        candidate: nil,
        version: nil
      )
    }

    var failures: [CodexCandidateFailure] = []
    for candidate in self.candidates {
      do {
        let result = try self.runner.run(
          executable: candidate.executable,
          arguments: ["app-server", "--stdio"],
          stdin: Self.protocolRequest
        )
        guard result.exitCode == 0 else {
          failures.append(CodexCandidateFailure(candidate: candidate, error: .temporaryFailure))
          continue
        }
        var snapshot = try self.decode(result.stdout, now: now)
        snapshot = ProviderSnapshot(
          provider: snapshot.provider,
          source: snapshot.source,
          capturedAt: snapshot.capturedAt,
          weekly: snapshot.weekly,
          fiveHour: snapshot.fiveHour,
          lastAttemptAt: snapshot.lastAttemptAt,
          sourceState: snapshot.sourceState,
          errorCode: snapshot.errorCode,
          codexExecutableSource: candidate.source
        )
        if snapshot.sourceState == .accessRestricted { return snapshot }
        return snapshot
      } catch BoundedProcessError.timeout {
        failures.append(CodexCandidateFailure(candidate: candidate, error: .timeout))
      } catch BoundedProcessError.outputLimitExceeded {
        failures.append(CodexCandidateFailure(candidate: candidate, error: .outputLimitExceeded))
      } catch BoundedProcessError.launchFailed {
        failures.append(CodexCandidateFailure(candidate: candidate, error: .launchFailed))
      } catch BoundedProcessError.inputWriteFailed {
        failures.append(CodexCandidateFailure(candidate: candidate, error: .temporaryFailure))
      } catch {
        failures.append(CodexCandidateFailure(candidate: candidate, error: .protocolIncompatible))
      }
    }

    let failure = failures.min { Self.failurePriority($0.error) < Self.failurePriority($1.error) }!
    let version = self.readVersion(failure.candidate.executable)
    let error: AcquisitionErrorCode
    if failure.error != .outputLimitExceeded,
      let parsed = version.flatMap(CodexSemanticVersion.init),
      parsed <= Self.maximumKnownIncompatibleVersion
    {
      error = .versionTooOld
    } else {
      error = failure.error
    }
    return self.failure(
      previous,
      now: now,
      state: error == .timeout ? .attemptTimedOut : .attemptFailed,
      error: error,
      candidate: failure.candidate,
      version: version
    )
  }

  public static func shouldRefresh(lastAttemptAt: Date?, now: Date) -> Bool {
    guard let lastAttemptAt else { return true }
    return now.timeIntervalSince(lastAttemptAt) >= self.minimumRefreshInterval
  }

  private func failure(
    _ previous: ProviderSnapshot?,
    now: Date,
    state: SourceState,
    error: AcquisitionErrorCode,
    candidate: CodexExecutableCandidate?,
    version: String?
  ) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: previous?.capturedAt,
      weekly: previous?.weekly,
      fiveHour: previous?.fiveHour,
      lastAttemptAt: now,
      sourceState: state,
      errorCode: error,
      codexExecutableSource: candidate?.source,
      codexExecutableVersion: candidate == nil ? nil : version
    )
  }

  private static func failurePriority(_ error: AcquisitionErrorCode) -> Int {
    switch error {
    case .outputLimitExceeded: 0
    case .timeout: 1
    case .launchFailed: 2
    case .protocolIncompatible: 3
    case .temporaryFailure: 4
    default: 5
    }
  }

  private func readVersion(_ executable: URL) -> String? {
    guard
      let result = try? self.versionRunner.run(
        executable: executable,
        arguments: ["--version"],
        stdin: Data()
      ),
      result.exitCode == 0
    else { return nil }
    let combined = result.stdout + result.stderr
    guard combined.count <= 4_096 else { return nil }
    let text = String(decoding: combined, as: UTF8.self)
    return CodexSemanticVersion.extract(from: text)?.description
  }

  private func decode(_ data: Data, now: Date) throws -> ProviderSnapshot {
    let lines = data.split(separator: 0x0A)
    let decoder = JSONDecoder()
    let response = lines.lazy.compactMap {
      try? decoder.decode(RPCResponse.self, from: Data($0))
    }
    .first { $0.id == 2 }
    guard let response, response.error == nil, let result = response.result else {
      throw AdapterError.invalidResponse
    }

    if result.ordinaryUsageAllowed == false {
      return Self.restrictedSnapshot(now: now)
    }

    let candidates = [result.rateLimitsByLimitId?["codex"], result.rateLimits].compactMap { $0 }
    for snapshot in candidates {
      do {
        if snapshot.spendControlReached == true || snapshot.rateLimitReachedType != nil {
          return Self.restrictedSnapshot(now: now)
        }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let weekly = try Self.window(windows, range: 8_640...11_520)
        let fiveHour = try Self.window(windows, range: 240...360)
        guard let weekly else { continue }
        return ProviderSnapshot(
          provider: .codex,
          source: .codexAppServer,
          capturedAt: now,
          weekly: weekly,
          fiveHour: fiveHour,
          lastAttemptAt: now,
          sourceState: .observationSucceeded
        )
      } catch AdapterError.invalidResponse {
        continue
      }
    }
    throw AdapterError.invalidResponse
  }

  private static func restrictedSnapshot(now: Date) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: now,
      weekly: nil,
      fiveHour: nil,
      lastAttemptAt: now,
      sourceState: .accessRestricted,
      errorCode: .usageRestricted
    )
  }

  private static func window(_ windows: [RPCWindow], range: ClosedRange<Int>) throws -> QuotaWindow?
  {
    guard
      let value = windows.first(where: { window in
        guard let duration = window.windowDurationMins else { return false }
        return range.contains(duration)
      })
    else { return nil }
    guard (0...100).contains(value.usedPercent), let duration = value.windowDurationMins,
      let reset = value.resetsAt
    else { throw AdapterError.invalidResponse }
    return QuotaWindow(
      remainingPercent: Double(100 - value.usedPercent),
      durationSeconds: Double(duration * 60),
      resetAt: Date(timeIntervalSince1970: Double(reset))
    )
  }

  static let protocolRequest = Data(
    """
    {"method":"initialize","id":1,"params":{"clientInfo":{"name":"quota_tempo","title":"QuotaTempo","version":"0.1.4"},"capabilities":{"optOutNotificationMethods":["account/rateLimits/updated"]}}}
    {"method":"initialized"}
    {"method":"account/rateLimits/read","id":2}

    """.utf8
  )
}

private enum AdapterError: Error { case invalidResponse }

private struct RPCResponse: Decodable {
  let id: Int?
  let result: RPCResult?
  let error: RPCError?
}

private struct RPCError: Decodable { let code: Int? }

private struct RPCResult: Decodable {
  let rateLimits: RPCRateLimits?
  let rateLimitsByLimitId: [String: RPCRateLimits]?
  let ordinaryUsageAllowed: Bool?
}

private struct RPCRateLimits: Decodable {
  let primary: RPCWindow?
  let secondary: RPCWindow?
  let rateLimitReachedType: String?
  let spendControlReached: Bool?
}

private struct RPCWindow: Decodable {
  let usedPercent: Int
  let windowDurationMins: Int?
  let resetsAt: Int64?
}
