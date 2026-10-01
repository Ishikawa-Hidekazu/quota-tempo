import Darwin
import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

private let throttleNow = Date(timeIntervalSince1970: 1_900_000_000)

private func throttleRecord() -> DesktopThrottleRecord {
  DesktopThrottleRecord(
    recordedAt: throttleNow, lastAttemptAt: throttleNow.addingTimeInterval(-1),
    localNextAllowedAt: throttleNow.addingTimeInterval(60),
    successfulNextAllowedAt: throttleNow.addingTimeInterval(300),
    serviceNotBefore: throttleNow.addingTimeInterval(600), unsupportedServiceWait: true,
    failureCount: 3, interruptedUntil: throttleNow.addingTimeInterval(30),
    authRefusal: .accessDenied)
}

private final class ThrottleFixture {
  let directory: URL
  var recordURL: URL { directory.appendingPathComponent("desktop-throttle.json") }
  var lockURL: URL { directory.appendingPathComponent("desktop-throttle.lock") }

  init(mode: Int = 0o700) throws {
    directory = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("QuotaTempo-Throttle-Synthetic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func write(_ data: Data, to url: URL? = nil, mode: mode_t = 0o600) throws {
    let destination = url ?? recordURL
    try data.write(to: destination)
    guard chmod(destination.path, mode) == 0 else { throw DesktopThrottleStoreError.ioFailure }
  }

  func writeRecord(_ record: DesktopThrottleRecord = throttleRecord()) throws {
    try write(JSONEncoder().encode(record))
  }

  func names() throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
  }
}

private final class ThrottleCounter: @unchecked Sendable {
  private let mutex = NSLock()
  private var value = 0

  func next() -> Int {
    mutex.lock()
    defer { mutex.unlock() }
    value += 1
    return value
  }
}

