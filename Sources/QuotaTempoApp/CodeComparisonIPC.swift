import CryptoKit
import Darwin
import Foundation

// Only local Unix sockets are opened. Quota payloads stay in memory; the grant
// file contains connection metadata, never usage or provider authentication.
enum CodeComparisonHTTP {
  struct Request {
    let path: String
    let body: Data
  }

  static let maximumHeaderBytes = 4_096
  static let maximumRequestBytes = maximumHeaderBytes + CodeComparisonProtocol.maximumBytes

  static func parse(_ bytes: Data) throws -> Request? {
    guard bytes.count <= maximumRequestBytes else { throw CodeComparisonFileError.unsafe }
    let delimiter = Data([13, 10, 13, 10])
    guard let separator = bytes.range(of: delimiter) else {
      guard bytes.count < maximumHeaderBytes else { throw CodeComparisonFileError.unsafe }
      return nil
    }
    guard separator.upperBound <= maximumHeaderBytes,
      let header = String(data: bytes[..<separator.lowerBound], encoding: .ascii)
    else { throw CodeComparisonFileError.unsafe }
    let lines = header.components(separatedBy: "\r\n")
    let requestLine = lines[0].components(separatedBy: " ")
    guard requestLine.count == 3, requestLine[0] == "POST", requestLine[2] == "HTTP/1.1",
      ["/connect", "/measure", "/disconnect"].contains(requestLine[1]), lines.count <= 24
    else { throw CodeComparisonFileError.unsafe }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { throw CodeComparisonFileError.unsafe }
      let key = String(line[..<colon]).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty,
        key.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
        value.utf8.allSatisfy({ (32...126).contains($0) }), headers[key] == nil
      else { throw CodeComparisonFileError.unsafe }
      headers[key] = value
    }
    guard headers["host"] == "quotatempo", headers["transfer-encoding"] == nil,
      headers["expect"] == nil, headers["content-type"] == "application/json",
      let lengthText = headers["content-length"], !lengthText.isEmpty,
      lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
      let length = Int(lengthText), length > 0, length <= CodeComparisonProtocol.maximumBytes
    else { throw CodeComparisonFileError.unsafe }
    let expected = separator.upperBound + length
    guard bytes.count <= expected else { throw CodeComparisonFileError.unsafe }
    guard bytes.count == expected else { return nil }
    return Request(path: requestLine[1], body: Data(bytes[separator.upperBound...]))
  }

  static func response(_ status: Int, _ result: String) -> Data {
    response(status, jsonData: Data("{\"status\":\"\(result)\"}".utf8))
  }

  static func response(_ status: Int, jsonData: Data) -> Data {
    Data(
      "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Rejected")\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nConnection: close\r\n\r\n"
        .utf8) + jsonData
  }
}

final class CodeComparisonIPCBridge: @unchecked Sendable {
  private let setup: CodeComparisonSetup
  private let clock: @Sendable () -> Date
  private let lockCheckpoint: @Sendable (String) -> Void
  private let listener: Int32
  private let socketDevice: Int32
  private let socketInode: UInt64
  private let lock = NSLock()
  private let stopped = DispatchSemaphore(value: 0)
  private var closed = false
  private var started = false
  private var stream: String?
  private var decoder: CodeComparisonDecoder?
  private var view = CodeUsageComparisonView(status: .waitingForConnection)
  private var clockWatermark: Date
  private var encryption: CodeComparisonEncryption

