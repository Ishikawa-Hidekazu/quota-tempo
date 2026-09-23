import Darwin
import Foundation

public protocol ClaudeUsageProbing: Sendable {
  func capture(executable: URL, workingDirectory: URL) throws -> Data
}

public enum ClaudeUsagePTYProbeError: Error, Equatable, Sendable {
  case timeout(stage: Stage)
  case authenticationRequired

  public enum Stage: String, Equatable, Sendable {
    case noOutput
    case startupOnly
    case usageSent
    case usageLabelSeen
    case resetLabelSeen
    case startupPromptSeen
    case commandPaletteSeen
    case authPromptSeen
    case cliErrorSeen
    case cursorQuerySeen
    case safetyDialogSeen
    case safetyMoveSent
    case safetyAccepted
    case normalPromptSeen
    case usageSentAfterSafety
    case usageSentWithoutSafety
    case unsupportedOption
    case sessionConflict
    case usageLoadFailed
  }
}

final class ClaudeSessionArtifactRegistry: @unchecked Sendable {
  static let shared = ClaudeSessionArtifactRegistry()

  private let lock = NSLock()
  private var sessions: [String: (URL, URL)] = [:]

  func register(_ id: String, directory: URL, projectsDirectory: URL) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.sessions[id] = (directory, projectsDirectory)
  }

  func unregister(_ id: String) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.sessions.removeValue(forKey: id)
  }

  func snapshot() -> [(String, URL, URL)] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.sessions.map { ($0.key, $0.value.0, $0.value.1) }
  }
}

public struct FoundationClaudeUsagePTYProbe: ClaudeUsageProbing {
  public let timeout: TimeInterval
  public let outputLimit: Int
  private let registerForShutdown: Bool
  private let sessionProjectsDirectory: URL

  public init(timeout: TimeInterval = 40, outputLimit: Int = 1_048_576) {
    self.timeout = timeout
    self.outputLimit = outputLimit
    self.registerForShutdown = true
    self.sessionProjectsDirectory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects", isDirectory: true)
  }

  init(
    timeout: TimeInterval,
    outputLimit: Int = 1_048_576,
    registerForShutdown: Bool,
    sessionProjectsDirectory: URL? = nil
  ) {
    self.timeout = timeout
    self.outputLimit = outputLimit
    self.registerForShutdown = registerForShutdown
    self.sessionProjectsDirectory =
      sessionProjectsDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects", isDirectory: true)
  }

