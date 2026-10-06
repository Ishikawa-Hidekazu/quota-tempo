import Combine
import Darwin
import Foundation

struct CodeComparisonSetup: Sendable {
  let directory: URL
  let connectionID: String
  let grant: Data
  let device: Int32
  let inode: UInt64
  var publicKey: String? = nil

  var command: String {
    "connect \(directory.path)" + (publicKey.map { " \($0)" } ?? "")
  }
}

protocol CodeComparisonServing: Sendable {
  func prepare(now: Date) async throws -> CodeComparisonSetup
  func preparationTicket() -> Int
  func prepare(now: Date, ticket: Int) async throws -> CodeComparisonSetup
  func poll(connectionID: String, clock: @Sendable () -> Date) async -> CodeUsageComparisonView
  func revoke(connectionID: String) async -> Bool
  func revokeImmediately(connectionID: String)
  func cancelPreparation()
  func terminate()
}

extension CodeComparisonServing {
  func preparationTicket() -> Int { 0 }
  func prepare(now: Date, ticket: Int) async throws -> CodeComparisonSetup {
    try await prepare(now: now)
  }
  func revokeImmediately(connectionID: String) {}
  func cancelPreparation() {}
}

enum CodeComparisonFileError: Error { case unsafe, unavailable }

enum CodeComparisonFiles {
  static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/"),
      !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw CodeComparisonFileError.unsafe }
    let parts = url.path.split(separator: "/").map(String.init)
    guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else {
      throw CodeComparisonFileError.unsafe
    }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw CodeComparisonFileError.unavailable }
    do {
      for (index, part) in parts.enumerated() {
        var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0 && errno == ENOENT && create {
          guard mkdirat(fd, part, 0o700) == 0 else { throw CodeComparisonFileError.unavailable }
          next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else { throw CodeComparisonFileError.unsafe }
        Darwin.close(fd)
        fd = next
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == geteuid() || info.st_uid == 0,
          (info.st_mode & 0o022) == 0 || (info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0)
        else { throw CodeComparisonFileError.unsafe }
        if index == parts.count - 1 {
          guard info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o700 else {
            throw CodeComparisonFileError.unsafe
          }
        }
      }
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  static func connection(_ setup: CodeComparisonSetup) throws -> Int32 {
    let fd = try directory(setup.directory)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_dev == setup.device, info.st_ino == setup.inode else {
      Darwin.close(fd)
      throw CodeComparisonFileError.unsafe
    }
    return fd
  }

  static func read(_ name: String, in directory: Int32, limit: Int) throws -> Data {
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw CodeComparisonFileError.unavailable }
    defer { Darwin.close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == geteuid(), before.st_nlink == 1, (before.st_mode & 0o022) == 0,
      before.st_size > 0, before.st_size <= limit
    else { throw CodeComparisonFileError.unsafe }
    var data = Data(count: Int(before.st_size) + 1)
    let capacity = data.count
    let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
    var after = stat()
    var named = stat()
    guard count == before.st_size, fstat(fd, &after) == 0,
      fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      before.st_dev == named.st_dev, before.st_ino == named.st_ino,
      (named.st_mode & S_IFMT) == S_IFREG
    else { throw CodeComparisonFileError.unsafe }
    data.count = count
    guard String(data: data, encoding: .utf8) != nil else { throw CodeComparisonFileError.unsafe }
    return data
  }

  static func names(in fd: Int32) throws -> [String] {
    let copy = dup(fd)
    guard copy >= 0 else { throw CodeComparisonFileError.unavailable }
    guard let directory = fdopendir(copy) else {
      Darwin.close(copy)
      throw CodeComparisonFileError.unavailable
    }
    defer { closedir(directory) }
    var names: [String] = []
    errno = 0
    while let pointer = readdir(directory) {
      var entry = pointer.pointee
      let name = withUnsafePointer(to: &entry.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if name != "." && name != ".." { names.append(name) }
      guard names.count <= 32 else { throw CodeComparisonFileError.unsafe }
      errno = 0
    }
    guard errno == 0 else { throw CodeComparisonFileError.unavailable }
    return names
  }

  static func streamID(_ name: String) -> String? {
    guard name.hasPrefix("stream-"), name.hasSuffix(".json") else { return nil }
    let id = String(name.dropFirst(7).dropLast(5))
    return CodeComparisonProtocol.uuid(id) ? id : nil
  }

  // A quit/revocation removes only this exact grant; no actor/network wait.
  static func revokeGrant(_ setup: CodeComparisonSetup) -> Bool {
    do {
      let fd = try connection(setup)
      defer { Darwin.close(fd) }
      var info = stat()
      if fstatat(fd, "probe-grant.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
        return errno == ENOENT
      }
      guard try read("probe-grant.json", in: fd, limit: 1_024) == setup.grant else { return false }
      return unlinkat(fd, "probe-grant.json", 0) == 0
    } catch { return false }
  }
}

// Grant creation and synchronous shutdown share a gate; a delayed actor reply
// cannot leave a connectable grant after normal application termination.
final class CodeComparisonGrantGate: @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  private var grants: [String: CodeComparisonSetup] = [:]

  func write(_ setup: CodeComparisonSetup, in directory: Int32) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { throw CodeComparisonFileError.unavailable }
    let file = openat(
      directory, "probe-grant.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw CodeComparisonFileError.unavailable }
    defer { Darwin.close(file) }
    let written = setup.grant.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
    guard written == setup.grant.count else {
      _ = unlinkat(directory, "probe-grant.json", 0)
      throw CodeComparisonFileError.unavailable
    }
    grants[setup.connectionID] = setup
  }

  func forget(_ id: String) {
    lock.lock()
    defer { lock.unlock() }
    grants.removeValue(forKey: id)
  }

  func terminate() {
    lock.lock()
    closed = true
    let pending = Array(grants.values)
    grants.removeAll()
    lock.unlock()
    for grant in pending { _ = CodeComparisonFiles.revokeGrant(grant) }
  }
}

actor CodeComparisonSession: CodeComparisonServing {
  nonisolated private let grants = CodeComparisonGrantGate()
  private let base: URL
  private var setup: CodeComparisonSetup?
  private var decoder: CodeComparisonDecoder?
  private var boundStream: String?
  private var multipleStreams = false
  private var clockWatermark = Date.distantPast

  init(directory: URL) { base = directory }

  nonisolated func terminate() { grants.terminate() }

  func prepare(now: Date) throws -> CodeComparisonSetup {
    guard now.timeIntervalSince1970.isFinite else { throw CodeComparisonFileError.unsafe }
    if let previous = setup {
      guard revoke(connectionID: previous.connectionID) else {
        throw CodeComparisonFileError.unsafe
      }
    }
    let parent = try CodeComparisonFiles.directory(base, create: true)
    defer { Darwin.close(parent) }
    let name = UUID().uuidString.lowercased()
    guard mkdirat(parent, name, 0o700) == 0 else { throw CodeComparisonFileError.unavailable }
    var completed = false
    defer { if !completed { _ = unlinkat(parent, name, AT_REMOVEDIR) } }
    let path = base.appendingPathComponent(name, isDirectory: true)
    let fd = try CodeComparisonFiles.directory(path)
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw CodeComparisonFileError.unsafe }
    let id = UUID().uuidString.lowercased()
    let grant = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1, "purpose": "quotatempo-mods-comparison", "connectionID": id,
        "createdAt": CodeComparisonProtocol.timestamp(now),
      ], options: [.sortedKeys])
    let result = CodeComparisonSetup(
      directory: path, connectionID: id, grant: grant, device: info.st_dev, inode: info.st_ino)
    try grants.write(result, in: fd)
    completed = true
    setup = result
    decoder = nil
    boundStream = nil
    multipleStreams = false
    clockWatermark = now
    return result
  }

  func poll(connectionID: String, clock: @Sendable () -> Date) -> CodeUsageComparisonView {
    guard let setup, setup.connectionID == connectionID else {
      return CodeUsageComparisonView(status: .disconnected)
    }
    let started = clock()
    guard started.timeIntervalSince1970.isFinite, started >= clockWatermark else {
      _ = decoder?.unavailable()
      return CodeUsageComparisonView(status: .invalidClock)
    }
    if multipleStreams { return CodeUsageComparisonView(status: .multipleSessions) }
    do {
      let fd = try CodeComparisonFiles.connection(setup)
      defer { Darwin.close(fd) }
      let names = try CodeComparisonFiles.names(in: fd)
      guard names.contains("probe-grant.json"),
        try CodeComparisonFiles.read("probe-grant.json", in: fd, limit: 1_024) == setup.grant
      else {
        _ = decoder?.unavailable()
        return CodeUsageComparisonView(status: .disconnected)
      }
      let streamNames = names.filter { $0 != "probe-grant.json" }
      guard streamNames.allSatisfy({ CodeComparisonFiles.streamID($0) != nil }) else {
        _ = decoder?.unavailable()
        return CodeUsageComparisonView(status: .storageUnavailable)
      }
      if streamNames.count > 1 {
        multipleStreams = true
        _ = decoder?.unavailable()
        return CodeUsageComparisonView(status: .multipleSessions)
      }
      guard let name = streamNames.first, let stream = CodeComparisonFiles.streamID(name) else {
        _ = decoder?.unavailable()
        let completed = clock()
        guard completed.timeIntervalSince1970.isFinite, completed >= started else {
          return CodeUsageComparisonView(status: .invalidClock)
        }
        clockWatermark = completed
        if boundStream != nil { return CodeUsageComparisonView(status: .unavailable) }
        let created = (try? JSONSerialization.jsonObject(with: setup.grant)) as? [String: Any]
        let expired =
          CodeComparisonProtocol.date(created?["createdAt"]).map {
            completed.timeIntervalSince($0) > 900
          } ?? true
        return CodeUsageComparisonView(status: expired ? .stale : .waitingForConnection)
      }
      guard boundStream == nil || boundStream == stream else {
        multipleStreams = true
        _ = decoder?.unavailable()
        return CodeUsageComparisonView(status: .multipleSessions)
      }
      let data = try CodeComparisonFiles.read(
        name, in: fd, limit: CodeComparisonProtocol.maximumBytes)
      let completed = clock()
      guard completed.timeIntervalSince1970.isFinite, completed >= started else {
        _ = decoder?.unavailable()
        return CodeUsageComparisonView(status: .invalidClock)
      }
      clockWatermark = completed
      if decoder == nil {
        boundStream = stream
        decoder = CodeComparisonDecoder(connectionID: setup.connectionID, streamID: stream)
      }
      return decoder!.consume(data, now: completed)
    } catch {
      _ = decoder?.unavailable()
      return CodeUsageComparisonView(status: .unavailable)
    }
  }

  func revoke(connectionID: String) -> Bool {
    guard let current = setup, current.connectionID == connectionID else { return true }
    decoder = nil
    boundStream = nil
    multipleStreams = false
    // Revoke even when unknown files prevent full cleanup. Never delete them.
    guard CodeComparisonFiles.revokeGrant(current) else { return false }
    grants.forget(current.connectionID)
    setup = nil
    do {
      let fd = try CodeComparisonFiles.connection(current)
      defer { Darwin.close(fd) }
      let names = try CodeComparisonFiles.names(in: fd)
      guard names.allSatisfy({ CodeComparisonFiles.streamID($0) != nil }) else { return false }
      for name in names {
        // Inspection rejects symlinks, hardlinks, directories and unsafe modes.
        _ = try CodeComparisonFiles.read(name, in: fd, limit: CodeComparisonProtocol.maximumBytes)
        guard unlinkat(fd, name, 0) == 0 else { return false }
      }
      let parent = try CodeComparisonFiles.directory(base)
      defer { Darwin.close(parent) }
      guard unlinkat(parent, current.directory.lastPathComponent, AT_REMOVEDIR) == 0 else {
        return false
      }
      return true
    } catch { return false }
  }
}