  init(
    setup: CodeComparisonSetup, privateKey: Curve25519.KeyAgreement.PrivateKey,
    clock: @escaping @Sendable () -> Date, now: Date,
    lockCheckpoint: @escaping @Sendable (String) -> Void = { _ in }
  ) throws {
    let path = setup.directory.appendingPathComponent("bridge.sock").path
    guard path.utf8.count <= 103 else { throw CodeComparisonFileError.unsafe }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CodeComparisonFileError.unavailable }
    var completed = false
    defer { if !completed { Darwin.close(fd) } }
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
      fcntl(fd, F_SETFL, O_NONBLOCK) == 0
    else { throw CodeComparisonFileError.unavailable }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: 104) { buffer in
        for (index, byte) in path.utf8.enumerated() { buffer[index] = CChar(bitPattern: byte) }
      }
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw CodeComparisonFileError.unavailable }
    // The newly created parent is 0700 before bind, so the initial socket mode
    // cannot expose data while chmod runs. Never chmod or remove a preexisting socket.
    let directory = try CodeComparisonFiles.connection(setup)
    defer { Darwin.close(directory) }
    guard fchmodat(directory, "bridge.sock", 0o600, AT_SYMLINK_NOFOLLOW) == 0,
      Darwin.listen(fd, 4) == 0
    else {
      _ = unlinkat(directory, "bridge.sock", 0)
      throw CodeComparisonFileError.unavailable
    }
    var info = stat()
    guard fstatat(directory, "bridge.sock", &info, AT_SYMLINK_NOFOLLOW) == 0,
      (info.st_mode & S_IFMT) == S_IFSOCK,
      info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o600
    else { throw CodeComparisonFileError.unsafe }
    self.setup = setup
    self.clock = clock
    self.lockCheckpoint = lockCheckpoint
    listener = fd
    socketDevice = info.st_dev
    socketInode = info.st_ino
    clockWatermark = now
    encryption = CodeComparisonEncryption(privateKey: privateKey)
    completed = true
  }

  func start() {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()
    DispatchQueue(label: "QuotaTempo.CodeComparison.IPC", qos: .utility).async { [self] in
      defer {
        Darwin.close(listener)
        stopped.signal()
      }
      while !isClosed {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, 100) > 0, descriptor.revents & Int16(POLLIN) != 0 else {
          continue
        }
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { continue }
        serve(client)
        Darwin.close(client)
      }
    }
  }

  private var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    encryption.close()
    decoder = nil
    view = CodeUsageComparisonView(status: .disconnected)
    // Worker owns close(), avoiding descriptor reuse races with an in-flight poll.
    // Hold the state lock through shutdown so the worker cannot close/reuse fd first.
    _ = Darwin.shutdown(listener, SHUT_RDWR)
    lock.unlock()
  }

  func finish() -> Bool {
    stopped.wait(timeout: .now() + 3) == .success
  }

  private func validFiles() -> Bool {
    do {
      let directory = try CodeComparisonFiles.connection(setup)
      defer { Darwin.close(directory) }
      var socket = stat()
      return try CodeComparisonFiles.read("probe-grant.json", in: directory, limit: 1_024)
        == setup.grant
        && fstatat(directory, "bridge.sock", &socket, AT_SYMLINK_NOFOLLOW) == 0
        && socket.st_dev == socketDevice && socket.st_ino == socketInode
        && socket.st_uid == geteuid() && socket.st_nlink == 1
        && (socket.st_mode & S_IFMT) == S_IFSOCK && (socket.st_mode & 0o777) == 0o600
    } catch { return false }
  }

  func snapshot(clock: @Sendable () -> Date) -> CodeUsageComparisonView {
    lockCheckpoint("poll")
    lock.lock()
    defer { lock.unlock() }
    let now = clock()
    guard !closed else { return CodeUsageComparisonView(status: .disconnected) }
    guard validFiles() else {
      view = decoder?.unavailable() ?? CodeUsageComparisonView(status: .storageUnavailable)
      return view
    }
    guard now.timeIntervalSince1970.isFinite, now >= clockWatermark else {
      _ = decoder?.unavailable()
      view = CodeUsageComparisonView(status: .invalidClock)
      return view
    }
    clockWatermark = now
    if view.status == .multipleSessions || view.status == .disconnected { return view }
    if let current = decoder?.current(now: now) {
      view = current
    } else if now.timeIntervalSince(
      CodeComparisonProtocol.date(
        ((try? JSONSerialization.jsonObject(with: setup.grant)) as? [String: Any])?["createdAt"])
        ?? .distantPast) > 900
    {
      view = CodeUsageComparisonView(status: .stale)
    }
    return view
  }

  private func receive(_ request: CodeComparisonHTTP.Request) -> Data {
    lockCheckpoint("receive")
    lock.lock()
    defer { lock.unlock() }
    let now = clock()
    guard !closed, validFiles(), now.timeIntervalSince1970.isFinite, now >= clockWatermark,
      view.status != .multipleSessions, view.status != .disconnected
    else { return CodeComparisonHTTP.response(409, "rejected") }
    let opened: CodeComparisonEncryption.Opened
    do {
      opened = try encryption.open(
        request.body, connectionID: setup.connectionID, endpoint: String(request.path.dropFirst()))
    } catch CodeComparisonEncryptionError.exhausted {
      decoder = nil
      stream = nil
      view = CodeUsageComparisonView(status: .disconnected)
      return CodeComparisonHTTP.response(409, "rejected")
    } catch { return CodeComparisonHTTP.response(409, "rejected") }
    let incoming = opened.streamID
    func success(_ status: String) -> Data {
      guard let json = try? opened.response(status: status) else {
        return CodeComparisonHTTP.response(409, "rejected")
      }
      return CodeComparisonHTTP.response(200, jsonData: json)
    }
    clockWatermark = now
    if request.path == "/measure" {
      guard stream == incoming, var decoder else {
        return CodeComparisonHTTP.response(409, "rejected")
      }
      view = decoder.consume(opened.plaintext, now: now)
      self.decoder = decoder
      return success("accepted")
    }
    if request.path == "/disconnect" {
      guard stream == incoming else { return CodeComparisonHTTP.response(409, "rejected") }
      decoder = nil
      encryption.close()
      view = CodeUsageComparisonView(status: .disconnected)
      return success("disconnected")
    }
    if let stream, stream != incoming {
      decoder = nil
      encryption.close()
      view = CodeUsageComparisonView(status: .multipleSessions)
      return CodeComparisonHTTP.response(409, "rejected")
    }
    guard stream == nil,
      let object = (try? JSONSerialization.jsonObject(with: setup.grant)) as? [String: Any],
      let created = CodeComparisonProtocol.date(object["createdAt"]),
      now.timeIntervalSince(created) <= 900
    else { return CodeComparisonHTTP.response(409, "rejected") }
    stream = incoming
    decoder = CodeComparisonDecoder(connectionID: setup.connectionID, streamID: incoming)
    view = CodeUsageComparisonView(status: .waitingForMeasurement)
    return success("connected")
  }

  private func serve(_ client: Int32) {
    var uid: uid_t = 0
    var gid: gid_t = 0
    var noSignal: Int32 = 1
    guard getpeereid(client, &uid, &gid) == 0, uid == geteuid(),
      fcntl(client, F_SETFL, O_NONBLOCK) == 0,
      fcntl(client, F_SETFD, FD_CLOEXEC) == 0,
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else { return }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var bytes = Data()
    var response: Data?
    while !isClosed && ProcessInfo.processInfo.systemUptime < deadline {
      var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
      guard Darwin.poll(&descriptor, 1, 100) > 0 else { continue }
      var buffer = [UInt8](repeating: 0, count: 2_048)
      let count = Darwin.read(client, &buffer, buffer.count)
      guard count > 0 else { return }
      bytes.append(contentsOf: buffer.prefix(count))
      do {
        if let request = try CodeComparisonHTTP.parse(bytes) {
          response = receive(request)
          break
        }
      } catch {
        response = CodeComparisonHTTP.response(400, "rejected")
        break
      }
    }
    guard let response else { return }
    var offset = 0
    while offset < response.count && !isClosed && ProcessInfo.processInfo.systemUptime < deadline {
      var descriptor = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
      guard Darwin.poll(&descriptor, 1, 100) > 0 else { continue }
      let count = response.withUnsafeBytes {
        Darwin.write(client, $0.baseAddress!.advanced(by: offset), $0.count - offset)
      }
      guard count > 0 else { return }
      offset += count
    }
  }

  func removeSocket() -> Bool {
    do {
      let directory = try CodeComparisonFiles.connection(setup)
      defer { Darwin.close(directory) }
      var socket = stat()
      guard fstatat(directory, "bridge.sock", &socket, AT_SYMLINK_NOFOLLOW) == 0 else {
        return errno == ENOENT
      }
      guard socket.st_dev == socketDevice, socket.st_ino == socketInode,
        (socket.st_mode & S_IFMT) == S_IFSOCK
      else { return false }
      return unlinkat(directory, "bridge.sock", 0) == 0
    } catch { return false }
  }
}