  public func capture(executable: URL, workingDirectory: URL) throws -> Data {
    let manager = FileManager.default
    guard !LocalPathSafety.containsSymlink(atOrAbove: workingDirectory, fileManager: manager) else {
      throw ClaudeAutomaticAdapterError.unsafePath
    }
    guard
      !LocalPathSafety.containsSymlink(
        atOrAbove: self.sessionProjectsDirectory, fileManager: manager),
      Self.isOwnedDirectoryIfPresent(self.sessionProjectsDirectory)
    else { throw ClaudeAutomaticAdapterError.unsafePath }
    try manager.createDirectory(
      at: workingDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    var directoryStat = stat()
    guard lstat(workingDirectory.path, &directoryStat) == 0,
      directoryStat.st_uid == geteuid(),
      directoryStat.st_mode & 0o777 == 0o700,
      try manager.contentsOfDirectory(atPath: workingDirectory.path).isEmpty
    else { throw ClaudeAutomaticAdapterError.unsafePath }

    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else {
      throw BoundedProcessError.launchFailed
    }
    let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    defer {
      try? masterHandle.close()
      try? slaveHandle.close()
    }
    let flags = fcntl(master, F_GETFL)
    guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw BoundedProcessError.launchFailed
    }

    let sessionID = UUID().uuidString.lowercased()
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "--allowed-tools", "", "--tools", "", "--setting-sources", "", "--strict-mcp-config",
      "--no-chrome", "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#,
      "--session-id", sessionID,
    ]
    process.currentDirectoryURL = workingDirectory
    process.standardInput = slaveHandle
    process.standardOutput = slaveHandle
    process.standardError = slaveHandle
    var environment = [
      "HOME": NSHomeDirectory(),
      "PATH":
        "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "TMPDIR": NSTemporaryDirectory(),
      "TERM": "xterm-256color",
      "LANG": "en_US.UTF-8",
      "DISABLE_AUTOUPDATER": "1",
      "PWD": workingDirectory.path,
    ]
    for key in [
      "USER", "LOGNAME", "SHELL", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "COLORTERM",
      "TERM_PROGRAM",
    ] {
      if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
    }
    process.environment = environment
    ClaudeSessionArtifactRegistry.shared.register(
      sessionID,
      directory: workingDirectory,
      projectsDirectory: self.sessionProjectsDirectory
    )
    do { try process.run() } catch {
      ClaudeSessionArtifactRegistry.shared.unregister(sessionID)
      throw BoundedProcessError.launchFailed
    }
    _ = setpgid(process.processIdentifier, process.processIdentifier)
    let processGroup =
      getpgid(process.processIdentifier) == process.processIdentifier
      ? process.processIdentifier : nil
    if self.registerForShutdown { RunningProcessRegistry.shared.register(process) }
    defer {
      Self.requestExit(process, descriptor: master)
      Self.stop(process, group: processGroup)
      if self.registerForShutdown { RunningProcessRegistry.shared.unregister(process) }
      Self.cleanupSession(
        sessionID,
        in: workingDirectory,
        projectsDirectory: self.sessionProjectsDirectory
      )
      ClaudeSessionArtifactRegistry.shared.unregister(sessionID)
    }

    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(self.timeout)
    var output = Data()
    var scanTail = ""
    var sentUsage = false
    var retriedUsage = false
    var sentTrust = false
    var sentStartupPrompt = false
    var safetyDialogSeenAt: Date?
    var safetyMoveSentAt: Date?
    var safetyMoveOutputCount: Int?
    var safetyMoveAttemptCount = 0
    var safetyInitiallySelectedYes = false
    var safetyAccepted = false
    var normalPromptSeen = false
    var sentPalette = false
    var answeredCursorQuery = false
    var panelSeenAt: Date?
    var chunk = [UInt8](repeating: 0, count: 16_384)

    while Date() < deadline {
      let count = read(master, &chunk, chunk.count)
      if count > 0 {
        guard output.count + count <= self.outputLimit else {
          throw BoundedProcessError.outputLimitExceeded
        }
        output.append(contentsOf: chunk.prefix(count))
        scanTail = String(
          (scanTail + String(decoding: chunk.prefix(count), as: UTF8.self)).suffix(16_384))
        let normalized = Self.normalizedVisibleText(scanTail)
        if Self.isAuthenticationPrompt(normalized) {
          throw ClaudeUsagePTYProbeError.authenticationRequired
        }
        if !answeredCursorQuery, scanTail.contains("\u{001B}[6n") {
          try Self.send("\u{001B}[1;1R", to: master)
          answeredCursorQuery = true
        }
        if !sentTrust, normalized.contains("doyoutrustthefilesinthisfolder?") {
          try Self.send("y\r", to: master)
          sentTrust = true
          scanTail = ""
        }
        if !sentStartupPrompt,
          normalized.contains("readytocodehere?") || normalized.contains("pressentertocontinue")
        {
          try Self.send("\r", to: master)
          sentStartupPrompt = true
          scanTail = ""
        }
        if safetyDialogSeenAt == nil,
          normalized.contains("quicksafetycheck:"),
          normalized.contains("no,exit"),
          normalized.contains("yes,itrustthisfolder")
        {
          safetyDialogSeenAt = Date()
          safetyInitiallySelectedYes = Self.safetyYesIsSelected(scanTail)
        }
        if let moveOutputCount = safetyMoveOutputCount,
          output.count > moveOutputCount,
          Self.safetyYesIsSelected(scanTail)
        {
          try Self.send("\r", to: master)
          safetyAccepted = true
          safetyMoveOutputCount = nil
          scanTail = ""
        }
        if !normalPromptSeen,
          safetyMoveSentAt == nil || safetyAccepted,
          Self.isNormalPrompt(scanTail)
        {
          normalPromptSeen = true
        }
        if sentUsage, !sentPalette,
          normalized.contains("showplanusagelimits")
        {
          try Self.send("\r", to: master)
          sentPalette = true
        }
        if Self.hasCompleteUsagePanel(normalized) {
          panelSeenAt = panelSeenAt ?? Date()
        }
      } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
        break
      }

