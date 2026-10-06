import Darwin
import Foundation
import Testing

@testable import QuotaTempoApp

@Suite("Code comparison private connection")
struct CodeComparisonConnectionTests {
  @Test("Construction does not create files; explicit preparation is private and bounded")
  func explicitPreparation() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let setup = try await session.prepare(now: now)
    #expect(CodeComparisonProtocol.uuid(setup.connectionID))
    #expect(setup.command == "connect \(setup.directory.path)")
    let directory = try FileManager.default.attributesOfItem(atPath: setup.directory.path)
    let file = try FileManager.default.attributesOfItem(
      atPath: setup.directory.appendingPathComponent("probe-grant.json").path)
    #expect(directory[.posixPermissions] as? Int == 0o700)
    #expect(file[.posixPermissions] as? Int == 0o600)
    let result = await session.poll(connectionID: setup.connectionID, clock: { now })
    #expect(result.status == .waitingForConnection)
    #expect(await session.revoke(connectionID: setup.connectionID))
    #expect(!FileManager.default.fileExists(atPath: setup.directory.path))
  }

  @Test("Own stream binds once, repeated reads expire, and failed reads cannot restore old bytes")
  func streamLifecycle() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let setup = try await session.prepare(now: now)
    let path = streamURL(setup)
    let bytes = try envelope(setup)
    try bytes.write(to: path)
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).weekly?.remainingPercent
        == 58)
    try FileManager.default.removeItem(at: path)
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status == .unavailable)
    try bytes.write(to: path)
    #expect(await session.poll(connectionID: setup.connectionID, clock: { now }).weekly == nil)
    try envelope(setup, sequence: 2).write(to: path)
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status == .comparisonOnly
    )
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now.addingTimeInterval(301) })
        .status == .stale)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Multiple streams are rejected permanently for that grant, never guessed or merged")
  func multipleStreams() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let setup = try await session.prepare(now: now)
    try envelope(setup).write(to: streamURL(setup))
    let other = setup.directory.appendingPathComponent(
      "stream-33333333-3333-4333-8333-333333333333.json")
    try envelope(setup).write(to: other)
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .multipleSessions)
    try FileManager.default.removeItem(at: other)
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .multipleSessions)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Unknown files are never read or deleted; revocation still removes the exact grant")
  func unknownFile() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let setup = try await session.prepare(now: now)
    let unknown = setup.directory.appendingPathComponent("unknown.txt")
    try Data("synthetic untouched".utf8).write(to: unknown)
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status
        == .storageUnavailable)
    #expect(!(await session.revoke(connectionID: setup.connectionID)))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: setup.directory.appendingPathComponent("probe-grant.json").path))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status == .disconnected)
    let replacement = try await session.prepare(now: now)
    #expect(replacement.connectionID != setup.connectionID)
    #expect(await session.revoke(connectionID: replacement.connectionID))
  }

  @Test(
    "Unsafe stream types and permissions fail closed",
    arguments: ["symlink", "hardlink", "directory", "writable", "oversized"])
  func unsafeStreams(_ kind: String) async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let setup = try await session.prepare(now: now)
    let path = streamURL(setup)
    let target = root.appendingPathComponent("synthetic-target.json")
    try envelope(setup).write(to: target)
    switch kind {
    case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
    case "hardlink": try FileManager.default.linkItem(at: target, to: path)
    case "directory":
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    case "writable":
      try envelope(setup).write(to: path)
      try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path.path)
    default: try Data(repeating: 0x20, count: 16 * 1_024 + 1).write(to: path)
    }
    let view = await session.poll(connectionID: setup.connectionID, clock: { now })
    #expect(view.status == .unavailable && view.weekly == nil)
    #expect(!(await session.revoke(connectionID: setup.connectionID)))
    #expect(FileManager.default.fileExists(atPath: target.path))
  }

  @Test("Symlinked and non-private base directories cannot prepare")
  func unsafeBase() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let actual = root.appendingPathComponent("actual")
    try FileManager.default.createDirectory(
      at: actual, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
    await #expect(throws: (any Error).self) {
      try await CodeComparisonSession(directory: link).prepare(now: now)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: actual.path)
    await #expect(throws: (any Error).self) {
      try await CodeComparisonSession(directory: actual).prepare(now: now)
    }
  }

  @Test(
    "Preparation expires, restart never resumes old grants, and old cleanup cannot revoke a new connection"
  )
  func restartAndReplacement() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let first = try await session.prepare(now: now)
    #expect(
      await session.poll(connectionID: first.connectionID, clock: { now.addingTimeInterval(901) })
        .status == .stale)
    let restarted = CodeComparisonSession(directory: root)
    #expect(
      await restarted.poll(connectionID: first.connectionID, clock: { now }).status == .disconnected
    )
    let second = try await session.prepare(now: now.addingTimeInterval(902))
    #expect(!FileManager.default.fileExists(atPath: first.directory.path))
    #expect(await session.revoke(connectionID: first.connectionID))
    #expect(
      await session.poll(connectionID: second.connectionID, clock: { now.addingTimeInterval(902) })
        .status == .waitingForConnection)
    #expect(await session.revoke(connectionID: second.connectionID))
  }

  @Test("Clock rollback after a successful observation clears the value")
  func rollback() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let setup = try await session.prepare(now: now)
    try envelope(setup).write(to: streamURL(setup))
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now }).status == .comparisonOnly
    )
    #expect(
      await session.poll(connectionID: setup.connectionID, clock: { now.addingTimeInterval(-1) })
        .status == .invalidClock)
    #expect(await session.poll(connectionID: setup.connectionID, clock: { now }).weekly == nil)
    #expect(await session.revoke(connectionID: setup.connectionID))
  }

  @Test("Grant revocation does not depend on directory enumeration or file count")
  func revokeCrowdedDirectory() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let setup = try await session.prepare(now: now)
    for index in 0..<40 {
      try Data("synthetic".utf8).write(
        to: setup.directory.appendingPathComponent("unknown-\(index)"))
    }
    #expect(CodeComparisonFiles.revokeGrant(setup))
    #expect(
      !FileManager.default.fileExists(
        atPath: setup.directory.appendingPathComponent("probe-grant.json").path))
  }

  @Test(
    "Terminated service removes grants even before the controller receives them and cannot create new ones"
  )
  func terminatePreparationGate() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = CodeComparisonSession(directory: root)
    let prepared = try await session.prepare(now: now)
    session.terminate()
    #expect(
      !FileManager.default.fileExists(
        atPath: prepared.directory.appendingPathComponent("probe-grant.json").path))
    await #expect(throws: (any Error).self) { try await session.prepare(now: now) }
    let empty = CodeComparisonSession(directory: root.appendingPathComponent("new"))
    empty.terminate()
    await #expect(throws: (any Error).self) { try await empty.prepare(now: now) }
  }
}