private final class CodeComparisonIPCGate: @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  private var revision = 0
  private var bridges: [String: (CodeComparisonSetup, CodeComparisonIPCBridge)] = [:]

  func ticket() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return revision
  }

  func validate(_ ticket: Int) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, revision == ticket else { throw CodeComparisonFileError.unavailable }
  }

  func register(
    _ bridge: CodeComparisonIPCBridge, setup: CodeComparisonSetup, directory: Int32,
    grants: CodeComparisonGrantGate, ticket: Int
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, revision == ticket else { throw CodeComparisonFileError.unavailable }
    // Register the grant and receiver under the same cancellation boundary.
    try grants.write(setup, in: directory)
    bridges[setup.connectionID] = (setup, bridge)
    bridge.start()
  }

  func revoke(_ id: String) {
    lock.lock()
    let bridge = bridges.removeValue(forKey: id)
    lock.unlock()
    bridge?.1.close()
  }

  func cancel() {
    lock.lock()
    revision += 1
    let pending = Array(bridges.values)
    bridges.removeAll()
    // Cancellation completes before another preparation can register.
    for (setup, bridge) in pending {
      bridge.close()
      _ = CodeComparisonFiles.revokeGrant(setup)
      _ = bridge.removeSocket()
    }
    lock.unlock()
  }

  func terminate() {
    lock.lock()
    closed = true
    let pending = Array(bridges.values)
    bridges.removeAll()
    lock.unlock()
    for (_, bridge) in pending {
      bridge.close()
      _ = bridge.removeSocket()
    }
  }
}