      if let seenAt = safetyDialogSeenAt,
        safetyMoveSentAt == nil,
        !safetyAccepted,
        Date().timeIntervalSince(seenAt) >= 0.4
      {
        if safetyInitiallySelectedYes {
          try Self.send("\r", to: master)
          safetyAccepted = true
          scanTail = ""
        } else {
          try Self.send("\u{001B}[B", to: master)
          safetyMoveSentAt = Date()
          safetyMoveOutputCount = output.count
          safetyMoveAttemptCount = 1
          scanTail = ""
        }
      } else if let sentAt = safetyMoveSentAt,
        !safetyAccepted,
        safetyMoveAttemptCount == 1,
        output.count == safetyMoveOutputCount,
        Date().timeIntervalSince(sentAt) >= 1.5
      {
        try Self.send("\u{001B}[B", to: master)
        safetyMoveSentAt = Date()
        safetyMoveOutputCount = output.count
        safetyMoveAttemptCount = 2
        scanTail = ""
      }
      if !sentUsage, normalPromptSeen {
        try Self.send("/usage\r", to: master)
        sentUsage = true
      } else if sentUsage, !retriedUsage,
        Date().timeIntervalSince(startedAt) >= 12,
        panelSeenAt == nil,
        !Self.normalizedVisibleText(scanTail).contains("currentsession")
      {
        try Self.send("\u{001B}/usage\r", to: master)
        retriedUsage = true
      }
      if let panelSeenAt, Date().timeIntervalSince(panelSeenAt) >= 1.5 { break }
      if !process.isRunning { break }
      usleep(20_000)
    }
    guard panelSeenAt != nil else {
      let normalized = Self.normalizedVisibleText(scanTail)
      let stage: ClaudeUsagePTYProbeError.Stage
      if safetyDialogSeenAt != nil, safetyMoveSentAt == nil {
        stage = .safetyDialogSeen
      } else if safetyMoveSentAt != nil, !safetyAccepted {
        stage = .safetyMoveSent
      } else if safetyAccepted, !normalPromptSeen {
        stage = .safetyAccepted
      } else if normalPromptSeen, !sentUsage {
        stage = .normalPromptSeen
      } else if normalized.contains("error") || normalized.contains("failed") {
        if normalized.contains("unknownoption") || normalized.contains("unknownargument")
          || normalized.contains("invalidoption")
        {
          stage = .unsupportedOption
        } else if normalized.contains("session")
          && (normalized.contains("inuse") || normalized.contains("alreadyexists"))
        {
          stage = .sessionConflict
        } else if normalized.contains("failedtoloadusagedata")
          || normalized.contains("unabletoloadusage")
        {
          stage = .usageLoadFailed
        } else if sentUsage {
          stage = safetyAccepted ? .usageSentAfterSafety : .usageSentWithoutSafety
        } else {
          stage = .cliErrorSeen
        }
      } else if normalized.contains("resets") {
        stage = .resetLabelSeen
      } else if normalized.contains("currentweek") || normalized.contains("currentsession") {
        stage = .usageLabelSeen
      } else if normalized.contains("signin") || normalized.contains("login") {
        stage = .authPromptSeen
      } else if normalized.contains("showplan") {
        stage = .commandPaletteSeen
      } else if sentTrust || sentStartupPrompt || safetyDialogSeenAt != nil {
        stage = .startupPromptSeen
      } else if answeredCursorQuery {
        stage = .cursorQuerySeen
      } else if sentUsage {
        stage = .usageSent
      } else if !output.isEmpty {
        stage = .startupOnly
      } else {
        stage = .noOutput
      }
      throw ClaudeUsagePTYProbeError.timeout(stage: stage)
    }
    return output
  }

  private static func hasCompleteUsagePanel(_ normalized: String) -> Bool {
    guard let weeklyRange = normalized.range(of: "currentweek(allmodels)") else { return false }
    let weekly = normalized[weeklyRange.lowerBound..<normalized.endIndex]
    return weekly.contains("%used") && weekly.contains("resets")
  }

  private static func send(_ text: String, to descriptor: Int32) throws {
    for byte in text.utf8 {
      var value = byte
      let written = Darwin.write(descriptor, &value, 1)
      guard written == 1 else { throw BoundedProcessError.inputWriteFailed }
    }
  }

  private static func normalizedVisibleText(_ text: String) -> String {
    ClaudeUsageTextParser.stripTerminalSequences(text).lowercased().filter { !$0.isWhitespace }
  }

  private static func isAuthenticationPrompt(_ normalized: String) -> Bool {
    [
      "selectloginmethod", "pleaselogin", "pleasesignin", "notloggedin", "pastecode",
      "authenticationrequired", "continuewithclaudeaccount",
    ].contains { normalized.contains($0) }
  }

  private static func safetyYesIsSelected(_ text: String) -> Bool {
    let lines = ClaudeUsageTextParser.stripTerminalSequences(text).lowercased()
      .split(whereSeparator: { $0.isNewline })
    guard let selected = lines.last(where: { $0.contains("❯") || $0.contains(">") }) else {
      return false
    }
    let normalized = selected.filter { !$0.isWhitespace }
    return normalized.contains("❯yes,itrustthisfolder")
      || normalized.contains(">yes,itrustthisfolder")
  }

  private static func isNormalPrompt(_ text: String) -> Bool {
    let visible = ClaudeUsageTextParser.stripTerminalSequences(text).lowercased()
    guard !visible.contains("quick safety check"),
      !visible.contains("do you trust the files in this folder"),
      !visible.contains("select login method"),
      !visible.contains("select a theme"),
      !visible.contains("choose a theme"),
      !visible.contains("choose the text style"),
      !visible.contains("which text style")
    else { return false }
    return visible.contains("❯") || visible.contains("\n> ") || visible.hasSuffix("> ")
  }

  private static func requestExit(_ process: Process, descriptor: Int32) {
    guard process.isRunning else { return }
    try? self.send("\u{001B}/exit\r", to: descriptor)
    let deadline = Date().addingTimeInterval(0.5)
    while process.isRunning && Date() < deadline { usleep(10_000) }
  }

  private static func stop(_ process: Process, group: pid_t?) {
    if let group {
      _ = kill(-group, SIGTERM)
    } else if process.isRunning {
      FoundationBoundedProcessRunner.terminateTree(process, grace: 0.3)
    }
    usleep(100_000)
    if let group { _ = kill(-group, SIGKILL) }
    process.waitUntilExit()
  }

  private static func isOwnedDirectoryIfPresent(_ directory: URL) -> Bool {
    var directoryStat = stat()
    if lstat(directory.path, &directoryStat) != 0 { return errno == ENOENT }
    return directoryStat.st_uid == geteuid() && directoryStat.st_mode & S_IFMT == S_IFDIR
  }

  private static func cleanupSession(
    _ id: String,
    in directory: URL,
    projectsDirectory: URL
  ) {
    let name = directory.path.precomposedStringWithCanonicalMapping.utf16.map { unit -> Character in
      switch unit {
      case 48...57, 65...90, 97...122: Character(UnicodeScalar(unit)!)
      default: "-"
      }
    }
    let project =
      projectsDirectory
      .appendingPathComponent(String(name), isDirectory: true)
    let artifact = project.appendingPathComponent("\(id).jsonl")
    guard !LocalPathSafety.containsSymlink(atOrAbove: artifact, fileManager: .default),
      (try? artifact.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { return }
    try? FileManager.default.removeItem(at: artifact)
  }

  static func cleanupRegisteredSessions() {
    for (id, directory, projectsDirectory) in ClaudeSessionArtifactRegistry.shared.snapshot() {
      self.cleanupSession(id, in: directory, projectsDirectory: projectsDirectory)
      ClaudeSessionArtifactRegistry.shared.unregister(id)
    }
  }
}