@MainActor
final class CodeUsageComparisonController: ObservableObject {
  @Published private(set) var view = CodeUsageComparisonView(status: .disconnected)
  @Published private(set) var isBusy = false
  @Published private(set) var command: String?
  @Published private(set) var pluginPackage: CodeComparisonPluginCommands?
  private let service: any CodeComparisonServing
  private let clock: @Sendable () -> Date
  private var setup: CodeComparisonSetup?
  private var generation = 0
  private var enabled = true

  init(
    service: (any CodeComparisonServing)? = nil,
    clock: @escaping @Sendable () -> Date = Date.init
  ) {
    self.service =
      service
      ?? CodeComparisonIPCSession(clock: clock)
    self.clock = clock
  }

  func rememberPluginPackage(_ package: CodeComparisonPluginCommands) {
    pluginPackage = package
  }

  func prepare() async {
    guard enabled, !isBusy else { return }
    generation += 1
    let revision = generation
    view = CodeUsageComparisonView(status: .preparing)
    command = nil
    isBusy = true
    defer { if generation == revision { isBusy = false } }
    let ticket = service.preparationTicket()
    do {
      let prepared = try await service.prepare(now: clock(), ticket: ticket)
      guard enabled, generation == revision else {
        _ = await service.revoke(connectionID: prepared.connectionID)
        return
      }
      setup = prepared
      command = prepared.command
      view = CodeUsageComparisonView(status: .waitingForConnection)
    } catch {
      guard generation == revision else { return }
      view = CodeUsageComparisonView(status: .storageUnavailable)
    }
  }

