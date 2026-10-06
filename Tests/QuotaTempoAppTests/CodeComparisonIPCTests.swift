import Darwin
import Foundation
import Testing

@testable import QuotaTempoApp

@Suite("Code comparison Unix transport", .serialized)
struct CodeComparisonIPCTests {
  private let now = Date(timeIntervalSince1970: 1_791_244_800)
  private let stream = "22222222-2222-4222-8222-222222222222"
  private let other = "33333333-3333-4333-8333-333333333333"

  @Test("Explicit private socket handshake, in-memory usage and disconnect")
  func lifecycle() async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let setup = try await session.prepare(now: now)
    defer { session.terminate() }
    let grant = try #require(JSONSerialization.jsonObject(with: setup.grant) as? [String: Any])
    #expect(CodeComparisonProtocol.number(grant["schemaVersion"]) == 3)
    #expect(grant["transport"] as? String == "unix-hpke")
    #expect(
      Set(grant.keys) == [
        "schemaVersion", "purpose", "connectionID", "createdAt", "transport", "socketPath",
      ])
    let publicKey = try #require(setup.publicKey)
    #expect(CodeComparisonEncryption.unhex(publicKey, bytes: 32...32) != nil)
    #expect(setup.command == "connect \(setup.directory.path) \(publicKey)")
    #expect(grant["socketPath"] as? String == setup.directory.path + "/bridge.sock")
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .waitingForConnection)
    #expect(try request(setup, "/measure", body: measurement(setup)).contains("409"))
    #expect(try request(setup, "/connect", body: control(setup)).contains("connected"))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .waitingForMeasurement)
    #expect(try request(setup, "/measure", body: measurement(setup)).contains("accepted"))
    let view = await session.poll(connectionID: setup.connectionID, clock: { now })
    #expect(view.weekly?.remainingPercent == 58)
    #expect(view.status == .comparisonOnly)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: setup.directory.path).sorted() == [
        "bridge.sock", "probe-grant.json",
      ])
    #expect(try request(setup, "/disconnect", body: control(setup)).contains("disconnected"))
    #expect(try request(setup, "/measure", body: measurement(setup, sequence: 2)).contains("409"))
    #expect(await session.poll(connectionID: setup.connectionID, clock: { now }).weekly == nil)
    #expect(await session.revoke(connectionID: setup.connectionID))
    #expect(!FileManager.default.fileExists(atPath: setup.directory.path))
  }

  @Test("Multiple sessions are sticky, not guessed or merged")
  func multiple() async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let setup = try await session.prepare(now: now)
    defer { session.terminate() }
    _ = try request(setup, "/connect", body: control(setup))
    _ = try request(setup, "/measure", body: measurement(setup))
    #expect(try request(setup, "/connect", body: control(setup, streamID: other)).contains("409"))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .multipleSessions)
    #expect(try request(setup, "/measure", body: measurement(setup, sequence: 2)).contains("409"))
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Plaintext, tampering, endpoint substitution and replay have no connection side effects")
  func encryptedWireSecurity() async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let setup = try await session.prepare(now: now)
    defer { session.terminate() }
    let plaintext = try JSONSerialization.data(withJSONObject: control(setup))
    #expect(try rawRequest(setup, "/connect", payload: plaintext).contains("409"))
    let sealed = try CodeComparisonSyntheticRequest(
      publicKey: #require(setup.publicKey), connectionID: setup.connectionID,
      streamID: stream, endpoint: "connect", plaintext: plaintext)
    var outer = try #require(JSONSerialization.jsonObject(with: sealed.data) as? [String: Any])
    let cipher = try #require(outer["ciphertext"] as? String)
    outer["ciphertext"] = (cipher.first == "0" ? "1" : "0") + String(cipher.dropFirst())
    let tampered = try JSONSerialization.data(withJSONObject: outer)
    #expect(try rawRequest(setup, "/connect", payload: tampered).contains("409"))
    #expect(try rawRequest(setup, "/disconnect", payload: sealed.data).contains("409"))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .waitingForConnection)
    let connected = try rawRequest(setup, "/connect", payload: sealed.data)
    #expect(try sealed.verifies(connected))
    let replayed = try rawRequest(setup, "/connect", payload: sealed.data)
    #expect(replayed.contains("409") && !replayed.contains("\"proof\""))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .waitingForMeasurement)
    _ = try request(setup, "/measure", body: measurement(setup))
    let usage = try CodeComparisonSyntheticRequest(
      publicKey: #require(setup.publicKey), connectionID: setup.connectionID,
      streamID: stream, endpoint: "measure",
      plaintext: JSONSerialization.data(withJSONObject: measurement(setup, sequence: 2)))
    #expect(try usage.verifies(rawRequest(setup, "/measure", payload: usage.data)))
    #expect(try rawRequest(setup, "/measure", payload: usage.data).contains("409"))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).weekly?
        .remainingPercent == 58)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Cancellation discards the pinned key; fresh setup needs its new command key")
  func freshKeyAfterCancellation() async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let old = try await session.prepare(now: now)
    defer { session.terminate() }
    _ = try request(old, "/connect", body: control(old))
    session.cancelPreparation()
    #expect(
      await session.poll(connectionID: old.connectionID, clock: { now }).status
        == .disconnected)
    #expect(await session.revoke(connectionID: old.connectionID))
    let fresh = try await session.prepare(now: now)
    #expect(fresh.publicKey != old.publicKey)
    let staleKey = try CodeComparisonSyntheticRequest(
      publicKey: #require(old.publicKey), connectionID: fresh.connectionID,
      streamID: stream, endpoint: "connect",
      plaintext: JSONSerialization.data(withJSONObject: control(fresh)))
    #expect(try rawRequest(fresh, "/connect", payload: staleKey.data).contains("409"))
    #expect(
      await session.poll(connectionID: fresh.connectionID, clock: { now }).status
        == .waitingForConnection)
    #expect(try request(fresh, "/connect", body: control(fresh)).contains("connected"))
    #expect(await session.revoke(connectionID: fresh.connectionID))
  }

  @Test(
    "Actual plugin hook sends quota only over the native socket",
    arguments: ["measure", "disconnect"])
  func pluginIntegration(_ action: String) async throws {
    let session = CodeComparisonIPCSession(clock: { now })
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
      project.appendingPathComponent("experiments/claude-mods-usage/tests/native-ipc-client.mjs")
        .path,
      setup.directory.path, String(Int(now.timeIntervalSince1970 * 1_000)), action,
      try #require(setup.publicKey),
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let result = output.fileHandleForReading.readDataToEndOfFile()
    #expect(result.count < 256)
    let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
    #expect(object["status"] as? String == "passed")
    #expect(object["quotaFileWrites"] as? Int == 0)
    let view = await session.poll(connectionID: setup.connectionID, clock: { now })
    if action == "disconnect" {
      #expect(view.status == .disconnected && view.weekly == nil)
    } else {
      #expect(view.status == .comparisonOnly && view.weekly?.remainingPercent == 58)
    }
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test(
    "Unsafe modes and immutable grants reject subsequent delivery",
    arguments: ["directory", "socket", "grant"])
  func mutation(_ kind: String) async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let setup = try await session.prepare(now: now)
    defer {
      session.terminate()
      try? FileManager.default.removeItem(at: setup.directory)
    }
    _ = try request(setup, "/connect", body: control(setup))
    _ = try request(setup, "/measure", body: measurement(setup))
    if kind == "grant" {
      try Data("{}".utf8).write(to: setup.directory.appendingPathComponent("probe-grant.json"))
    } else {
      let target =
        kind == "directory"
        ? setup.directory : setup.directory.appendingPathComponent("bridge.sock")
      try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: target.path)
    }
    #expect(try request(setup, "/measure", body: measurement(setup, sequence: 2)).contains("409"))
    #expect(await session.poll(connectionID: setup.connectionID, clock: { now }).weekly == nil)
    if kind == "directory" {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: setup.directory.path)
    }
    if kind == "grant" {
      try setup.grant.write(to: setup.directory.appendingPathComponent("probe-grant.json"))
    }
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Wrong binding never takes over; expiry never rereads a quota file")
  func bindingAndExpiry() async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let setup = try await session.prepare(now: now)
    defer { session.terminate() }
    var wrong = control(setup)
    wrong["connectionID"] = other
    #expect(try request(setup, "/connect", body: wrong).contains("409"))
    _ = try request(setup, "/connect", body: control(setup))
    _ = try request(setup, "/measure", body: measurement(setup))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now.addingTimeInterval(301) })
        .status == .stale)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Synchronous revoke and quit reject delayed messages and preparation")
  func quit() async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let setup = try await session.prepare(now: now)
    _ = try request(setup, "/connect", body: control(setup))
    session.revokeImmediately(connectionID: setup.connectionID)
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status == .disconnected)
    #expect(await session.revoke(connectionID: setup.connectionID))
    session.terminate()
    await #expect(throws: (any Error).self) { try await session.prepare(now: now) }
  }

  @Test("OFF and quit fence a receiver before its grant is registered", arguments: ["off", "quit"])
  func cancelPendingPreparation(_ action: String) async throws {
    let barrier = IPCPreparationBarrier()
    let session = CodeComparisonIPCSession(clock: { now }, preparationCheckpoint: barrier.pause)
    let ticket = session.preparationTicket()
    let preparation = Task { try await session.prepare(now: now, ticket: ticket) }
    let reached = await Task.detached { barrier.waitUntilReady() }.value
    defer {
      barrier.release.signal()
      session.terminate()
    }
    #expect(reached)
    let path = try #require(barrier.directory)
    let queued = Task { try await session.prepare(now: now, ticket: ticket) }
    #expect(
      !FileManager.default.fileExists(atPath: path.appendingPathComponent("probe-grant.json").path))
    if action == "off" { session.cancelPreparation() } else { session.terminate() }
    barrier.release.signal()
    await #expect(throws: (any Error).self) { try await preparation.value }
    await #expect(throws: (any Error).self) { try await queued.value }
    #expect(!FileManager.default.fileExists(atPath: path.path))
    #expect(barrier.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    if action == "off" {
      let new = try await session.prepare(now: now)
      #expect(await session.revoke(connectionID: new.connectionID))
    }
  }

  @Test("Poll samples time only after concurrent reception releases the bridge lock")
  func clockOrdering() async throws {
    let barrier = IPCTimeBarrier()
    let session = CodeComparisonIPCSession(
      clock: {
        barrier.pause()
        return now
      }, lockCheckpoint: { if $0 == "poll" { barrier.arrived.signal() } })
    let setup = try await session.prepare(now: now)
    defer {
      barrier.release.signal()
      session.terminate()
      try? FileManager.default.removeItem(at: setup.directory)
    }
    let connecting = Task.detached { try request(setup, "/connect", body: control(setup)) }
    let reached = await Task.detached { barrier.waitUntilReady() }.value
    #expect(reached)
    let polling = Task {
      await session.poll(
        connectionID: setup.connectionID,
        clock: {
          barrier.sampled.signal()
          return now.addingTimeInterval(1)
        })
    }
    #expect(await Task.detached { barrier.waitForArrival() }.value)
    let early = await Task.detached { barrier.sampledEarly() }
      .value
    #expect(!early)
    barrier.release.signal()
    #expect(try await connecting.value.contains("connected"))
    #expect(await polling.value.status == .waitingForMeasurement)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Reception samples time only after concurrent polling releases the bridge lock")
  func reverseClockOrdering() async throws {
    let barrier = IPCTimeBarrier()
    let reception = IPCTimeBarrier()
    let session = CodeComparisonIPCSession(
      clock: {
        barrier.sampled.signal()
        return now.addingTimeInterval(1)
      }, lockCheckpoint: { if $0 == "receive" { reception.pause() } })
    let setup = try await session.prepare(now: now)
    defer {
      barrier.release.signal()
      reception.release.signal()
      session.terminate()
      try? FileManager.default.removeItem(at: setup.directory)
    }
    let connecting = Task.detached { try request(setup, "/connect", body: control(setup)) }
    #expect(await Task.detached { reception.waitUntilReady() }.value)
    let polling = Task {
      await session.poll(
        connectionID: setup.connectionID,
        clock: {
          barrier.pause()
          return now
        })
    }
    #expect(await Task.detached { barrier.waitUntilReady() }.value)
    reception.release.signal()
    #expect(!(await Task.detached { barrier.sampledEarly() }.value))
    barrier.release.signal()
    #expect(await polling.value.status == .waitingForConnection)
    #expect(try await connecting.value.contains("connected"))
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("A rejected old preparation ticket cannot revoke a newer connection")
  func stalePreparationTicket() async throws {
    let session = CodeComparisonIPCSession(clock: { now })
    let old = session.preparationTicket()
    session.cancelPreparation()
    let setup = try await session.prepare(now: now, ticket: session.preparationTicket())
    defer {
      session.terminate()
      try? FileManager.default.removeItem(at: setup.directory)
    }
    await #expect(throws: (any Error).self) { try await session.prepare(now: now, ticket: old) }
    #expect(
      FileManager.default.fileExists(
        atPath: setup.directory.appendingPathComponent("probe-grant.json").path))
    #expect(try request(setup, "/connect", body: control(setup)).contains("connected"))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .waitingForMeasurement)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test(
    "Strict HTTP framing rejects ambiguous or unbounded requests",
    arguments: [
      "GET", "chunked", "duplicate", "host", "query", "oversized", "pipeline", "negative", "folded",
    ])
  func badHTTP(_ kind: String) throws {
    var bytes =
      "POST /connect HTTP/1.1\r\nHost: quotatempo\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
    switch kind {
    case "GET": bytes = bytes.replacingOccurrences(of: "POST", with: "GET")
    case "chunked":
      bytes = bytes.replacingOccurrences(
        of: "Content-Length: 2", with: "Transfer-Encoding: chunked\r\nContent-Length: 2")
    case "duplicate":
      bytes = bytes.replacingOccurrences(
        of: "Content-Length: 2", with: "Content-Length: 2\r\ncontent-length: 2")
    case "host": bytes = bytes.replacingOccurrences(of: "quotatempo", with: "other")
    case "query": bytes = bytes.replacingOccurrences(of: "/connect", with: "/connect?x=1")
    case "oversized":
      bytes = bytes.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 16385")
    case "pipeline": bytes += bytes
    case "negative":
      bytes = bytes.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: -2")
    default: bytes = bytes.replacingOccurrences(of: "Host:", with: " Host:")
    }
    #expect(throws: (any Error).self) { try CodeComparisonHTTP.parse(Data(bytes.utf8)) }
  }

  @Test("Partial bodies wait, header-only floods fail, socket permissions are private")
  func bounds() async throws {
    let partial = Data(
      "POST /connect HTTP/1.1\r\nHost: quotatempo\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{"
        .utf8)
    #expect(try CodeComparisonHTTP.parse(partial) == nil)
    #expect(throws: (any Error).self) {
      try CodeComparisonHTTP.parse(Data(repeating: 65, count: 4_096))
    }
    let session = CodeComparisonIPCSession(clock: { now })
    let setup = try await session.prepare(now: now)
    defer { session.terminate() }
    let attributes = try FileManager.default.attributesOfItem(
      atPath: setup.directory.appendingPathComponent("bridge.sock").path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  private func control(_ setup: CodeComparisonSetup, streamID: String? = nil) -> [String: Any] {
    ["schemaVersion": 2, "connectionID": setup.connectionID, "streamID": streamID ?? stream]
  }

  private func measurement(_ setup: CodeComparisonSetup, sequence: Int = 1) -> [String: Any] {
    let time = CodeComparisonProtocol.timestamp(now)
    return [
      "schemaVersion": 1, "connectionID": setup.connectionID, "streamID": stream,
      "sequence": sequence,
      "result": [
        "schemaVersion": 1, "status": "valid", "reason": NSNull(), "readAt": time,
        "rateLimits": [
          [
            "kind": "seven_day", "percentUsed": 42,
            "resetsAt": CodeComparisonProtocol.timestamp(now.addingTimeInterval(86_400)),
            "firstSeenAt": time, "lastReadAt": time,
          ]
        ],
      ],
    ]
  }

  private func request(_ setup: CodeComparisonSetup, _ path: String, body: [String: Any]) throws
    -> String
  {
    let sealed = try CodeComparisonSyntheticRequest(
      publicKey: #require(setup.publicKey), connectionID: setup.connectionID,
      streamID: body["streamID"] as? String ?? stream, endpoint: String(path.dropFirst()),
      plaintext: JSONSerialization.data(withJSONObject: body))
    let response = try rawRequest(setup, path, payload: sealed.data)
    if response.hasPrefix("HTTP/1.1 200") {
      #expect(try sealed.verifies(response))
    } else {
      #expect(!response.contains("\"proof\""))
    }
    return response
  }

  private func rawRequest(_ setup: CodeComparisonSetup, _ path: String, payload: Data) throws
    -> String
  {
    let bytes =
      Data(
        "POST \(path) HTTP/1.1\r\nHost: quotatempo\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n"
          .utf8) + payload
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CodeComparisonFileError.unavailable }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let socketPath = setup.directory.appendingPathComponent("bridge.sock").path
    withUnsafeMutablePointer(to: &address.sun_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: 104) { buffer in
        for (index, byte) in socketPath.utf8.enumerated() {
          buffer[index] = CChar(bitPattern: byte)
        }
      }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw CodeComparisonFileError.unavailable }
    let sent = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard sent == bytes.count else { throw CodeComparisonFileError.unavailable }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0, response.count + count < 4_096 else {
        throw CodeComparisonFileError.unavailable
      }
      response.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: response, as: UTF8.self)
  }
}

private final class IPCPreparationBarrier: @unchecked Sendable {
  let ready = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var path: URL?
  private var paths: [URL] = []
  var directories: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return paths
  }
  func waitUntilReady() -> Bool { ready.wait(timeout: .now() + 5) == .success }
  var directory: URL? {
    lock.lock()
    defer { lock.unlock() }
    return path
  }
  func pause(_ setup: CodeComparisonSetup) {
    lock.lock()
    paths.append(setup.directory)
    let first = path == nil
    if first { path = setup.directory }
    lock.unlock()
    if first {
      ready.signal()
      _ = release.wait(timeout: .now() + 5)
    }
  }
}

private final class IPCTimeBarrier: @unchecked Sendable {
  let ready = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let sampled = DispatchSemaphore(value: 0)
  let arrived = DispatchSemaphore(value: 0)
  func waitUntilReady() -> Bool { ready.wait(timeout: .now() + 5) == .success }
  func sampledEarly() -> Bool { sampled.wait(timeout: .now() + 0.1) == .success }
  func waitForArrival() -> Bool { arrived.wait(timeout: .now() + 5) == .success }
  func pause() {
    ready.signal()
    _ = release.wait(timeout: .now() + 5)
  }
}
