import Darwin
import Foundation
import Testing

@testable import QuotaTempoApp

@Suite("Isolated official Code engine wire acceptance", .serialized)
struct CodeComparisonOfficialWireTests {
  @Test(
    "Official engine sends encrypted synthetic usage to the real native receiver",
    .enabled(
      if: ProcessInfo.processInfo.environment["QUOTATEMPO_OFFICIAL_CLAUDE_TEST_BINARY"] != nil)
  )
  func engineWire() async throws {
    let executable = try #require(
      ProcessInfo.processInfo.environment["QUOTATEMPO_OFFICIAL_CLAUDE_TEST_BINARY"])
    let now = Date()
    let session = CodeComparisonIPCSession(clock: Date.init)
    let setup = try await session.prepare(now: now)
    defer {
      session.terminate()
      try? FileManager.default.removeItem(at: setup.directory)
    }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "node",
      project.appendingPathComponent("experiments/claude-mods-usage/tests/official-ipc-client.mjs")
        .path,
      setup.directory.path, String(Int(now.timeIntervalSince1970 * 1_000)),
      try #require(setup.publicKey), executable,
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 40
    var receivedSyntheticUsage = false
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      let view = await session.poll(connectionID: setup.connectionID, clock: Date.init)
      if view.status == .comparisonOnly && view.weekly?.remainingPercent == 58 {
        receivedSyntheticUsage = true
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    if process.isRunning {
      process.terminate()
      let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2
      while process.isRunning && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(receivedSyntheticUsage)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    #expect(data.count < 512)
    let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(result["status"] as? String == "passed")
    #expect(result["actualHTTP"] as? Bool == true)
    #expect(result["modelRequests"] as? Int == 0)
    #expect(result["quotaFileWrites"] as? Int == 0)
    #expect(result["liveAcceptance"] as? Bool == false)
    let final = await session.poll(connectionID: setup.connectionID, clock: Date.init)
    #expect(final.status == .disconnected && final.weekly == nil)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }
}