private let now = Date(timeIntervalSince1970: 1_791_244_800)
private let stream = "22222222-2222-4222-8222-222222222222"
private func privateRoot() -> URL {
  URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent("quotatempo-code-test-\(UUID().uuidString)", isDirectory: true)
}
private func streamURL(_ setup: CodeComparisonSetup) -> URL {
  setup.directory.appendingPathComponent("stream-\(stream).json")
}
private func envelope(_ setup: CodeComparisonSetup, sequence: Int = 1) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: [
      "schemaVersion": 1, "connectionID": setup.connectionID, "streamID": stream,
      "sequence": sequence,
      "result": [
        "schemaVersion": 1, "status": "valid", "reason": NSNull(),
        "readAt": CodeComparisonProtocol.timestamp(now),
        "rateLimits": [
          [
            "kind": "seven_day", "percentUsed": 42,
            "resetsAt": CodeComparisonProtocol.timestamp(now.addingTimeInterval(86_400)),
            "firstSeenAt": CodeComparisonProtocol.timestamp(now),
            "lastReadAt": CodeComparisonProtocol.timestamp(now),
          ]
        ],
      ],
    ], options: [.sortedKeys])
}

@Suite("Code comparison controller lifecycle")
@MainActor
struct CodeComparisonControllerTests {
  @Test("Off and startup never prepare or read automatically")
  func explicitOnly() async {
    let service = ComparisonServiceStub()
    let controller = CodeUsageComparisonController(service: service, clock: { now })
    await controller.refresh()
    controller.setEnabled(false)
    await controller.prepare()
    await controller.refresh()
    #expect(await service.counts == [0, 0, 0])
    #expect(controller.view.status == .disconnected && controller.command == nil)
    controller.setEnabled(true)
    await controller.refresh()
    #expect(await service.counts == [0, 0, 0])
  }