@Suite("Desktop restart throttle metadata store")
struct DesktopThrottleStoreTests {
  @Test func applicationSupportCreatesOnlyPrivateCandidateDirectory() throws {
    let fixture = try ThrottleFixture()
    let library = fixture.directory.appendingPathComponent("Library")
    let support = library.appendingPathComponent("Application Support")
    try FileManager.default.createDirectory(
      at: library, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let existing = support.appendingPathComponent("QuotaTempo")
    try FileManager.default.createDirectory(
      at: existing, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let sentinel = existing.appendingPathComponent("synthetic-public-data")
    let bytes = Data("untouched-synthetic-data".utf8)
    try bytes.write(to: sentinel)
    var first: DesktopThrottleFileStore? = try .applicationSupport(homeDirectory: fixture.directory)
    let candidate = support.appendingPathComponent("QuotaTempoDesktopPreview")
    var info = stat()
    #expect(lstat(candidate.path, &info) == 0)
    #expect(info.st_uid == geteuid())
    #expect(info.st_mode & 0o7777 == 0o700)
    #expect(try first?.load() == nil)
    try first?.save(throttleRecord())
    #expect(throws: DesktopThrottleStoreError.locked) {
      try DesktopThrottleFileStore.applicationSupport(homeDirectory: fixture.directory)
    }
    first = nil
    let restarted = try DesktopThrottleFileStore.applicationSupport(
      homeDirectory: fixture.directory)
    #expect(try restarted.load() == throttleRecord())
    #expect(try Data(contentsOf: sentinel) == bytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: existing.path) == [
        "synthetic-public-data"
      ])
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: support.path))
        == ["QuotaTempo", "QuotaTempoDesktopPreview"])
  }

  @Test(arguments: [false, true])
  func applicationSupportNeverCreatesMissingAncestors(libraryExists: Bool) throws {
    let fixture = try ThrottleFixture()
    let library = fixture.directory.appendingPathComponent("Library")
    if libraryExists {
      try FileManager.default.createDirectory(
        at: library, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    #expect(throws: DesktopThrottleStoreError.unsafePath) {
      try DesktopThrottleFileStore.applicationSupport(homeDirectory: fixture.directory)
    }
    #expect(try fixture.names() == (libraryExists ? ["Library"] : []))
    if libraryExists {
      #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }
  }

  @Test(arguments: ["parent-mode", "parent-link", "child-link", "child-mode"])
  func applicationSupportRejectsUnsafePaths(kind: String) throws {
    let fixture = try ThrottleFixture()
    let library = fixture.directory.appendingPathComponent("Library")
    let support = library.appendingPathComponent("Application Support")
    try FileManager.default.createDirectory(
      at: library, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let target = fixture.directory.appendingPathComponent("synthetic-link-target")
    try FileManager.default.createDirectory(
      at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let child = support.appendingPathComponent("QuotaTempoDesktopPreview")
    switch kind {
    case "parent-mode":
      #expect(chmod(support.path, 0o777) == 0)
    case "parent-link":
      try FileManager.default.removeItem(at: support)
      try FileManager.default.createSymbolicLink(at: support, withDestinationURL: target)
    case "child-link":
      try FileManager.default.createSymbolicLink(at: child, withDestinationURL: target)
    default:
      try FileManager.default.createDirectory(
        at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
      #expect(chmod(child.path, 0o777) == 0)
    }
    #expect(throws: DesktopThrottleStoreError.unsafePath) {
      try DesktopThrottleFileStore.applicationSupport(homeDirectory: fixture.directory)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    if kind == "parent-mode" {
      var info = stat()
      #expect(lstat(support.path, &info) == 0)
      #expect(info.st_mode & 0o7777 == 0o777)
      #expect(!FileManager.default.fileExists(atPath: child.path))
    }
  }

  @Test func missingRoundTripReplacementAndRestart() throws {
    let fixture = try ThrottleFixture(mode: 0o755)
    var first: DesktopThrottleFileStore? = try DesktopThrottleFileStore(
      directory: fixture.directory)
    #expect(try first?.load() == nil)
    #expect(try first?.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
    let record = throttleRecord()
    try first?.save(record)
    #expect(try first?.load() == record)
    var next = record
    next.recordedAt = throttleNow.addingTimeInterval(1)
    next.failureCount = 4
    try first?.save(next)
    #expect(try first?.load() == next)
    first = nil
    let restarted = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(try restarted.load() == next)
    #expect(try fixture.names() == ["desktop-throttle.json", "desktop-throttle.lock"])
  }

  @Test func minimalRecordAndExplicitMetadataAllowlist() throws {
    let fixture = try ThrottleFixture()
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    let minimal = DesktopThrottleRecord(recordedAt: throttleNow)
    try store.save(minimal)
    #expect(try store.load() == minimal)
    try store.save(throttleRecord())
    let data = try Data(contentsOf: fixture.recordURL)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(json.keys) == [
        "schemaVersion", "recordedAt", "lastAttemptAt", "localNextAllowedAt",
        "successfulNextAllowedAt", "serviceNotBefore", "unsupportedServiceWait",
        "failureCount", "interruptedUntil", "authRefusal",
      ])
    #expect(json["authRefusal"] as? String == "accessDenied")
    #expect(data.count <= 4096)
    #expect(try Data(contentsOf: fixture.lockURL) == Data([1]))
    for url in [fixture.recordURL, fixture.lockURL] {
      var info = stat()
      #expect(lstat(url.path, &info) == 0)
      #expect(info.st_uid == geteuid())
      #expect(info.st_mode & 0o7777 == 0o600)
      #expect(info.st_nlink == 1)
    }
  }

  @Test(arguments: [DesktopAuthRefusal.waitingForDesktopRenewal, .accessDenied])
  func refusalRoundTripAndRestart(refusal: DesktopAuthRefusal) throws {
    let fixture = try ThrottleFixture()
    var store: DesktopThrottleFileStore? = try DesktopThrottleFileStore(
      directory: fixture.directory)
    let minimal = DesktopThrottleRecord(recordedAt: throttleNow, authRefusal: refusal)
    try store?.save(minimal)
    #expect(try store?.load() == minimal)
    var full = throttleRecord()
    full.authRefusal = refusal
    try store?.save(full)
    store = nil
    let restarted = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(try restarted.load() == full)
  }

  @Test func legacyV1WithoutRefusalRemainsReadable() throws {
    let fixture = try ThrottleFixture()
    var legacy = throttleRecord()
    legacy.authRefusal = nil
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    json.removeValue(forKey: "authRefusal")
    try fixture.write(JSONSerialization.data(withJSONObject: json))
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(try store.load() == legacy)
    try store.save(legacy)
    #expect(try store.load() == legacy)
  }

  @Test(arguments: ["unknown", "current", "401", ""])
  func invalidRefusalEnumRejected(value: String) throws {
    let fixture = try ThrottleFixture()
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(throttleRecord()))
        as? [String: Any])
    json["authRefusal"] = value
    try fixture.write(JSONSerialization.data(withJSONObject: json))
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.load() }
  }

  @Test(arguments: ["{", "[]", "null", "{}", "\"synthetic-only\""])
  func corruptBodiesReturnOnlyFixedErrors(body: String) throws {
    let fixture = try ThrottleFixture()
    try fixture.write(Data(body.utf8))
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.load() }
  }

  @Test(arguments: ["schemaVersion", "recordedAt", "unsupportedServiceWait", "failureCount"])
  func missingRequiredFieldsRejected(field: String) throws {
    let fixture = try ThrottleFixture()
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(throttleRecord()))
        as? [String: Any])
    json.removeValue(forKey: field)
    try fixture.write(JSONSerialization.data(withJSONObject: json))
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.load() }
  }

  @Test(arguments: [
    "accountFingerprint", "organizationFingerprint", "credential", "token", "extra",
    "authRefusalGeneration", "generation", "credentialHash", "owner",
  ])
  func unknownFieldsRejected(field: String) throws {
    let fixture = try ThrottleFixture()
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(throttleRecord()))
        as? [String: Any])
    json[field] = "synthetic-only"
    try fixture.write(JSONSerialization.data(withJSONObject: json))
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.load() }
  }

  @Test func invalidVersionAndSemanticValuesRejectedOnReadAndWrite() throws {
    var version = throttleRecord()
    version.schemaVersion = 2
    var count = throttleRecord()
    count.failureCount = -1
    var date = throttleRecord()
    date.recordedAt = Date(timeIntervalSince1970: 0)
    var interrupted = throttleRecord()
    interrupted.lastAttemptAt = nil
    for invalid in [version, count, date, interrupted] {
      let fixture = try ThrottleFixture()
      try fixture.writeRecord(invalid)
      let store = try DesktopThrottleFileStore(directory: fixture.directory)
      #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.load() }
      let original = try Data(contentsOf: fixture.recordURL)
      #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.save(invalid) }
      #expect(try Data(contentsOf: fixture.recordURL) == original)
    }
    let fixture = try ThrottleFixture()
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    var nonfinite = throttleRecord()
    nonfinite.recordedAt = Date(timeIntervalSince1970: .infinity)
    #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.save(nonfinite) }
    #expect(try store.load() == nil)
  }

  @Test func exactByteLimitAcceptedAndOversizeRejectedBeforeRead() throws {
    let fixture = try ThrottleFixture()
    var data = try JSONEncoder().encode(throttleRecord())
    data.append(Data(repeating: 0x20, count: 4096 - data.count))
    try fixture.write(data)
    var store: DesktopThrottleFileStore? = try DesktopThrottleFileStore(
      directory: fixture.directory)
    #expect(try store?.load() == throttleRecord())
    store = nil
    data.append(0x20)
    try fixture.write(data)
    #expect(throws: DesktopThrottleStoreError.inputTooLarge) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
  }

  @Test func directoryMustAlreadyExistAndCannotUseSymlinkAlias() throws {
    let fixture = try ThrottleFixture()
    let missing = fixture.directory.appendingPathComponent("missing")
    #expect(throws: DesktopThrottleStoreError.self) {
      try DesktopThrottleFileStore(directory: missing)
    }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    // /tmp is a symlink on macOS; only the real /private/tmp ancestry is accepted.
    let alias = URL(fileURLWithPath: "/tmp").appendingPathComponent(
      fixture.directory.lastPathComponent)
    #expect(throws: DesktopThrottleStoreError.self) {
      try DesktopThrottleFileStore(directory: alias)
    }
  }

  @Test(arguments: [0o770, 0o707, 0o777, 0o1777])
  func writableFinalDirectoriesRejected(mode: Int) throws {
    let fixture = try ThrottleFixture()
    #expect(chmod(fixture.directory.path, mode_t(mode)) == 0)
    #expect(throws: DesktopThrottleStoreError.unsafePath) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
  }

  @Test func writableOrSymlinkedAncestorRejected() throws {
    let fixture = try ThrottleFixture()
    let parent = fixture.directory.appendingPathComponent("parent")
    let child = parent.appendingPathComponent("child")
    try FileManager.default.createDirectory(
      at: child, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #expect(chmod(parent.path, 0o777) == 0)
    #expect(throws: DesktopThrottleStoreError.unsafePath) {
      try DesktopThrottleFileStore(directory: child)
    }
    #expect(chmod(parent.path, 0o700) == 0)
    let alias = fixture.directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    for url in [alias, alias.appendingPathComponent("child")] {
      #expect(throws: DesktopThrottleStoreError.self) {
        try DesktopThrottleFileStore(directory: url)
      }
    }
  }

  @Test(
    arguments: ["desktop-throttle.json", "desktop-throttle.lock"], [0o644, 0o660, 0o400])
  func unsafeFilePermissionsRejected(name: String, mode: Int) throws {
    let fixture = try ThrottleFixture()
    try fixture.write(
      Data(), to: fixture.directory.appendingPathComponent(name), mode: mode_t(mode))
    // An unreadable/unwritable lock may fail at open before metadata validation.
    #expect(throws: DesktopThrottleStoreError.self) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
  }

  @Test("Special permission bits are rejected without requiring a set-id file on disk")
  func specialFileModeBits() {
    // macOS sandboxed chmod may strip set-id bits. Exercise the exact stat input
    // independently, keeping ordinary permission/path tests on real fixture files.
    for bits: mode_t in [S_ISUID, S_ISGID, S_ISVTX] {
      var info = stat()
      info.st_mode = S_IFREG | 0o600 | bits
      info.st_uid = geteuid()
      info.st_nlink = 1
      #expect(throws: DesktopThrottleStoreError.unsafePath) {
        try DesktopThrottleFileStore.validateFile(info, maximumBytes: 0)
      }
    }
  }

  @Test func nonemptyLockIsRejectedWithoutReadingItsBody() throws {
    let fixture = try ThrottleFixture()
    try fixture.write(Data("synthetic-only".utf8), to: fixture.lockURL)
    #expect(throws: DesktopThrottleStoreError.inputTooLarge) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
  }

  @Test(arguments: ["desktop-throttle.json", "desktop-throttle.lock"])
  func symlinksHardlinksAndSpecialFilesRejected(name: String) throws {
    for kind in ["symlink", "hardlink", "fifo", "directory"] {
      let fixture = try ThrottleFixture()
      let path = fixture.directory.appendingPathComponent(name)
      let target = fixture.directory.appendingPathComponent("synthetic-target")
      try fixture.write(Data(), to: target)
      switch kind {
      case "symlink":
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
      case "hardlink":
        #expect(link(target.path, path.path) == 0)
      case "fifo":
        #expect(mkfifo(path.path, 0o600) == 0)
      default:
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
      }
      #expect(throws: DesktopThrottleStoreError.self) {
        try DesktopThrottleFileStore(directory: fixture.directory)
      }
      #expect(try Data(contentsOf: target).isEmpty)
    }
  }

  @Test func contentionRejectedAndReleaseLeavesLockForRestart() throws {
    let fixture = try ThrottleFixture()
    var first: DesktopThrottleFileStore? = try DesktopThrottleFileStore(
      directory: fixture.directory)
    #expect(first != nil)
    #expect(throws: DesktopThrottleStoreError.locked) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
    first = nil
    #expect(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    let second = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(try second.load() == nil)
  }

  @Test(arguments: ["construction", "read", "save", "invalid-read"])
  func disappearanceNeverBecomesFresh(mode: String) throws {
    let fixture = try ThrottleFixture()
    if mode != "save" {
      if mode == "invalid-read" {
        try fixture.write(Data("{".utf8))
      } else {
        try fixture.writeRecord()
      }
    }
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    if mode == "save" { try store.save(throttleRecord()) }
    if mode == "read" { #expect(try store.load() == throttleRecord()) }
    if mode == "invalid-read" {
      #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.load() }
    }
    try FileManager.default.removeItem(at: fixture.recordURL)
    #expect(throws: DesktopThrottleStoreError.missingRecord) { try store.load() }
    #expect(throws: DesktopThrottleStoreError.missingRecord) { try store.save(throttleRecord()) }
    #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
  }

  @Test("Initialized store deletion remains an error after a process restart")
  func missingCheckpointAfterRestart() throws {
    let fixture = try ThrottleFixture()
    var store: DesktopThrottleFileStore? = try DesktopThrottleFileStore(
      directory: fixture.directory)
    try store?.save(throttleRecord())
    store = nil
    try FileManager.default.removeItem(at: fixture.recordURL)
    #expect(throws: DesktopThrottleStoreError.missingRecord) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
    #expect(try Data(contentsOf: fixture.lockURL) == Data([1]))
  }

  @Test("A successfully loaded legacy checkpoint initializes its durable marker")
  func loadedCheckpointMarker() throws {
    let fixture = try ThrottleFixture()
    try fixture.writeRecord()
    var store: DesktopThrottleFileStore? = try DesktopThrottleFileStore(
      directory: fixture.directory)
    #expect(try store?.load() == throttleRecord())
    store = nil
    try FileManager.default.removeItem(at: fixture.recordURL)
    #expect(throws: DesktopThrottleStoreError.missingRecord) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
  }

  @Test("An invalid lock marker cannot become a fresh store")
  func invalidMarker() throws {
    let fixture = try ThrottleFixture()
    try fixture.write(Data([2]), to: fixture.lockURL)
    #expect(throws: DesktopThrottleStoreError.invalidRecord) {
      try DesktopThrottleFileStore(directory: fixture.directory)
    }
  }

  @Test func newlyAppearedInvalidRecordCannotDisappearIntoFreshState() throws {
    let fixture = try ThrottleFixture()
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(try store.load() == nil)
    try fixture.write(Data("{".utf8))
    #expect(throws: DesktopThrottleStoreError.invalidRecord) { try store.load() }
    try FileManager.default.removeItem(at: fixture.recordURL)
    #expect(throws: DesktopThrottleStoreError.missingRecord) { try store.load() }
    #expect(throws: DesktopThrottleStoreError.missingRecord) { try store.save(throttleRecord()) }
  }

  @Test func externalRecordReplacementAndPermissionChangesFailClosed() throws {
    for replace in [true, false] {
      let fixture = try ThrottleFixture()
      try fixture.writeRecord()
      let store = try DesktopThrottleFileStore(directory: fixture.directory)
      #expect(try store.load() == throttleRecord())
      if replace {
        let other = fixture.directory.appendingPathComponent("replacement")
        try fixture.write(JSONEncoder().encode(throttleRecord()), to: other)
        #expect(rename(other.path, fixture.recordURL.path) == 0)
      } else {
        #expect(chmod(fixture.recordURL.path, 0o644) == 0)
      }
      #expect(throws: DesktopThrottleStoreError.self) { try store.load() }
      #expect(throws: DesktopThrottleStoreError.self) { try store.save(throttleRecord()) }
    }
  }

  @Test(arguments: [false, true])
  func missingOrReplacedLockFailsClosed(replace: Bool) throws {
    let fixture = try ThrottleFixture()
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    try store.save(throttleRecord())
    try FileManager.default.removeItem(at: fixture.lockURL)
    if replace { try fixture.write(Data(), to: fixture.lockURL) }
    #expect(throws: DesktopThrottleStoreError.self) { try store.load() }
    #expect(throws: DesktopThrottleStoreError.self) { try store.save(throttleRecord()) }
  }

  @Test func directoryReplacementAndAncestorPermissionChangeFailClosed() throws {
    for replace in [true, false] {
      let fixture = try ThrottleFixture()
      let child = fixture.directory.appendingPathComponent("store")
      try FileManager.default.createDirectory(
        at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let store = try DesktopThrottleFileStore(directory: child)
      try store.save(throttleRecord())
      if replace {
        try FileManager.default.moveItem(
          at: child, to: fixture.directory.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(
          at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      } else {
        #expect(chmod(fixture.directory.path, 0o777) == 0)
      }
      #expect(throws: DesktopThrottleStoreError.self) { try store.load() }
      #expect(throws: DesktopThrottleStoreError.self) { try store.save(throttleRecord()) }
    }
  }

  @Test func shortWritesAndInterruptedSyscallsAreRetried() throws {
    let fixture = try ThrottleFixture()
    let writes = ThrottleCounter()
    let syncs = ThrottleCounter()
    var io = DesktopThrottleFileStore.IO()
    io.write = { fd, bytes, count in
      if writes.next() == 1 {
        errno = EINTR
        return -1
      }
      return Darwin.write(fd, bytes, min(count, 7))
    }
    io.sync = { fd in
      if syncs.next() == 1 {
        errno = EINTR
        return -1
      }
      return Darwin.fsync(fd)
    }
    let store = try DesktopThrottleFileStore(directory: fixture.directory, io: io)
    try store.save(throttleRecord())
    #expect(try store.load() == throttleRecord())
    #expect(writes.next() > 2)
    #expect(syncs.next() == 4)
  }

  @Test(arguments: ["write", "zero-write", "sync", "rename"], [false, true])
  func preRenameFailurePreservesPriorAndCleansOnlyOwnTemp(failure: String, existing: Bool) throws {
    let fixture = try ThrottleFixture()
    if existing { try fixture.writeRecord() }
    let stale = fixture.directory.appendingPathComponent(".desktop-throttle-unrelated.tmp")
    try fixture.write(Data("synthetic-unrelated".utf8), to: stale)
    let original = existing ? try Data(contentsOf: fixture.recordURL) : nil
    let writes = ThrottleCounter()
    var io = DesktopThrottleFileStore.IO()
    switch failure {
    case "write":
      io.write = { fd, bytes, count in
        if writes.next() == 1 { return Darwin.write(fd, bytes, min(count, 7)) }
        errno = ENOSPC
        return -1
      }
    case "zero-write":
      io.write = { _, _, _ in 0 }
    case "sync":
      io.sync = { _ in
        errno = EIO
        return -1
      }
    default:
      io.rename = { _, _, _, _ in
        errno = EIO
        return -1
      }
    }
    let store = try DesktopThrottleFileStore(directory: fixture.directory, io: io)
    var changed = throttleRecord()
    changed.failureCount = 4
    #expect(throws: DesktopThrottleStoreError.ioFailure) { try store.save(changed) }
    if let original {
      #expect(try Data(contentsOf: fixture.recordURL) == original)
      #expect(try store.load() == throttleRecord())
    } else {
      #expect(try store.load() == nil)
    }
    let expected: Set<String> =
      existing
      ? ["desktop-throttle.json", "desktop-throttle.lock", stale.lastPathComponent]
      : ["desktop-throttle.lock", stale.lastPathComponent]
    #expect(try fixture.names() == expected)
    #expect(try Data(contentsOf: stale) == Data("synthetic-unrelated".utf8))
  }

  @Test func cleanupDoesNotUnlinkReplacementAtTemporaryName() throws {
    let fixture = try ThrottleFixture()
    try fixture.writeRecord()
    let directory = fixture.directory
    let original = try Data(contentsOf: fixture.recordURL)
    var io = DesktopThrottleFileStore.IO()
    io.write = { _, _, _ in
      do {
        let name = try #require(
          try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .first { $0.hasPrefix(".desktop-throttle-") && $0.hasSuffix(".tmp") })
        let temporary = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(
          at: temporary, to: directory.appendingPathComponent("moved-own-temp"))
        try Data("synthetic-replacement".utf8).write(to: temporary)
      } catch {
        Issue.record("Synthetic temporary-file replacement failed")
      }
      errno = ENOSPC
      return -1
    }
    let store = try DesktopThrottleFileStore(directory: directory, io: io)
    #expect(throws: DesktopThrottleStoreError.ioFailure) { try store.save(throttleRecord()) }
    #expect(try Data(contentsOf: fixture.recordURL) == original)
    let name = try #require(try fixture.names().first { $0.hasSuffix(".tmp") })
    #expect(
      try Data(contentsOf: directory.appendingPathComponent(name))
        == Data("synthetic-replacement".utf8))
  }

  @Test func parentSyncFailureReportsUncertainCommitAndFailsClosed() throws {
    let fixture = try ThrottleFixture()
    try fixture.writeRecord()
    let syncs = ThrottleCounter()
    var io = DesktopThrottleFileStore.IO()
    io.sync = { fd in
      if syncs.next() == 2 {
        errno = EIO
        return -1
      }
      return Darwin.fsync(fd)
    }
    var store: DesktopThrottleFileStore? = try DesktopThrottleFileStore(
      directory: fixture.directory, io: io)
    var changed = throttleRecord()
    changed.failureCount = 4
    #expect(throws: DesktopThrottleStoreError.ioFailure) { try store?.save(changed) }
    #expect(throws: DesktopThrottleStoreError.ioFailure) { try store?.load() }
    #expect(throws: DesktopThrottleStoreError.ioFailure) { try store?.save(throttleRecord()) }
    store = nil
    let restarted = try DesktopThrottleFileStore(directory: fixture.directory)
    #expect(try restarted.load() == changed)
    #expect(try fixture.names() == ["desktop-throttle.json", "desktop-throttle.lock"])
  }

  @Test func concurrentCallsUseOneSerializedStore() async throws {
    let fixture = try ThrottleFixture()
    let store = try DesktopThrottleFileStore(directory: fixture.directory)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<24 {
        group.addTask {
          var record = throttleRecord()
          record.recordedAt = throttleNow.addingTimeInterval(Double(index))
          try store.save(record)
          let loadedRecord = try store.load()
          let loaded = try #require(loadedRecord)
          #expect(loaded.isValid)
        }
      }
      try await group.waitForAll()
    }
    #expect(try store.load() != nil)
    #expect(try fixture.names() == ["desktop-throttle.json", "desktop-throttle.lock"])
  }
}
