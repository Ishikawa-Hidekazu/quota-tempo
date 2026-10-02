import Darwin
import Foundation

protocol DesktopThrottleStoring: Sendable {
  func load() throws -> DesktopThrottleRecord?
  func save(_ record: DesktopThrottleRecord) throws
}

enum DesktopThrottleStoreError: Error, Equatable, Sendable {
  case unavailable
  case unsafePath
  case locked
  case missingRecord
  case changed
  case inputTooLarge
  case invalidRecord
  case ioFailure
}

enum DesktopThrottleRecoveryResult: Equatable, Sendable {
  case notNeeded
  case preserved
  case repaired
  case unsupportedVersion
}

// Retain this store for the process lifetime. Closing it releases, but never
// removes, the lock file. All persisted fields are explicitly listed below.
final class DesktopThrottleFileStore: DesktopThrottleStoring, @unchecked Sendable {
  private static let recordName = "desktop-throttle.json"
  private static let lockName = "desktop-throttle.lock"
  private static let maximumBytes = 4096

  // Narrow syscall seams for synthetic short-write/EINTR and durability tests.
  struct IO: Sendable {
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = {
      Darwin.write($0, $1, $2)
    }
    var sync: @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }
    var rename: @Sendable (Int32, String, Int32, String) -> Int32 = {
      Darwin.renameat($0, $1, $2, $3)
    }
  }

  private struct Identity: Equatable {
    let device: Int32
    let inode: UInt64

    init(_ info: stat) {
      device = info.st_dev
      inode = info.st_ino
    }
  }

  private let directory: URL
  private let directoryFD: Int32
  private let ancestry: [Identity]
  private let lockFD: Int32
  private var lockStamp: DesktopFileStamp
  private let io: IO
  private let mutex = NSLock()
  private var hasSeenRecord = false
  private var recordStamp: DesktopFileStamp?
  private var uncertainCommit = false

  static func applicationSupport(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> DesktopThrottleFileStore {
    try applicationSupport(homeDirectory: homeDirectory, recovering: false)
  }

  // Explicit offline operation: acquiring the same lifetime flock refuses a
  // running owner. Recovery never removes the lock or enables automatic requests.
  static func recoverApplicationSupport(
    now: Date, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> DesktopThrottleRecoveryResult {
    let store = try applicationSupport(homeDirectory: homeDirectory, recovering: true)
    return try store.recover(now: now)
  }

  static func recover(directory: URL, now: Date) throws -> DesktopThrottleRecoveryResult {
    let store = try DesktopThrottleFileStore(directory: directory, io: IO(), recovering: true)
    return try store.recover(now: now)
  }

  private static func applicationSupport(
    homeDirectory: URL, recovering: Bool
  ) throws -> DesktopThrottleFileStore {
    let parentURL = homeDirectory.appendingPathComponent(
      "Library/Application Support", isDirectory: true)
    let parent = try openDirectory(parentURL)
    defer { Darwin.close(parent.fd) }
    let childName = "QuotaTempoDesktopPreview"
    if mkdirat(parent.fd, childName, 0o700) != 0 {
      guard errno == EEXIST else { throw DesktopThrottleStoreError.ioFailure }
    }
    let child = openat(parent.fd, childName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard child >= 0 else { throw DesktopThrottleStoreError.unsafePath }
    defer { Darwin.close(child) }
    var info = stat()
    guard fstat(child, &info) == 0 else { throw DesktopThrottleStoreError.ioFailure }
    try validateDirectory(info, final: true)
    guard info.st_mode & 0o7777 == 0o700 else { throw DesktopThrottleStoreError.unsafePath }
    while Darwin.fsync(parent.fd) != 0 {
      guard errno == EINTR else { throw DesktopThrottleStoreError.ioFailure }
    }
    let checked = try openDirectory(parentURL)
    defer { Darwin.close(checked.fd) }
    guard checked.ancestry == parent.ancestry else { throw DesktopThrottleStoreError.changed }
    let store = try DesktopThrottleFileStore(
      directory: parentURL.appendingPathComponent(childName, isDirectory: true),
      io: IO(), recovering: recovering)
    // The path-based initializer must have opened the same parent and child.
    guard store.ancestry == parent.ancestry + [Identity(info)] else {
      throw DesktopThrottleStoreError.changed
    }
    try store.validateEnvironment()
    return store
  }

  convenience init(directory: URL, io: IO = IO()) throws {
    try self.init(directory: directory, io: io, recovering: false)
  }

  private init(directory: URL, io: IO, recovering: Bool) throws {
    let opened = try Self.openDirectory(directory)
    var retained = false
    defer { if !retained { Darwin.close(opened.fd) } }
    let lock = openat(
      opened.fd, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard lock >= 0 else { throw DesktopThrottleStoreError.unavailable }
    defer { if !retained { Darwin.close(lock) } }
    let info = try Self.fileInfo(lock, maximumBytes: 1)
    if info.st_size == 1 {
      var marker: UInt8 = 0
      guard pread(lock, &marker, 1, 0) == 1, marker == 1 else {
        throw DesktopThrottleStoreError.invalidRecord
      }
    }
    let stamp = DesktopFileStamp(info)
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      throw DesktopThrottleStoreError.locked
    }
    try Self.requireFile(opened.fd, name: Self.lockName, stamp: stamp, maximumBytes: 1)
    let checked = try Self.openDirectory(directory)
    defer { Darwin.close(checked.fd) }
    guard checked.ancestry == opened.ancestry else { throw DesktopThrottleStoreError.changed }
    // Observe existence at construction, without reading a body, so deletion
    // before the first load cannot turn a persisted store into a fresh one.
    var existing = stat()
    let initialStamp: DesktopFileStamp?
    if fstatat(opened.fd, Self.recordName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
      try Self.validateFile(existing, maximumBytes: Self.maximumBytes)
      initialStamp = DesktopFileStamp(existing)
    } else {
      guard errno == ENOENT else { throw DesktopThrottleStoreError.unsafePath }
      guard recovering || info.st_size == 0 else { throw DesktopThrottleStoreError.missingRecord }
      initialStamp = nil
    }
    self.directory = directory
    directoryFD = opened.fd
    ancestry = opened.ancestry
    lockFD = lock
    lockStamp = stamp
    self.io = io
    recordStamp = initialStamp
    hasSeenRecord = (!recovering && info.st_size == 1) || initialStamp != nil
    retained = true
  }

  deinit {
    Darwin.close(lockFD)
    Darwin.close(directoryFD)
  }

  func load() throws -> DesktopThrottleRecord? {
    mutex.lock()
    defer { mutex.unlock() }
    guard let data = try readData() else { return nil }
    let record = try Self.decode(data)
    try markInitialized()
    return record
  }

  private static func decode(_ data: Data) throws -> DesktopThrottleRecord {
    do {
      let record = try JSONDecoder().decode(Metadata.self, from: data).record
      guard record.schemaVersion == 1, record.isValid else {
        throw DesktopThrottleStoreError.invalidRecord
      }
      return record
    } catch {
      // Never propagate decoder diagnostics containing stored values or paths.
      throw DesktopThrottleStoreError.invalidRecord
    }
  }

  private func readData() throws -> Data? {
    guard !uncertainCommit else { throw DesktopThrottleStoreError.ioFailure }
    try validateEnvironment()
    guard let before = try observeRecord() else {
      try validateEnvironment()
      return nil
    }
    let fd = openat(directoryFD, Self.recordName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw DesktopThrottleStoreError.changed }
    defer { Darwin.close(fd) }
    guard DesktopFileStamp(try Self.fileInfo(fd, maximumBytes: Self.maximumBytes)) == before else {
      throw DesktopThrottleStoreError.changed
    }
    // One extra byte detects growth without ever allocating an unbounded body.
    var data = Data(count: Int(before.size) + 1)
    let capacity = data.count
    let count = try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < capacity {
        let readCount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), capacity - offset)
        if readCount < 0 && errno == EINTR { continue }
        guard readCount >= 0 else { throw DesktopThrottleStoreError.ioFailure }
        if readCount == 0 { break }
        offset += readCount
      }
      return offset
    }
    guard count == Int(before.size),
      DesktopFileStamp(try Self.fileInfo(fd, maximumBytes: Self.maximumBytes)) == before
    else { throw DesktopThrottleStoreError.changed }
    try Self.requireFile(
      directoryFD, name: Self.recordName, stamp: before, maximumBytes: Self.maximumBytes)
    try validateEnvironment()
    data.count = count
    return data
  }

  private func recover(now: Date) throws -> DesktopThrottleRecoveryResult {
    // This private instance cannot escape; its flock spans inspection and save.
    let data = try readData()
    // No checkpoint and no durable initialization marker means unused, not lost.
    // Keep the validated lifetime lock, but do not invent a wait or initialize it.
    if data == nil, lockStamp.size == 0 { return .notNeeded }
    let inspected = recordStamp
    if let data {
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["schemaVersion"] != nil
      {
        struct Version: Decodable { let schemaVersion: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else {
          throw DesktopThrottleStoreError.invalidRecord
        }
        guard version.schemaVersion == 1 else { return .unsupportedVersion }
      }
      if (try? Self.decode(data)) != nil {
        try markInitialized()
        return .preserved
      }
    }
    guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0 else {
      throw DesktopThrottleStoreError.invalidRecord
    }
    let recovered = data.flatMap { try? JSONDecoder().decode(RecoveryMetadata.self, from: $0) }
    let reference = max(now, recovered?.recordedAt ?? now, recovered?.lastAttemptAt ?? now)
    let floor = reference.addingTimeInterval(15 * 60)
    let record = DesktopThrottleRecord(
      recordedAt: reference, lastAttemptAt: reference,
      localNextAllowedAt: max(floor, recovered?.localNextAllowedAt ?? floor),
      successfulNextAllowedAt: recovered?.successfulNextAllowedAt,
      serviceNotBefore: recovered?.serviceNotBefore, unsupportedServiceWait: true,
      failureCount: 0, interruptedUntil: max(floor, recovered?.interruptedUntil ?? floor),
      authRefusal: recovered?.authRefusal, authRefusalExpiresAt: recovered?.authRefusalExpiresAt)
    // Unrepresentable retained deadlines fail closed rather than being shortened.
    try save(record, repairing: true, expectedRecord: inspected)
    return .repaired
  }

  func save(_ record: DesktopThrottleRecord) throws {
    try save(record, repairing: false)
  }

  private func save(
    _ record: DesktopThrottleRecord, repairing: Bool, expectedRecord: DesktopFileStamp? = nil
  ) throws {
    mutex.lock()
    defer { mutex.unlock() }
    guard !uncertainCommit else { throw DesktopThrottleStoreError.ioFailure }
    guard record.schemaVersion == 1, record.isValid else {
      throw DesktopThrottleStoreError.invalidRecord
    }
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(Metadata(record))
    } catch {
      throw DesktopThrottleStoreError.invalidRecord
    }
    guard data.count <= Self.maximumBytes else { throw DesktopThrottleStoreError.inputTooLarge }
    try validateEnvironment()
    let previous = try observeRecord()
    if repairing, previous != expectedRecord { throw DesktopThrottleStoreError.changed }
    if !repairing, let data = try readData() {
      _ = try Self.decode(data)
    }
    let temporaryName = ".desktop-throttle-\(UUID().uuidString).tmp"
    let fd = openat(
      directoryFD, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw DesktopThrottleStoreError.ioFailure }
    defer { Darwin.close(fd) }
    var created = stat()
    guard fstat(fd, &created) == 0 else { throw DesktopThrottleStoreError.ioFailure }
    var renamed = false
    defer {
      if !renamed {
        Self.removeOwnTemporary(directoryFD, name: temporaryName, identity: Identity(created))
      }
    }
    _ = try Self.fileInfo(fd, maximumBytes: 0)
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = io.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if written < 0 && errno == EINTR { continue }
        guard written > 0, written <= buffer.count - offset else {
          throw DesktopThrottleStoreError.ioFailure
        }
        offset += written
      }
    }
    try sync(fd)
    let ready = DesktopFileStamp(try Self.fileInfo(fd, maximumBytes: Self.maximumBytes))
    guard ready.size == Int64(data.count) else { throw DesktopThrottleStoreError.changed }
    try validateEnvironment()
    guard try observeRecord() == previous else { throw DesktopThrottleStoreError.changed }
    try Self.requireFile(
      directoryFD, name: temporaryName, stamp: ready, maximumBytes: Self.maximumBytes)
    guard io.rename(directoryFD, temporaryName, directoryFD, Self.recordName) == 0 else {
      throw DesktopThrottleStoreError.ioFailure
    }
    renamed = true
    hasSeenRecord = true
    // A post-rename error is not a rollback. Fail closed for this store instance
    // until its owner restarts and reads the committed file under a new lock.
    uncertainCommit = true
    let committed = DesktopFileStamp(try Self.fileInfo(fd, maximumBytes: Self.maximumBytes))
    recordStamp = committed
    try sync(directoryFD)
    try Self.requireFile(
      directoryFD, name: Self.recordName, stamp: committed, maximumBytes: Self.maximumBytes)
    try validateEnvironment()
    try markInitialized()
    uncertainCommit = false
  }

  // This byte outlives record replacement and detects a lost checkpoint after
  // restart. An empty lock is valid only before a first successful load/save.
  private func markInitialized() throws {
    if lockStamp.size == 1 { return }
    var marker: UInt8 = 1
    while pwrite(lockFD, &marker, 1, 0) != 1 {
      guard errno == EINTR else { throw DesktopThrottleStoreError.ioFailure }
    }
    while Darwin.fsync(lockFD) != 0 {
      guard errno == EINTR else { throw DesktopThrottleStoreError.ioFailure }
    }
    lockStamp = DesktopFileStamp(try Self.fileInfo(lockFD, maximumBytes: 1))
    try Self.requireFile(directoryFD, name: Self.lockName, stamp: lockStamp, maximumBytes: 1)
  }

  private func sync(_ fd: Int32) throws {
    while io.sync(fd) != 0 {
      guard errno == EINTR else { throw DesktopThrottleStoreError.ioFailure }
    }
  }

  private func observeRecord() throws -> DesktopFileStamp? {
    var info = stat()
    guard fstatat(directoryFD, Self.recordName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      guard errno == ENOENT else { throw DesktopThrottleStoreError.unsafePath }
      guard !hasSeenRecord else { throw DesktopThrottleStoreError.missingRecord }
      return nil
    }
    hasSeenRecord = true
    try Self.validateFile(info, maximumBytes: Self.maximumBytes)
    let current = DesktopFileStamp(info)
    guard recordStamp == nil || recordStamp == current else {
      throw DesktopThrottleStoreError.changed
    }
    recordStamp = current
    return current
  }

  private func validateEnvironment() throws {
    let current = try Self.openDirectory(directory)
    defer { Darwin.close(current.fd) }
    var info = stat()
    guard current.ancestry == ancestry, fstat(directoryFD, &info) == 0,
      Identity(info) == ancestry.last
    else { throw DesktopThrottleStoreError.changed }
    try Self.validateDirectory(info, final: true)
    guard DesktopFileStamp(try Self.fileInfo(lockFD, maximumBytes: 1)) == lockStamp else {
      throw DesktopThrottleStoreError.changed
    }
    try Self.requireFile(directoryFD, name: Self.lockName, stamp: lockStamp, maximumBytes: 1)
  }

  private static func openDirectory(_ url: URL) throws -> (fd: Int32, ancestry: [Identity]) {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.path.hasPrefix("/"), !url.path.utf8.contains(0)
    else { throw DesktopThrottleStoreError.unsafePath }
    let components = url.path.split(separator: "/").map(String.init)
    guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
      throw DesktopThrottleStoreError.unsafePath
    }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DesktopThrottleStoreError.unavailable }
    var retained = false
    defer { if !retained { Darwin.close(fd) } }
    var root = stat()
    guard fstat(fd, &root) == 0 else { throw DesktopThrottleStoreError.unavailable }
    try validateDirectory(root, final: false)
    var ancestry = [Identity(root)]
    for (index, component) in components.enumerated() {
      let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw DesktopThrottleStoreError.unsafePath }
      Darwin.close(fd)
      fd = next
      var info = stat()
      guard fstat(fd, &info) == 0 else { throw DesktopThrottleStoreError.unavailable }
      try validateDirectory(info, final: index == components.count - 1)
      ancestry.append(Identity(info))
    }
    retained = true
    return (fd, ancestry)
  }

  private static func validateDirectory(_ info: stat, final: Bool) throws {
    let stickySystemAncestor = !final && info.st_uid == 0 && info.st_mode & S_ISVTX != 0
    guard info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid() || (!final && info.st_uid == 0),
      info.st_mode & 0o022 == 0 || stickySystemAncestor
    else { throw DesktopThrottleStoreError.unsafePath }
  }

  private static func fileInfo(_ fd: Int32, maximumBytes: Int) throws -> stat {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw DesktopThrottleStoreError.ioFailure }
    try validateFile(info, maximumBytes: maximumBytes)
    return info
  }

  static func validateFile(_ info: stat, maximumBytes: Int) throws {
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
      info.st_mode & 0o7777 == 0o600
    else { throw DesktopThrottleStoreError.unsafePath }
    guard info.st_size >= 0, info.st_size <= Int64(maximumBytes) else {
      throw DesktopThrottleStoreError.inputTooLarge
    }
  }

  private static func requireFile(
    _ directoryFD: Int32, name: String, stamp: DesktopFileStamp, maximumBytes: Int
  ) throws {
    var info = stat()
    guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw DesktopThrottleStoreError.changed
    }
    try validateFile(info, maximumBytes: maximumBytes)
    guard DesktopFileStamp(info) == stamp else { throw DesktopThrottleStoreError.changed }
  }

  private static func removeOwnTemporary(_ directoryFD: Int32, name: String, identity: Identity) {
    var info = stat()
    guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
      Identity(info) == identity
    else { return }
    _ = unlinkat(directoryFD, name, 0)
  }

  // Separate wire representation prevents future coordinator fields from being
  // persisted by accident. Dates use Codable's reference-date numeric encoding.
  private struct Metadata: Codable {
    let schemaVersion: Int
    let recordedAt: Date
    let lastAttemptAt: Date?
    let localNextAllowedAt: Date?
    let successfulNextAllowedAt: Date?
    let serviceNotBefore: Date?
    let unsupportedServiceWait: Bool
    let failureCount: Int
    let interruptedUntil: Date?
    let authRefusal: DesktopAuthRefusal?
    let authRefusalExpiresAt: Date?

    enum CodingKeys: String, CodingKey, CaseIterable {
      case schemaVersion, recordedAt, lastAttemptAt, localNextAllowedAt
      case successfulNextAllowedAt, serviceNotBefore, unsupportedServiceWait
      case failureCount, interruptedUntil, authRefusal, authRefusalExpiresAt
    }

    private struct AnyKey: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init?(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { return nil }
    }

    init(_ record: DesktopThrottleRecord) {
      schemaVersion = record.schemaVersion
      recordedAt = record.recordedAt
      lastAttemptAt = record.lastAttemptAt
      localNextAllowedAt = record.localNextAllowedAt
      successfulNextAllowedAt = record.successfulNextAllowedAt
      serviceNotBefore = record.serviceNotBefore
      unsupportedServiceWait = record.unsupportedServiceWait
      failureCount = record.failureCount
      interruptedUntil = record.interruptedUntil
      authRefusal = record.authRefusal
      authRefusalExpiresAt = record.authRefusalExpiresAt
    }

    init(from decoder: Decoder) throws {
      let keys = try decoder.container(keyedBy: AnyKey.self)
      let allowed = Set(CodingKeys.allCases.map(\.rawValue))
      guard keys.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DesktopThrottleStoreError.invalidRecord
      }
      let values = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
      recordedAt = try values.decode(Date.self, forKey: .recordedAt)
      lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
      localNextAllowedAt = try values.decodeIfPresent(Date.self, forKey: .localNextAllowedAt)
      successfulNextAllowedAt = try values.decodeIfPresent(
        Date.self, forKey: .successfulNextAllowedAt)
      serviceNotBefore = try values.decodeIfPresent(Date.self, forKey: .serviceNotBefore)
      unsupportedServiceWait = try values.decode(Bool.self, forKey: .unsupportedServiceWait)
      failureCount = try values.decode(Int.self, forKey: .failureCount)
      interruptedUntil = try values.decodeIfPresent(Date.self, forKey: .interruptedUntil)
      authRefusal = try values.decodeIfPresent(DesktopAuthRefusal.self, forKey: .authRefusal)
      authRefusalExpiresAt = try values.decodeIfPresent(Date.self, forKey: .authRefusalExpiresAt)
    }

    var record: DesktopThrottleRecord {
      DesktopThrottleRecord(
        schemaVersion: schemaVersion, recordedAt: recordedAt, lastAttemptAt: lastAttemptAt,
        localNextAllowedAt: localNextAllowedAt, successfulNextAllowedAt: successfulNextAllowedAt,
        serviceNotBefore: serviceNotBefore, unsupportedServiceWait: unsupportedServiceWait,
        failureCount: failureCount, interruptedUntil: interruptedUntil, authRefusal: authRefusal,
        authRefusalExpiresAt: authRefusalExpiresAt)
    }
  }

  // Salvage known constraints independently of unrelated corrupt fields. Invalid
  // expiry becomes nil (indefinite refusal), never permission to retry sooner.
  private struct RecoveryMetadata: Decodable {
    let recordedAt: Date?
    let lastAttemptAt: Date?
    let localNextAllowedAt: Date?
    let successfulNextAllowedAt: Date?
    let serviceNotBefore: Date?
    let interruptedUntil: Date?
    let authRefusal: DesktopAuthRefusal?
    let authRefusalExpiresAt: Date?

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: Metadata.CodingKeys.self)
      func date(_ key: Metadata.CodingKeys) -> Date? {
        guard let value = try? values.decode(Date.self, forKey: key),
          value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 > 0
        else { return nil }
        return value
      }
      recordedAt = date(.recordedAt)
      lastAttemptAt = date(.lastAttemptAt)
      localNextAllowedAt = date(.localNextAllowedAt)
      successfulNextAllowedAt = date(.successfulNextAllowedAt)
      serviceNotBefore = date(.serviceNotBefore)
      interruptedUntil = date(.interruptedUntil)
      authRefusal = try? values.decode(DesktopAuthRefusal.self, forKey: .authRefusal)
      authRefusalExpiresAt = authRefusal == nil ? nil : date(.authRefusalExpiresAt)
    }
  }
}