actor CodeComparisonIPCSession: CodeComparisonServing {
  nonisolated private let gate = CodeComparisonIPCGate()
  nonisolated private let grants = CodeComparisonGrantGate()
  private let clock: @Sendable () -> Date
  private let preparationCheckpoint: @Sendable (CodeComparisonSetup) -> Void
  private let lockCheckpoint: @Sendable (String) -> Void
  private var current: (CodeComparisonSetup, CodeComparisonIPCBridge)?

  init(
    clock: @escaping @Sendable () -> Date = Date.init,
    preparationCheckpoint: @escaping @Sendable (CodeComparisonSetup) -> Void = { _ in },
    lockCheckpoint: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.clock = clock
    self.preparationCheckpoint = preparationCheckpoint
    self.lockCheckpoint = lockCheckpoint
  }

  nonisolated func revokeImmediately(connectionID: String) { gate.revoke(connectionID) }
  nonisolated func cancelPreparation() { gate.cancel() }
  nonisolated func preparationTicket() -> Int { gate.ticket() }
  nonisolated func terminate() {
    gate.terminate()
    grants.terminate()
  }

  func prepare(now: Date) async throws -> CodeComparisonSetup {
    try build(now: now, ticket: preparationTicket())
  }

  func prepare(now: Date, ticket: Int) async throws -> CodeComparisonSetup {
    try build(now: now, ticket: ticket)
  }

  private func build(now: Date, ticket: Int) throws -> CodeComparisonSetup {
    try gate.validate(ticket)
    guard now.timeIntervalSince1970.isFinite else { throw CodeComparisonFileError.unsafe }
    if let current, !revoke(connectionID: current.0.connectionID) {
      throw CodeComparisonFileError.unsafe
    }
    let parent = Darwin.open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw CodeComparisonFileError.unavailable }
    defer { Darwin.close(parent) }
    var parentInfo = stat()
    guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == 0,
      (parentInfo.st_mode & S_ISVTX) != 0
    else { throw CodeComparisonFileError.unsafe }
    let name = "qtc-\(UUID().uuidString.lowercased())"
    guard mkdirat(parent, name, 0o700) == 0 else { throw CodeComparisonFileError.unavailable }
    let path = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name)
    var completed = false
    defer { if !completed { _ = unlinkat(parent, name, AT_REMOVEDIR) } }
    let fd = try CodeComparisonFiles.directory(path)
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw CodeComparisonFileError.unsafe }
    let id = UUID().uuidString.lowercased()
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let grant = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 3, "purpose": "quotatempo-mods-comparison", "connectionID": id,
        "createdAt": CodeComparisonProtocol.timestamp(now), "transport": "unix-hpke",
        "socketPath": path.appendingPathComponent("bridge.sock").path,
      ], options: [.sortedKeys])
    let setup = CodeComparisonSetup(
      directory: path, connectionID: id, grant: grant, device: info.st_dev, inode: info.st_ino,
      publicKey: CodeComparisonEncryption.hex(privateKey.publicKey.rawRepresentation))
    let bridge = try CodeComparisonIPCBridge(
      setup: setup, privateKey: privateKey, clock: clock, now: now, lockCheckpoint: lockCheckpoint)
    do {
      preparationCheckpoint(setup)
      try gate.register(bridge, setup: setup, directory: fd, grants: grants, ticket: ticket)
    } catch {
      gate.revoke(id)
      bridge.close()
      bridge.start()
      _ = bridge.finish()
      _ = bridge.removeSocket()
      throw error
    }
    current = (setup, bridge)
    completed = true
    return setup
  }

  func poll(connectionID: String, clock: @Sendable () -> Date) -> CodeUsageComparisonView {
    guard let current, current.0.connectionID == connectionID else {
      return CodeUsageComparisonView(status: .disconnected)
    }
    return current.1.snapshot(clock: clock)
  }

  func revoke(connectionID: String) -> Bool {
    guard let previous = current, previous.0.connectionID == connectionID else { return true }
    current = nil
    gate.revoke(connectionID)
    let stopped = previous.1.finish()
    let grantRemoved = CodeComparisonFiles.revokeGrant(previous.0)
    grants.forget(connectionID)
    let socketRemoved = stopped && previous.1.removeSocket()
    guard grantRemoved, socketRemoved else { return false }
    do {
      let directory = try CodeComparisonFiles.connection(previous.0)
      defer { Darwin.close(directory) }
      guard try CodeComparisonFiles.names(in: directory).isEmpty else { return false }
      return rmdir(previous.0.directory.path) == 0
    } catch { return false }
  }
}