  @Test("Prepare, read and disconnect publish only comparison values")
  func lifecycle() async {
    let service = ComparisonServiceStub()
    let controller = CodeUsageComparisonController(service: service, clock: { now })
    await controller.prepare()
    #expect(controller.view.status == .waitingForConnection && controller.command != nil)
    await controller.refresh()
    #expect(
      controller.view.status == .comparisonOnly && controller.view.weekly?.remainingPercent == 58)
    await controller.disconnect()
    #expect(
      controller.view.status == .disconnected && controller.view.weekly == nil
        && controller.command == nil)
    #expect(await service.counts == [1, 1, 1])
  }

  @Test("Disconnect during delayed preparation fences and revokes the late result")
  func preparationRace() async {
    let service = ComparisonServiceStub(delayedPrepare: true)
    let controller = CodeUsageComparisonController(service: service, clock: { now })
    let pending = Task { await controller.prepare() }
    await service.waitForPreparation()
    #expect(controller.isBusy && controller.view.status == .preparing)
    await controller.disconnect()
    await service.finishPreparation()
    await pending.value
    #expect(
      controller.view.status == .disconnected && controller.command == nil && !controller.isBusy)
    #expect(await service.counts == [1, 0, 1])
  }

  @Test("Off during delayed reading cannot restore values and overlapping refresh coalesces")
  func readRace() async {
    let service = ComparisonServiceStub(delayedPoll: true)
    let controller = CodeUsageComparisonController(service: service, clock: { now })
    await controller.prepare()
    let pending = Task { await controller.refresh() }
    await service.waitForPoll()
    await controller.refresh()
    controller.setEnabled(false)
    await service.finishPoll()
    await pending.value
    #expect(
      controller.view.status == .disconnected && controller.command == nil && !controller.isBusy)
    #expect(await service.counts[1] == 1)
  }

  @Test("Failure clears preparation loader and a second explicit preparation can recover")
  func recovery() async {
    let service = ComparisonServiceStub(failPrepare: true)
    let controller = CodeUsageComparisonController(service: service, clock: { now })
    await controller.prepare()
    #expect(
      controller.view.status == .storageUnavailable && !controller.isBusy
        && controller.command == nil)
    await service.allowPreparation()
    await controller.prepare()
    #expect(controller.view.status == .waitingForConnection && controller.command != nil)
    await controller.disconnect()
  }

  @Test("Quit revokes an actual grant without waiting for the asynchronous service")
  func quit() async throws {
    let root = privateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = CodeUsageComparisonController(clock: { now })
    await controller.prepare()
    let command = try #require(controller.command)
    let parts = command.split(separator: " ")
    #expect(parts.count == 3 && parts[2].count == 64)
    let path = String(parts[1])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }
    let grant = URL(fileURLWithPath: path).appendingPathComponent("probe-grant.json")
    #expect(FileManager.default.fileExists(atPath: grant.path))
    controller.applicationWillTerminate()
    #expect(!FileManager.default.fileExists(atPath: grant.path))
    #expect(controller.command == nil && controller.view.status == .disconnected)
  }
}

private actor ComparisonServiceStub: CodeComparisonServing {
  nonisolated func terminate() {}
  var counts = [0, 0, 0]
  private var delayedPrepare: Bool
  private var delayedPoll: Bool
  private var failPrepare: Bool
  private var prepareGate: CheckedContinuation<Void, Never>?
  private var pollGate: CheckedContinuation<Void, Never>?
  init(delayedPrepare: Bool = false, delayedPoll: Bool = false, failPrepare: Bool = false) {
    self.delayedPrepare = delayedPrepare
    self.delayedPoll = delayedPoll
    self.failPrepare = failPrepare
  }
  func prepare(now: Date) async throws -> CodeComparisonSetup {
    counts[0] += 1
    if delayedPrepare { await withCheckedContinuation { prepareGate = $0 } }
    if failPrepare { throw CodeComparisonFileError.unavailable }
    return CodeComparisonSetup(
      directory: URL(fileURLWithPath: "/private/tmp/quotatempo-synthetic"),
      connectionID: "11111111-1111-4111-8111-111111111111", grant: Data(), device: 0, inode: 0)
  }
  func poll(connectionID: String, clock: @Sendable () -> Date) async -> CodeUsageComparisonView {
    counts[1] += 1
    if delayedPoll { await withCheckedContinuation { pollGate = $0 } }
    return CodeUsageComparisonView(
      status: .comparisonOnly,
      weekly: CodeUsageComparisonWindow(
        remainingPercent: 58, resetAt: clock().addingTimeInterval(86_400)),
      receivedAt: clock())
  }
  func revoke(connectionID: String) -> Bool {
    counts[2] += 1
    return true
  }
  func waitForPreparation() async { while prepareGate == nil { await Task.yield() } }
  func waitForPoll() async { while pollGate == nil { await Task.yield() } }
  func finishPreparation() {
    prepareGate?.resume()
    prepareGate = nil
  }
  func finishPoll() {
    pollGate?.resume()
    pollGate = nil
  }
  func allowPreparation() { failPrepare = false }
}