  func refresh() async {
    guard enabled, !isBusy, let setup else { return }
    let revision = generation
    isBusy = true
    defer { if generation == revision { isBusy = false } }
    let result = await service.poll(connectionID: setup.connectionID, clock: clock)
    guard enabled, generation == revision else { return }
    view = result
  }

  func disconnect() async {
    service.cancelPreparation()
    generation += 1
    let revision = generation
    let previous = setup
    setup = nil
    command = nil
    view = CodeUsageComparisonView(status: .disconnected)
    isBusy = false
    if let previous { service.revokeImmediately(connectionID: previous.connectionID) }
    if let previous, !(await service.revoke(connectionID: previous.connectionID)),
      generation == revision
    {
      view = CodeUsageComparisonView(status: .storageUnavailable)
    }
  }

  func setEnabled(_ value: Bool) {
    enabled = value
    if !value {
      service.cancelPreparation()
      let previous = setup
      generation += 1
      setup = nil
      command = nil
      view = CodeUsageComparisonView(status: .disconnected)
      isBusy = false
      if let previous {
        service.revokeImmediately(connectionID: previous.connectionID)
        _ = CodeComparisonFiles.revokeGrant(previous)
        Task { _ = await service.revoke(connectionID: previous.connectionID) }
      }
    }
  }

  func applicationWillTerminate() {
    generation += 1
    view = CodeUsageComparisonView(status: .disconnected)
    command = nil
    service.terminate()
    setup = nil
  }
}
