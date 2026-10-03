import CryptoKit
import Darwin
import Foundation
import SQLite3

struct DesktopOrganizationSelection: Equatable, Sendable {
  let organization: String
  // Fixed order: Cookies, its WAL/SHM/journal, then Network/Cookies and its sidecars.
  // Missing files remain nil so appearance/disappearance changes the context.
  let stamps: [DesktopFileStamp?]
}

enum DesktopOrganizationReader {
  private static let maximumDatabaseBytes = 16 * 1_024 * 1_024
  private static let maximumRows = 16
  private static let chromiumEpochOffset: TimeInterval = 11_644_473_600
  private static let query = """
    SELECT host_key, value, encrypted_value, expires_utc, has_expires, is_persistent
    FROM cookies
    WHERE name COLLATE BINARY = 'lastActiveOrg'
      AND host_key COLLATE BINARY IN ('.claude.ai', 'claude.ai')
      AND path COLLATE BINARY = '/'
    LIMIT 17
    """

  static func read(directory: URL, decrypt: (Data) throws -> Data) throws
    -> DesktopOrganizationSelection
  {
    guard directory.isFileURL, directory.host == nil || directory.host == "",
      directory.query == nil, directory.fragment == nil
    else { throw DesktopCredentialError.unsafePath }
    let databases = [
      directory.appendingPathComponent("Cookies"),
      directory.appendingPathComponent("Network").appendingPathComponent("Cookies"),
    ]
    let paths = databases.flatMap { database in
      [database] + ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: database.path + $0) }
    }
    let before = try stamps(paths)

    for index in databases.indices {
      let offset = index * 4
      // TRUNCATE mode keeps an empty journal after commit. It needs no recovery;
      // retain its stamp to reject any change during the read. Never recover a
      // nonempty journal, even when its header might otherwise look inactive.
      guard before[offset + 3] == nil || before[offset + 3]?.size == 0 else {
        throw DesktopCredentialError.unavailable
      }
      guard
        before[offset] != nil
          || before[(offset + 1)...(offset + 3)].allSatisfy({ $0 == nil })
      else { throw DesktopCredentialError.unavailable }
    }

    var organizations = Set<String>()
    var firstExpiry = Date.distantFuture
    do {
      for (index, database) in databases.enumerated() {
        guard let expected = before[index * 4] else { continue }
        try DesktopProtectedFile.withDescriptor(database, maximumBytes: maximumDatabaseBytes) {
          descriptor, opened in
          guard opened == expected else { throw DesktopCredentialError.changedDuringRead }
          let values = try readDatabase(
            database, hasWAL: before[index * 4 + 1] != nil, decrypt: decrypt)
          var info = stat()
          guard fstat(descriptor, &info) == 0, DesktopFileStamp(info) == expected else {
            throw DesktopCredentialError.changedDuringRead
          }
          for (organization, expiry) in values {
            organizations.insert(organization)
            firstExpiry = min(firstExpiry, expiry)
          }
        }
      }
    } catch {
      guard try stamps(paths) == before else { throw DesktopCredentialError.changedDuringRead }
      throw (error as? DesktopCredentialError) ?? .invalidStore
    }

    // Neither route locks the writer. Recheck all source files after SQLite closes,
    // including SHM, which unix-none never opens. These stamps detect ordinary
    // concurrent commits/replacement, not an atomic snapshot or hostile same-user
    // swapping/restoring of DB/WAL paths between validation and SQLite's own opens.
    guard try stamps(paths) == before else { throw DesktopCredentialError.changedDuringRead }
    guard firstExpiry > Date(), !organizations.isEmpty else {
      throw DesktopCredentialError.identityUnavailable
    }
    guard organizations.count == 1, let organization = organizations.first else {
      throw DesktopCredentialError.ambiguousIdentity
    }
    return DesktopOrganizationSelection(organization: organization, stamps: before)
  }

  private static func stamps(_ paths: [URL]) throws -> [DesktopFileStamp?] {
    try paths.map { path in
      do {
        return try DesktopProtectedFile.stamp(path, maximumBytes: maximumDatabaseBytes)
      } catch DesktopCredentialError.unavailable {
        return nil
      }
    }
  }

  private static func readDatabase(_ url: URL, hasWAL: Bool, decrypt: (Data) throws -> Data) throws
    -> [(String, Date)]
  {
    if hasWAL, sqlite3_vfs_find("unix-none") == nil {
      throw DesktopCredentialError.unavailable
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw DesktopCredentialError.unsafePath
    }
    // immutable ignores committed WAL pages. unix-none instead uses SQLite's own
    // WAL recovery with a private heap index when EXCLUSIVE is set before access.
    // mode=ro also constrains WAL descriptors. Do not add nolock=1: SQLite disables
    // WAL support for that URI option. Without WAL, immutable avoids sidecar creation.
    components.queryItems = [
      URLQueryItem(name: "mode", value: "ro"),
      hasWAL
        ? URLQueryItem(name: "vfs", value: "unix-none")
        : URLQueryItem(name: "immutable", value: "1"),
    ]
    guard let uri = components.string else { throw DesktopCredentialError.unsafePath }
    var connection: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
    let status = sqlite3_open_v2(uri, &connection, flags, nil)
    defer { sqlite3_close(connection) }
    guard status == SQLITE_OK, let connection, sqlite3_db_readonly(connection, "main") == 1 else {
      throw DesktopCredentialError.invalidStore
    }

    sqlite3_busy_timeout(connection, 0)
    // Apple's SQLite module omits extension loading. The authorizer also denies
    // all SQL functions and schema indirection; no extension-loading API is used.
    sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 65_536)
    sqlite3_limit(connection, SQLITE_LIMIT_SQL_LENGTH, 4_096)
    sqlite3_limit(connection, SQLITE_LIMIT_COLUMN, 64)
    sqlite3_limit(connection, SQLITE_LIMIT_EXPR_DEPTH, 16)
    sqlite3_limit(connection, SQLITE_LIMIT_COMPOUND_SELECT, 1)
    sqlite3_limit(connection, SQLITE_LIMIT_VDBE_OP, 4_096)
    sqlite3_limit(connection, SQLITE_LIMIT_ATTACHED, 0)
    sqlite3_limit(connection, SQLITE_LIMIT_VARIABLE_NUMBER, 0)
    sqlite3_limit(connection, SQLITE_LIMIT_TRIGGER_DEPTH, 0)
    sqlite3_limit(connection, SQLITE_LIMIT_WORKER_THREADS, 0)
    // These settings are connection-local. EXCLUSIVE is not an OS lock with this
    // VFS; it selects a heap WAL index and leaves the source SHM untouched.
    let settings =
      (hasWAL ? "PRAGMA locking_mode=EXCLUSIVE; " : "")
      + "PRAGMA query_only=ON; PRAGMA temp_store=MEMORY; PRAGMA trusted_schema=OFF;"
    guard
      sqlite3_exec(connection, settings, nil, nil, nil) == SQLITE_OK
    else { throw DesktopCredentialError.invalidStore }

    var budget = QueryBudget()
    return try withUnsafeMutablePointer(to: &budget) { budgetPointer in
      sqlite3_progress_handler(
        connection, 1_000,
        { context in
          guard let context else { return 1 }
          let budget = context.assumingMemoryBound(to: QueryBudget.self)
          budget.pointee.callsRemaining -= 1
          return budget.pointee.callsRemaining <= 0
            || DispatchTime.now().uptimeNanoseconds >= budget.pointee.deadline ? 1 : 0
        }, budgetPointer)
      defer { sqlite3_progress_handler(connection, 0, nil, nil) }
      guard
        sqlite3_set_authorizer(
          connection,
          { _, action, table, column, database, origin in
            guard origin == nil else { return SQLITE_DENY }
            if action == SQLITE_SELECT { return SQLITE_OK }
            guard action == SQLITE_READ, let table, let column, let database,
              String(cString: table) == "cookies", String(cString: database) == "main",
              [
                "host_key", "name", "path", "value", "encrypted_value", "expires_utc",
                "has_expires",
                "is_persistent",
              ].contains(String(cString: column))
            else { return SQLITE_DENY }
            return SQLITE_OK
          }, nil) == SQLITE_OK
      else { throw DesktopCredentialError.invalidStore }

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw DesktopCredentialError.invalidStore }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_stmt_readonly(statement) == 1 else { throw DesktopCredentialError.invalidStore }

      var values: [(String, Date)] = []
      var rows = 0
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { break }
        guard result == SQLITE_ROW else { throw DesktopCredentialError.invalidStore }
        rows += 1
        guard rows <= maximumRows else { throw DesktopCredentialError.inputTooLarge }
        guard (3...5).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER })
        else { throw DesktopCredentialError.invalidStore }
        let expiry = sqlite3_column_int64(statement, 3)
        let hasExpiry = sqlite3_column_int64(statement, 4)
        let persistent = sqlite3_column_int64(statement, 5)
        guard (0...1).contains(hasExpiry), persistent == hasExpiry, expiry >= 0 else {
          throw DesktopCredentialError.invalidStore
        }
        // A persisted session cookie has no verifiable lifetime in this reader.
        // Only unexpired, persistent cookies may establish active organization.
        guard hasExpiry == 1 else { continue }
        let expiresAt = Date(
          timeIntervalSince1970: Double(expiry) / 1_000_000 - chromiumEpochOffset)
        guard expiresAt > Date() else { continue }
        let host = try text(statement, 0, maximumBytes: 16)
        guard host == ".claude.ai" || host == "claude.ai" else {
          throw DesktopCredentialError.invalidStore
        }
        let plain = try text(statement, 1, maximumBytes: 36)
        guard sqlite3_column_type(statement, 2) == SQLITE_BLOB else {
          throw DesktopCredentialError.invalidStore
        }
        let encryptedSize = sqlite3_column_bytes(statement, 2)
        guard encryptedSize == 0 || encryptedSize == 83 else {
          throw DesktopCredentialError.invalidStore
        }
        let organization: String
        if !plain.isEmpty {
          guard encryptedSize == 0 else { throw DesktopCredentialError.invalidStore }
          organization = try DesktopIdentity.canonicalUUID(plain)
        } else {
          guard encryptedSize == 83, let bytes = sqlite3_column_blob(statement, 2) else {
            throw DesktopCredentialError.identityUnavailable
          }
          let encrypted = Data(bytes: bytes, count: Int(encryptedSize))
          guard encrypted.starts(with: Data("v10".utf8)) else {
            throw DesktopCredentialError.invalidStore
          }
          let decrypted = try decrypt(encrypted)
          let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
          guard decrypted.count == 68, decrypted.starts(with: hostHash),
            let value = String(data: decrypted.dropFirst(32), encoding: .utf8)
          else { throw DesktopCredentialError.identityUnavailable }
          organization = try DesktopIdentity.canonicalUUID(value)
        }
        values.append((organization, expiresAt))
      }
      return values
    }
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32, maximumBytes: Int) throws
    -> String
  {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT else {
      throw DesktopCredentialError.invalidStore
    }
    let count = sqlite3_column_bytes(statement, column)
    guard count >= 0, count <= maximumBytes else { throw DesktopCredentialError.inputTooLarge }
    if count == 0 { return "" }
    guard let bytes = sqlite3_column_text(statement, column),
      let value = String(data: Data(bytes: bytes, count: Int(count)), encoding: .utf8)
    else { throw DesktopCredentialError.invalidStore }
    return value
  }

  private struct QueryBudget {
    var callsRemaining = 200
    let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
  }
}
