import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing

@testable import QuotaTempoDesktopCandidate

@Suite("Desktop candidate organization cookie reader")
struct DesktopOrganizationReaderTests {
  private let first = "11111111-2222-4333-8444-555555555555"
  private let second = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

  @Test("Plain UUID is canonicalized without writes or new sidecars")
  func plainReadIsUnchanged() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.second.uppercased())
    let bytes = try Data(contentsOf: fixture.database)
    let stamp = try DesktopProtectedFile.stamp(fixture.database, maximumBytes: 1_000_000)
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    let result = try self.read(fixture)
    #expect(result.organization == self.second)
    #expect(result.stamps.count == 8)
    #expect(result.stamps[0] == stamp)
    #expect(result.stamps.dropFirst().allSatisfy { $0 == nil })
    #expect(try Data(contentsOf: fixture.database) == bytes)
    #expect(try DesktopProtectedFile.stamp(fixture.database, maximumBytes: 1_000_000) == stamp)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == names)
  }

  @Test("Both eligible hosts and both stores must agree")
  func agreeingStores() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.insert(value: self.first, host: "claude.ai")
    let network = try fixture.makeNetworkDatabase()
    try fixture.insert(value: self.first, connection: network)
    let result = try self.read(fixture)
    #expect(result.organization == self.first)
    #expect(result.stamps[4] != nil)
  }

  @Test("Conflicting active organizations on eligible hosts are ambiguous")
  func conflictingHosts() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.insert(value: self.second, host: "claude.ai")
    #expect(throws: DesktopCredentialError.ambiguousIdentity) { try self.read(fixture) }
  }

  @Test("Conflicting active organizations across database locations are ambiguous")
  func conflictingStores() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    let network = try fixture.makeNetworkDatabase()
    try fixture.insert(value: self.second, connection: network)
    #expect(throws: DesktopCredentialError.ambiguousIdentity) { try self.read(fixture) }
  }

  @Test("Only the named organization cookie on the exact host and root path is read")
  func unrelatedRowsAreIgnored() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    for (name, host, path) in [
      ("sessionKey", ".claude.ai", "/"), ("lastActiveOrg", "evil.claude.ai", "/"),
      ("lastActiveOrg", ".claude.ai", "/other"), ("lastActiveOrg", "CLAUDE.AI", "/"),
      ("lastActiveOrg", ".claude.ai", "//"), ("lastActiveOrgSuffix", ".claude.ai", "/"),
    ] {
      try fixture.insert(value: self.second, name: name, host: host, path: path)
    }
    #expect(try self.read(fixture).organization == self.first)
  }

  @Test("A non-root-path cookie cannot establish organization")
  func noPathFallback() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first, path: "/settings")
    #expect(throws: DesktopCredentialError.identityUnavailable) { try self.read(fixture) }
  }

  @Test("Schema collations cannot broaden the exact cookie selection")
  func explicitBinaryCollation() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.execute(
      """
      DROP TABLE cookies;
      CREATE TABLE cookies (
        name TEXT COLLATE NOCASE, host_key TEXT COLLATE RTRIM, path TEXT COLLATE RTRIM,
        value TEXT, encrypted_value BLOB, expires_utc INTEGER, has_expires INTEGER,
        is_persistent INTEGER
      );
      """)
    try fixture.insert(value: self.first)
    try fixture.insert(value: self.second, name: "LASTACTIVEORG")
    try fixture.insert(value: self.second, path: "/ ")
    try fixture.insert(value: self.second, host: ".claude.ai ")
    #expect(try self.read(fixture).organization == self.first)
  }

  @Test("Expired and session cookies do not override eligible persistent cookies")
  func expirySelection() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.insert(
      value: self.second, expiry: Fixture.chromiumDate(Date().addingTimeInterval(-60)))
    try fixture.insert(value: self.second, expiry: 0, hasExpiry: 0, persistent: 0)
    #expect(try self.read(fixture).organization == self.first)
  }

  @Test("Expired or session cookies alone cannot establish active organization")
  func noExpiredFallback() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first, expiry: 0, hasExpiry: 0, persistent: 0)
    try fixture.insert(
      value: self.second, expiry: Fixture.chromiumDate(Date().addingTimeInterval(-60)))
    #expect(throws: DesktopCredentialError.identityUnavailable) { try self.read(fixture) }
  }

  @Test("Missing stores fail without creating files")
  func missingStores() throws {
    let fixture = try Fixture(createDatabase: false)
    defer { fixture.cleanup() }
    #expect(throws: DesktopCredentialError.identityUnavailable) { try self.read(fixture) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
  }

  @Test(
    "Encrypted cookies require the matching host hash and strict UUID",
    arguments: [".claude.ai", "claude.ai"])
  func encryptedCookie(_ host: String) throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let cipher = Self.cipher()
    try fixture.insert(value: "", host: host, encrypted: cipher)
    var calls = 0
    let result = try DesktopOrganizationReader.read(directory: fixture.directory) { bytes in
      calls += 1
      #expect(bytes == cipher)
      return Data(SHA256.hash(data: Data(host.utf8))) + Data(self.first.utf8)
    }
    #expect(calls == 1)
    #expect(result.organization == self.first)
  }

  @Test("Malformed ciphertext never reaches decryption", arguments: [0, 3, 19, 82, 84, 4_096])
  func cipherLength(_ count: Int) throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Data(repeating: 0x61, count: count))
    var calls = 0
    do {
      _ = try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
        calls += 1
        return Data()
      }
      Issue.record("Malformed encrypted cookie was accepted")
    } catch {
      #expect(
        error as? DesktopCredentialError == (count == 0 ? .identityUnavailable : .invalidStore))
    }
    #expect(calls == 0)
  }

  @Test("Unknown cipher version is refused before decryption")
  func cipherVersion() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Data("v20".utf8) + Data(repeating: 0x61, count: 80))
    #expect(throws: DesktopCredentialError.invalidStore) { try self.read(fixture) }
  }

  @Test("Host-bound ciphertext cannot be reused for a different eligible host")
  func wrongHostHash() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Self.cipher())
    #expect(throws: DesktopCredentialError.identityUnavailable) {
      try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
        Data(SHA256.hash(data: Data("claude.ai".utf8))) + Data(self.first.utf8)
      }
    }
  }

  @Test("Malformed decrypted bytes and plaintext never become an organization")
  func invalidUUIDs() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    for value in ["", "not-a-uuid", String(repeating: "x", count: 36), self.first + "\u{0}"] {
      try fixture.execute("DELETE FROM cookies")
      try fixture.insert(value: value)
      do {
        _ = try self.read(fixture)
        Issue.record("Invalid organization was accepted")
      } catch {
        let bounded = error as? DesktopCredentialError
        #expect(bounded == .identityUnavailable || bounded == .inputTooLarge)
      }
    }
  }

  @Test("Dual plaintext and encrypted representations are not silently preferred")
  func dualRepresentations() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first, encrypted: Self.cipher())
    #expect(throws: DesktopCredentialError.invalidStore) { try self.read(fixture) }
  }

  @Test(
    "Malformed content types and expiry flags do not get coerced",
    arguments: [
      "expires_utc = NULL", "expires_utc = 'unknown'", "expires_utc = 1.5", "has_expires = 2",
      "has_expires = NULL", "is_persistent = 0", "value = x'FF'", "encrypted_value = NULL",
      "encrypted_value = ''", "expires_utc = -1",
    ])
  func malformedColumns(_ assignment: String) throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.execute("UPDATE cookies SET " + assignment)
    #expect(throws: DesktopCredentialError.invalidStore) { try self.read(fixture) }
  }

  @Test("Only a bounded number of matching rows may be considered")
  func rowLimit() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    for _ in 0..<16 { try fixture.insert(value: self.first) }
    #expect(try self.read(fixture).organization == self.first)
    try fixture.insert(value: self.first)
    #expect(throws: DesktopCredentialError.inputTooLarge) { try self.read(fixture) }
  }

  @Test("Views are not allowed to redirect the organization query")
  func rejectsViews() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.execute(
      "ALTER TABLE cookies RENAME TO other; CREATE VIEW cookies AS SELECT * FROM other")
    #expect(throws: DesktopCredentialError.invalidStore) { try self.read(fixture) }
  }

  @Test("Query interpretation remains literal for reserved characters in paths")
  func escapedURI() throws {
    let fixture = try Fixture(suffix: " space ?mode=rw&immutable=0#fragment%20")
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    #expect(try self.read(fixture).organization == self.first)
  }

  @Test(
    "Symlink databases and sidecars are rejected",
    arguments: ["Cookies", "Cookies-wal", "Cookies-shm", "Cookies-journal"])
  func rejectsSymlinks(_ name: String) throws {
    let fixture = try Fixture(createDatabase: false)
    defer { fixture.cleanup() }
    let target = fixture.directory.appendingPathComponent("synthetic-target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fixture.directory.appendingPathComponent(name), withDestinationURL: target)
    #expect(throws: DesktopCredentialError.unsafePath) { try self.read(fixture) }
  }

  @Test("A symlinked Network parent is rejected even when its database is absent")
  func rejectsSymlinkedParent() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    let target = fixture.directory.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: fixture.directory.appendingPathComponent("Network"), withDestinationURL: target)
    #expect(throws: DesktopCredentialError.unsafePath) { try self.read(fixture) }
  }

  @Test("Nonregular sidecars are rejected without blocking")
  func rejectsFIFO() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    #expect(mkfifo(fixture.database.path + "-wal", 0o600) == 0)
    #expect(throws: DesktopCredentialError.unsafePath) { try self.read(fixture) }
  }

  @Test("Oversized databases are rejected before SQLite opens them")
  func oversizedDatabase() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    fixture.close()
    let file = try FileHandle(forWritingTo: fixture.database)
    try file.truncate(atOffset: 16 * 1_024 * 1_024 + 1)
    try file.close()
    #expect(throws: DesktopCredentialError.inputTooLarge) { try self.read(fixture) }
  }

  @Test("Group-writable databases do not establish identity")
  func unsafePermissions() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o660], ofItemAtPath: fixture.database.path)
    #expect(throws: DesktopCredentialError.unsafePath) { try self.read(fixture) }
  }

  @Test("New sidecars during decryption invalidate the read")
  func concurrentSidecar() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Self.cipher())
    #expect(throws: DesktopCredentialError.changedDuringRead) {
      try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
        try Data().write(to: URL(fileURLWithPath: fixture.database.path + "-wal"))
        return Data(SHA256.hash(data: Data(".claude.ai".utf8))) + Data(self.first.utf8)
      }
    }
  }

  @Test("Changes in a previously missing store invalidate the complete selection")
  func concurrentNewStore() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Self.cipher())
    #expect(throws: DesktopCredentialError.changedDuringRead) {
      try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
        let network = try fixture.makeNetworkDatabase()
        try fixture.insert(value: self.second, connection: network)
        return Data(SHA256.hash(data: Data(".claude.ai".utf8))) + Data(self.first.utf8)
      }
    }
  }

  @Test("Decryption errors are bounded and never expose arbitrary error text")
  func sanitizedError() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Self.cipher())
    do {
      _ = try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
        throw NSError(domain: "synthetic-private-marker", code: 1)
      }
      Issue.record("Expected a bounded failure")
    } catch {
      #expect(error as? DesktopCredentialError == .invalidStore)
      #expect(!String(reflecting: error).contains("synthetic-private-marker"))
    }
  }

  @Test("A WAL-only latest organization is returned without changing source files")
  func walOnlyCommit() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
    let mainBefore = try Data(contentsOf: fixture.database)
    try fixture.execute("UPDATE cookies SET value='\(self.second)'")
    #expect(try fixture.writerOrganization() == self.second)
    #expect(try Data(contentsOf: fixture.database) == mainBefore)
    let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
    let shm = URL(fileURLWithPath: fixture.database.path + "-shm")
    let walBefore = try Data(contentsOf: wal)
    let shmBefore = try Data(contentsOf: shm)
    #expect(!walBefore.isEmpty)
    #expect(try self.read(fixture).organization == self.second)
    #expect(try Data(contentsOf: fixture.database) == mainBefore)
    #expect(try Data(contentsOf: wal) == walBefore)
    #expect(try Data(contentsOf: shm) == shmBefore)
  }

  @Test("A WAL without shared memory is read without creating shared memory")
  func walWithoutSHM() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
    try fixture.execute("UPDATE cookies SET value='\(self.second)'")
    #expect(try fixture.writerOrganization() == self.second)
    // Synthetic store only: the idle writer stays open to retain the committed WAL.
    let shm = URL(fileURLWithPath: fixture.database.path + "-shm")
    try FileManager.default.removeItem(at: shm)
    let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
    let before = try Data(contentsOf: wal)
    #expect(try self.read(fixture).organization == self.second)
    #expect(!FileManager.default.fileExists(atPath: shm.path))
    #expect(try Data(contentsOf: wal) == before)
  }

  @Test("A stable checkpointed WAL-mode database with no sidecars may be read")
  func checkpointedDatabase() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.execute("PRAGMA journal_mode=WAL")
    try fixture.execute("UPDATE cookies SET value='\(self.second)'")
    try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    fixture.close()
    // SQLite builds may retain an empty WAL after close. This is a synthetic,
    // fully checkpointed fixture; remove its empty sidecars to exercise that state.
    let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
    if FileManager.default.fileExists(atPath: wal.path) {
      let empty = try Data(contentsOf: wal).isEmpty
      try #require(empty)
      try FileManager.default.removeItem(at: wal)
    }
    let shm = URL(fileURLWithPath: fixture.database.path + "-shm")
    if FileManager.default.fileExists(atPath: shm.path) {
      try FileManager.default.removeItem(at: shm)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.database.path + "-wal"))
    #expect(try self.read(fixture).organization == self.second)
    #expect(!FileManager.default.fileExists(atPath: fixture.database.path + "-shm"))
  }

  @Test("Rollback journals are refused without recovery", arguments: [0, 512])
  func refusesJournal(_ count: Int) throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    let journal = URL(fileURLWithPath: fixture.database.path + "-journal")
    let content = Data(repeating: 0x61, count: count)
    try content.write(to: journal)
    let main = try Data(contentsOf: fixture.database)
    #expect(throws: DesktopCredentialError.unavailable) { try self.read(fixture) }
    #expect(try Data(contentsOf: journal) == content)
    #expect(try Data(contentsOf: fixture.database) == main)
  }

  @Test("Orphan WAL or SHM cannot fall back to another store", arguments: ["-wal", "-shm"])
  func refusesOrphanSidecar(_ suffix: String) throws {
    let fixture = try Fixture(createDatabase: false)
    defer { fixture.cleanup() }
    let network = try fixture.makeNetworkDatabase()
    try fixture.insert(value: self.first, connection: network)
    let sidecar = URL(fileURLWithPath: fixture.database.path + suffix)
    try Data().write(to: sidecar)
    #expect(throws: DesktopCredentialError.unavailable) { try self.read(fixture) }
    #expect(!FileManager.default.fileExists(atPath: fixture.database.path))
  }

  @Test(
    "Synthetic unix-none read-only probe reads WAL without source writes and refuses missing WAL",
    arguments: ["live", "missing-shm", "checkpointed", "empty-wal", "no-wal"])
  func readonlyWALProbe(_ mode: String) throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
    let originalMain = try Data(contentsOf: fixture.database)
    try fixture.execute("UPDATE cookies SET value='\(self.second)'")
    #expect(try fixture.writerOrganization() == self.second)
    #expect(try Data(contentsOf: fixture.database) == originalMain)
    if mode == "checkpointed" { try fixture.execute("PRAGMA wal_checkpoint(FULL)") }
    if mode == "empty-wal" || mode == "no-wal" {
      try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    if mode == "no-wal" {
      fixture.close()
      for suffix in ["-wal", "-shm"] {
        let path = URL(fileURLWithPath: fixture.database.path + suffix)
        if FileManager.default.fileExists(atPath: path.path) {
          if suffix == "-wal" {
            let empty = try Data(contentsOf: path).isEmpty
            try #require(empty)
          }
          try FileManager.default.removeItem(at: path)
        }
      }
    } else if mode == "missing-shm" {
      try FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.database.path + "-shm"))
    }
    let paths = ["", "-wal", "-shm", "-journal"].map {
      URL(fileURLWithPath: fixture.database.path + $0)
    }
    let bytes = paths.map { try? Data(contentsOf: $0) }
    let stamps = paths.map { try? DesktopProtectedFile.stamp($0, maximumBytes: 1_000_000) }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
    try fixture.withReadonlyWALProbe { reader in
      #expect(sqlite3_db_readonly(reader, "main") == 1)
      if mode == "no-wal" {
        // The production reader uses immutable for this state. The unix-none
        // probe cannot create a missing WAL in read-only mode.
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(reader, "SELECT value FROM cookies", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        #expect(result != SQLITE_OK)
      } else {
        let organization = try fixture.organization(connection: reader)
        #expect(organization == self.second)
        #expect(
          sqlite3_exec(reader, "UPDATE cookies SET value='must-not-write'", nil, nil, nil)
            == SQLITE_READONLY)
      }
    }
    #expect(paths.map { try? Data(contentsOf: $0) } == bytes)
    #expect(paths.map { try? DesktopProtectedFile.stamp($0, maximumBytes: 1_000_000) } == stamps)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == names)
    // Exercise the actual bounded reader, including its no-WAL routing, in all
    // five conditions. Observe close as well as query completion for side effects.
    #expect(try self.read(fixture).organization == self.second)
    #expect(paths.map { try? Data(contentsOf: $0) } == bytes)
    #expect(paths.map { try? DesktopProtectedFile.stamp($0, maximumBytes: 1_000_000) } == stamps)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == names)
  }

  @Test("The synthetic unix-none reader does not block a concurrent writer or alter it on close")
  func readonlyWALWriterProbe() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: self.first)
    try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
    try fixture.execute("UPDATE cookies SET value='\(self.first)'")
    let paths = ["", "-wal", "-shm"].map { URL(fileURLWithPath: fixture.database.path + $0) }
    var afterWriter: [Data?] = []
    try fixture.withReadonlyWALProbe { reader in
      var statement: OpaquePointer?
      let prepared = sqlite3_prepare_v2(reader, "SELECT value FROM cookies", -1, &statement, nil)
      defer { sqlite3_finalize(statement) }
      try #require(prepared == SQLITE_OK)
      try #require(sqlite3_step(statement) == SQLITE_ROW)
      try fixture.execute("UPDATE cookies SET value='\(self.second)'")
      #expect(try fixture.writerOrganization() == self.second)
      afterWriter = paths.map { try? Data(contentsOf: $0) }
    }
    #expect(paths.map { try? Data(contentsOf: $0) } == afterWriter)
    #expect(try fixture.writerOrganization() == self.second)
  }

  @Test("A concurrent WAL commit succeeds but invalidates the organization's stamped read")
  func concurrentWALCommit() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Self.cipher())
    try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
    try fixture.execute("UPDATE cookies SET value=''")
    let paths = ["", "-wal", "-shm"].map { URL(fileURLWithPath: fixture.database.path + $0) }
    var afterWriter: [Data?] = []
    var commits = 0
    #expect(throws: DesktopCredentialError.changedDuringRead) {
      try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
        try fixture.execute("UPDATE cookies SET value='\(self.second)', encrypted_value=x''")
        commits += 1
        afterWriter = paths.map { try? Data(contentsOf: $0) }
        return Data(SHA256.hash(data: Data(".claude.ai".utf8))) + Data(self.first.utf8)
      }
    }
    #expect(commits == 1)
    #expect(paths.map { try? Data(contentsOf: $0) } == afterWriter)
    #expect(try fixture.writerOrganization() == self.second)
  }

  @Test("The production WAL reader opens only read-only DB and WAL descriptors, never SHM")
  func readonlyWALDescriptors() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.insert(value: "", encrypted: Self.cipher())
    try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
    try fixture.execute("UPDATE cookies SET value=''")
    let paths = [
      fixture.database.path, fixture.database.path + "-wal", fixture.database.path + "-shm",
    ]
    func sourcePath(_ descriptor: Int32) -> String? {
      var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let status = bytes.withUnsafeMutableBufferPointer {
        fcntl(descriptor, F_GETPATH, $0.baseAddress!)
      }
      guard status == 0 else { return nil }
      let path = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
      return paths.contains(path) ? path : nil
    }
    // Only the fixture's writer descriptors remain open throughout this read.
    // Other tests can close unrelated FDs and the reader can reuse those numbers.
    let unrelated = (0..<8).map { _ in open("/dev/null", O_RDONLY | O_CLOEXEC) }
    let descriptors = Set((0..<4_096).map { Int32($0) }.filter { sourcePath($0) != nil })
    for descriptor in unrelated where descriptor >= 0 { close(descriptor) }
    var inspected = false
    let result = try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
      var mainCount = 0
      var walCount = 0
      var shmCount = 0
      for descriptor in Int32(0)..<4_096 where !descriptors.contains(descriptor) {
        guard let path = sourcePath(descriptor) else { continue }
        #expect(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
        if path == fixture.database.path { mainCount += 1 }
        if path == fixture.database.path + "-wal" { walCount += 1 }
        if path == fixture.database.path + "-shm" { shmCount += 1 }
      }
      #expect(mainCount >= 1)
      #expect(walCount == 1)
      #expect(shmCount == 0)
      inspected = true
      return Data(SHA256.hash(data: Data(".claude.ai".utf8))) + Data(self.first.utf8)
    }
    #expect(inspected)
    #expect(result.organization == self.first)
  }

  private func read(_ fixture: Fixture) throws -> DesktopOrganizationSelection {
    try DesktopOrganizationReader.read(directory: fixture.directory) { _ in
      Issue.record("Unexpected decryption")
      throw DesktopCredentialError.invalidStore
    }
  }

  private static func cipher() -> Data { Data("v10".utf8) + Data(repeating: 0x61, count: 80) }

  private final class Fixture {
    let directory: URL
    let database: URL
    private var connections: [OpaquePointer] = []

    init(createDatabase: Bool = true, suffix: String = "") throws {
      directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("QuotaTempoSyntheticOrg-" + UUID().uuidString + suffix)
      database = directory.appendingPathComponent("Cookies")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if createDatabase { _ = try self.create(database) }
    }

    func makeNetworkDatabase() throws -> OpaquePointer {
      let network = directory.appendingPathComponent("Network")
      try FileManager.default.createDirectory(
        at: network, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return try self.create(network.appendingPathComponent("Cookies"))
    }

    private func create(_ url: URL) throws -> OpaquePointer {
      var db: OpaquePointer?
      guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw Failure.sqlite }
      connections.append(db)
      try self.execute(
        """
        CREATE TABLE cookies (
          name TEXT, host_key TEXT, path TEXT, value TEXT, encrypted_value BLOB,
          expires_utc INTEGER, has_expires INTEGER, is_persistent INTEGER
        )
        """, connection: db)
      return db
    }

    func insert(
      value: String, name: String = "lastActiveOrg", host: String = ".claude.ai",
      path: String = "/",
      encrypted: Data = Data(), expiry: Int64? = nil, hasExpiry: Int64 = 1,
      persistent: Int64 = 1, connection: OpaquePointer? = nil
    ) throws {
      guard let db = connection ?? connections.first else { throw Failure.sqlite }
      let sql = "INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw Failure.sqlite
      }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      for (index, text) in [name, host, path, value].enumerated() {
        let result = text.withCString {
          sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(text.utf8.count), transient)
        }
        guard result == SQLITE_OK else { throw Failure.sqlite }
      }
      if encrypted.isEmpty {
        guard sqlite3_bind_zeroblob(statement, 5, 0) == SQLITE_OK else { throw Failure.sqlite }
      } else {
        let result = encrypted.withUnsafeBytes {
          sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), transient)
        }
        guard result == SQLITE_OK else { throw Failure.sqlite }
      }
      let future = Self.chromiumDate(Date().addingTimeInterval(86_400))
      guard sqlite3_bind_int64(statement, 6, expiry ?? future) == SQLITE_OK,
        sqlite3_bind_int64(statement, 7, hasExpiry) == SQLITE_OK,
        sqlite3_bind_int64(statement, 8, persistent) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE
      else { throw Failure.sqlite }
    }

    func execute(_ sql: String, connection: OpaquePointer? = nil) throws {
      guard let connection = connection ?? connections.first,
        sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK
      else { throw Failure.sqlite }
    }

    func writerOrganization() throws -> String {
      guard let db = connections.first else { throw Failure.sqlite }
      return try self.organization(connection: db)
    }

    func organization(connection db: OpaquePointer) throws -> String {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, "SELECT value FROM cookies", -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw Failure.sqlite }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
      else {
        throw Failure.sqlite
      }
      return String(cString: text)
    }

    // Independently exercise native SQLite's descriptor/close behavior without
    // the production authorizer, including attempted writes that must be denied.
    func withReadonlyWALProbe(_ body: (OpaquePointer) throws -> Void) throws {
      guard var components = URLComponents(url: database, resolvingAgainstBaseURL: false) else {
        throw Failure.sqlite
      }
      components.queryItems = [
        URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "vfs", value: "unix-none"),
      ]
      guard let uri = components.string else { throw Failure.sqlite }
      var reader: OpaquePointer?
      let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW
      let opened = sqlite3_open_v2(uri, &reader, flags, nil)
      guard opened == SQLITE_OK, let reader else {
        sqlite3_close(reader)
        throw Failure.sqlite
      }
      defer { #expect(sqlite3_close(reader) == SQLITE_OK) }
      guard
        sqlite3_exec(
          reader,
          "PRAGMA locking_mode=EXCLUSIVE; PRAGMA query_only=ON; PRAGMA temp_store=MEMORY;",
          nil, nil, nil) == SQLITE_OK
      else { throw Failure.sqlite }
      try body(reader)
    }

    func close() {
      for connection in connections { sqlite3_close(connection) }
      connections.removeAll()
    }

    func cleanup() {
      self.close()
      try? FileManager.default.removeItem(at: directory)
    }

    static func chromiumDate(_ date: Date) -> Int64 {
      Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    private enum Failure: Error { case sqlite }
  }
}
