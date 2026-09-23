import Darwin
import Foundation
import Testing

@testable import QuotaTempoCore

struct ClaudeUsagePTYProbeTests {
  @Test("PTY probe sends usage and captures only a bounded panel")
  func capturesUsage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("claude")
    let exitMarker = root.appendingPathComponent("exit-requested")
    let script = """
      #!/bin/sh
      printf 'Claude Code\\r\\n❯ '
      while IFS= read -r input; do
        case "$input" in
          *"/usage"*)
            printf 'Current session\\r\\n43%% used\\r\\nResets Sep 22, 2026 at 11:00 PM\\r\\nCurrent week (all models)\\r\\n12%% used\\r\\nResets Sep 29, 2026 at 5:00 AM\\r\\n'
            ;;
          *"/exit"*)
            touch "\(exitMarker.path)"
            exit 0
            ;;
        esac
      done
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    let captured = try FoundationClaudeUsagePTYProbe(timeout: 12, registerForShutdown: false)
      .capture(
        executable: fake,
        workingDirectory: root.appendingPathComponent("probe")
      )
    let text = String(decoding: captured, as: UTF8.self)
    #expect(text.contains("Current week (all models)"))
    #expect(text.contains("Resets Sep 29, 2026"))
    #expect(FileManager.default.fileExists(atPath: exitMarker.path))
  }

  @Test("PTY probe waits for the delayed weekly values and reset")
  func waitsForDelayedWeeklyPanel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("claude")
    let script = """
      #!/bin/sh
      printf 'Claude Code\r\n❯ '
      while IFS= read -r input; do
        case "$input" in
          *"/usage"*)
            printf 'Current session\r\n43%% used\r\nResets 2026-09-23T23:00:00Z\r\nCurrent week (all models)\r\n'
            sleep 2
            printf '12%% used\r\nResets 2026-09-29T05:00:00Z\r\n'
            ;;
          *"/exit"*) exit 0 ;;
        esac
      done
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    let captured = try FoundationClaudeUsagePTYProbe(timeout: 12, registerForShutdown: false)
      .capture(executable: fake, workingDirectory: root.appendingPathComponent("probe"))
    let text = String(decoding: captured, as: UTF8.self)
    #expect(text.contains("12% used"))
    #expect(text.contains("Resets 2026-09-29"))
  }

  @Test("PTY probe accepts a complete weekly panel when session usage is unavailable")
  func capturesWeeklyOnlyPanel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("claude")
    let script = """
      #!/bin/sh
      printf 'Claude Code\r\n❯ '
      while IFS= read -r input; do
        case "$input" in
          *"/usage"*)
            printf 'Current session\r\nCurrent week (all models)\r\n12%% used\r\nResets 2026-09-29T05:00:00Z\r\n'
            ;;
          *"/exit"*) exit 0 ;;
        esac
      done
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    let captured = try FoundationClaudeUsagePTYProbe(timeout: 12, registerForShutdown: false)
      .capture(executable: fake, workingDirectory: root.appendingPathComponent("probe"))
    let text = String(decoding: captured, as: UTF8.self)
    #expect(text.contains("Current week (all models)"))
    #expect(text.contains("Resets 2026-09-29"))
  }

  @Test("PTY probe selects Yes in the safety dialog before sending usage")
  func acceptsSafetyDialog() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("claude")
    let inputMarker = root.appendingPathComponent("input")
    let script = """
      #!/bin/sh
      printf 'Quick safety check:\\r\\n❯ No, exit\\r\\n  Yes, I trust this folder\\r\\n'
      stty raw -echo
      keys=$(dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -d ' \\n')
      printf '%s' "$keys" > "\(inputMarker.path)"
      [ "$keys" = "1b5b42" ] || exit 21
      printf '\\r\\n  No, exit\\r\\n❯ Yes, I trust this folder\\r\\n'
      dd bs=1 count=1 of=/dev/null 2>/dev/null
      stty sane
      printf '\\033[2JClaude Code\\r\\n❯ '
      while IFS= read -r input; do
        case "$input" in
          *"/usage"*)
            printf 'Current session\\r\\n43%% used\\r\\nResets 2026-09-22T23:00:00Z\\r\\nCurrent week (all models)\\r\\n12%% used\\r\\nResets 2026-09-29T05:00:00Z\\r\\n'
            ;;
          *"/exit"*) exit 0 ;;
        esac
      done
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    let captured = try FoundationClaudeUsagePTYProbe(timeout: 12, registerForShutdown: false)
      .capture(executable: fake, workingDirectory: root.appendingPathComponent("probe"))
    #expect(String(decoding: captured, as: UTF8.self).contains("Current week (all models)"))
    #expect(try String(contentsOf: inputMarker, encoding: .utf8) == "1b5b42")
  }

  @Test("PTY probe accepts a safety dialog whose Yes option is already selected")
  func acceptsInitiallySelectedYes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("claude")
    let inputMarker = root.appendingPathComponent("input")
    let script = """
      #!/bin/sh
      printf 'Quick safety check:\r\n  No, exit\r\n❯ Yes, I trust this folder\r\n'
      stty raw -echo
      key=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
      printf '%s' "$key" > "\(inputMarker.path)"
      [ "$key" = "0d" ] || exit 21
      stty sane
      printf '\033[2JClaude Code\r\n❯ '
      while IFS= read -r input; do
        case "$input" in
          *"/usage"*)
            printf 'Current session\r\n43%% used\r\nResets 2026-09-22T23:00:00Z\r\nCurrent week (all models)\r\n12%% used\r\nResets 2026-09-29T05:00:00Z\r\n'
            ;;
          *"/exit"*) exit 0 ;;
        esac
      done
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    let captured = try FoundationClaudeUsagePTYProbe(timeout: 12, registerForShutdown: false)
      .capture(executable: fake, workingDirectory: root.appendingPathComponent("probe"))
    #expect(String(decoding: captured, as: UTF8.self).contains("Current week (all models)"))
    #expect(try String(contentsOf: inputMarker, encoding: .utf8) == "0d")
  }

  @Test("PTY probe does not treat an onboarding theme choice as the normal prompt")
  func rejectsThemeSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("claude")
    let script = """
      #!/bin/sh
      printf 'Claude Code\r\nSelect a theme\r\n❯ Dark mode\r\n  Light mode\r\n'
      sleep 5
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    do {
      _ = try FoundationClaudeUsagePTYProbe(timeout: 1, registerForShutdown: false).capture(
        executable: fake, workingDirectory: root.appendingPathComponent("probe"))
      Issue.record("Expected the onboarding choice to time out")
    } catch ClaudeUsagePTYProbeError.timeout(let stage) {
      #expect(stage == .startupOnly || stage == .noOutput)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("PTY probe times out rather than treating startup as quota")
  func timesOutWithoutPanel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = root.appendingPathComponent("claude")
    try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    #expect(throws: ClaudeUsagePTYProbeError.timeout(stage: .noOutput)) {
      try FoundationClaudeUsagePTYProbe(timeout: 1, registerForShutdown: false).capture(
        executable: fake,
        workingDirectory: root.appendingPathComponent("probe")
      )
    }
  }

  @Test("Authentication prompt aborts without sending input")
  func stopsAtAuthentication() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("input")
    let fake = root.appendingPathComponent("claude")
    let script = """
      #!/bin/sh
      printf 'Select login method\\r\\n'
      dd bs=1 count=64 of="\(input.path)" 2>/dev/null
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    #expect(throws: ClaudeUsagePTYProbeError.authenticationRequired) {
      try FoundationClaudeUsagePTYProbe(timeout: 5, registerForShutdown: false).capture(
        executable: fake, workingDirectory: root.appendingPathComponent("probe"))
    }
    let received = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
    #expect(!received.contains("/usage"))
  }

  @Test("A nonempty working directory is never auto-trusted")
  func rejectsNonemptyDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = root.appendingPathComponent("probe")
    try FileManager.default.createDirectory(
      at: probe, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data("existing".utf8).write(to: probe.appendingPathComponent("user-file"))
    #expect(throws: ClaudeAutomaticAdapterError.unsafePath) {
      try FoundationClaudeUsagePTYProbe(timeout: 1, registerForShutdown: false).capture(
        executable: URL(fileURLWithPath: "/bin/false"), workingDirectory: probe)
    }
  }

  @Test("Application shutdown removes a registered Claude session artifact")
  func shutdownRemovesRegisteredSession() throws {
    let directory = URL(fileURLWithPath: "/tmp/QuotaTempoProbeShutdownTest")
    let id = UUID().uuidString.lowercased()
    let projectName = directory.path.utf16.map { unit -> Character in
      switch unit {
      case 48...57, 65...90, 97...122: Character(UnicodeScalar(unit)!)
      default: "-"
      }
    }
    let project = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects", isDirectory: true)
      .appendingPathComponent(String(projectName), isDirectory: true)
    let artifact = project.appendingPathComponent("\(id).jsonl")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("temporary".utf8).write(to: artifact)
    defer { try? FileManager.default.removeItem(at: artifact) }
    ClaudeSessionArtifactRegistry.shared.register(id, directory: directory)

    FoundationBoundedProcessRunner.terminateAllRunningProcesses()

    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(!ClaudeSessionArtifactRegistry.shared.snapshot().contains { $0.0 == id })
  }

  @Test("PTY probe terminates a CLI child even when its parent exits")
  func stopsExitedParentChild() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let childPIDFile = root.appendingPathComponent("child.pid")
    let fake = root.appendingPathComponent("claude")
    let script = """
      #!/bin/sh
      sleep 30 &
      echo $! > "\(childPIDFile.path)"
      printf 'Claude Code\\r\\n❯ '
      while IFS= read -r input; do
        case "$input" in
          *"/usage"*)
            printf 'Current session\\r\\n20%% used\\r\\nResets 2026-09-22T23:00:00Z\\r\\nCurrent week (all models)\\r\\n20%% used\\r\\nResets 2026-09-29T23:00:00Z\\r\\n'
            sleep 0.2
            exit 0
            ;;
        esac
      done
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
    _ = try FoundationClaudeUsagePTYProbe(timeout: 12, registerForShutdown: false)
      .capture(executable: fake, workingDirectory: root.appendingPathComponent("probe"))
    let pidText = try String(contentsOf: childPIDFile, encoding: .utf8)
    let pid = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    for _ in 0..<30 {
      if kill(pid, 0) != 0 { return }
      usleep(20_000)
    }
    let stateProcess = Process()
    stateProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
    stateProcess.arguments = ["-o", "stat=", "-p", String(pid)]
    let output = Pipe()
    stateProcess.standardOutput = output
    try stateProcess.run()
    stateProcess.waitUntilExit()
    let state = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(state.isEmpty || state.hasPrefix("Z"))
  }
}
