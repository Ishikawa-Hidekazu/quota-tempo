import Foundation
import QuotaTempoCore

enum CommandError: Error { case usage }

func value(after flag: String, in arguments: [String]) throws -> String {
  guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
    throw CommandError.usage
  }
  return arguments[index + 1]
}

func lifecycle(_ arguments: [String]) throws -> ClaudeStatusLineLifecycle {
  ClaudeStatusLineLifecycle(
    settingsURL: URL(fileURLWithPath: try value(after: "--settings", in: arguments)),
    installationDirectory: URL(fileURLWithPath: try value(after: "--install-dir", in: arguments)),
    bridgeExecutable: URL(fileURLWithPath: try value(after: "--bridge", in: arguments)),
    snapshotURL: URL(fileURLWithPath: try value(after: "--output", in: arguments))
  )
}

func boundedStdin(limit: Int) throws -> Data {
  try BoundedInputReader.read(from: .standardInput, limit: limit)
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else { throw CommandError.usage }
  switch command {
  case "refresh-codex":
    let output = URL(fileURLWithPath: try value(after: "--output", in: arguments))
    let previous = try? NormalizedSnapshotStore.load(from: output, expectedProvider: .codex)
    let snapshot = CodexRateLimitAdapter().refresh(previous: previous, now: Date())
    try FileAtomicDataWriter().write(try NormalizedSnapshotCodec.encode(snapshot), to: output)
    if snapshot.sourceState != .observationSucceeded { exit(3) }
  case "refresh-claude":
    let output = URL(fileURLWithPath: try value(after: "--output", in: arguments))
    let previous = try? NormalizedSnapshotStore.load(from: output, expectedProvider: .claude)
    let snapshot = ClaudeAutomaticAdapter(ptyProbeEnabled: true).refresh(
      previous: previous, now: Date(), forceLiveProbe: arguments.contains("--force-pty")
    )
    try FileAtomicDataWriter().write(try NormalizedSnapshotCodec.encode(snapshot), to: output)
    if snapshot.sourceState != .observationSucceeded { exit(3) }
  case "diagnose-claude-pty":
    guard let executable = ClaudeCLIExecutableResolver.resolve() else {
      print(#"{"stage":"cliMissing"}"#)
      exit(3)
    }
    let freshDirectory = arguments.contains("--fresh-directory")
    let directory =
      freshDirectory
      ? FileManager.default.temporaryDirectory.appendingPathComponent(
        "QuotaTempoClaudeProbe-Fresh-\(UUID().uuidString)", isDirectory: true)
      : FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      )[0].appendingPathComponent("QuotaTempo/ClaudeProbe", isDirectory: true)
    defer {
      if freshDirectory { try? FileManager.default.removeItem(at: directory) }
    }
    do {
      let output = try FoundationClaudeUsagePTYProbe().capture(
        executable: executable, workingDirectory: directory
      )
      let parsed = ClaudeUsageTextParser.parse(output, now: Date())
      print(
        "{\"stage\":\"panelCaptured\",\"capturedBytes\":\(output.count),\"weeklyExactResetPresent\":\(parsed?.weekly?.resetAt != nil),\"fiveHourExactResetPresent\":\(parsed?.fiveHour?.resetAt != nil)}"
      )
    } catch let error as ClaudeUsagePTYProbeError {
      switch error {
      case .timeout(let stage): print("{\"stage\":\"\(stage.rawValue)\"}")
      case .authenticationRequired: print(#"{"stage":"authenticationRequired"}"#)
      }
      exit(3)
    }
  case "ingest-claude":
    let output = URL(fileURLWithPath: try value(after: "--output", in: arguments))
    let snapshot = try ClaudeStatusLineBridge.normalize(
      boundedStdin(limit: ClaudeStatusLineBridge.maximumInputBytes),
      receivedAt: Date()
    )
    try FileAtomicDataWriter().write(try NormalizedSnapshotCodec.encode(snapshot), to: output)
  case "claude-activate":
    try lifecycle(arguments).activate(consent: arguments.contains("--consent"))
  case "claude-status":
    print(try lifecycle(arguments).status().rawValue)
  case "claude-rollback":
    try lifecycle(arguments).rollback()
  case "claude-uninstall":
    try lifecycle(arguments).uninstall()
  default:
    throw CommandError.usage
  }
} catch {
  let code =
    (error as? ClaudeBridgeError)?.stableCode
    ?? (error as? ClaudeLifecycleError)?.stableCode
    ?? "command_failed"
  FileHandle.standardError.write(Data("{\"error\":\"\(code)\"}\n".utf8))
  exit(2)
}
