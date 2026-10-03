import Darwin
import Foundation

public enum ClaudeBrowserBridgeError: String, Error {
  case invalidMessage
  case staleMessage
  case profileMismatch
  case accountMismatch
  case inputTooLarge
  case truncatedMessage
  case connectionMismatch
  case bridgeBusy
  case connectionLimitReached
}

public enum NativeMessageFraming {
  public static let maximumBytes = 16 * 1_024

  public static func read(from handle: FileHandle) throws -> Data {
    let header = try readExactly(4, from: handle)
    let size = header.enumerated().reduce(UInt32(0)) {
      $0 | (UInt32($1.element) << ($1.offset * 8))
    }
    guard size > 0, size <= maximumBytes else { throw ClaudeBrowserBridgeError.inputTooLarge }
    return try readExactly(Int(size), from: handle)
  }

  public static func frame(_ data: Data) throws -> Data {
    guard !data.isEmpty, data.count <= maximumBytes else {
      throw ClaudeBrowserBridgeError.inputTooLarge
    }
    let size = UInt32(data.count)
    var result = Data((0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
    result.append(data)
    return result
  }

  private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    var result = Data()
    while result.count < count {
      let chunk = try handle.read(upToCount: count - result.count) ?? Data()
      guard !chunk.isEmpty else { throw ClaudeBrowserBridgeError.truncatedMessage }
      result.append(chunk)
    }
    return result
  }
}

public struct ClaudeBrowserMessage: Decodable, Sendable {
  public enum Status: String, Codable, Sendable {
    case ok, signedOut, accountChanged, unavailable, rateLimited
    case organizationSelectionRequired, connected, disconnected
  }

  public struct Window: Decodable, Sendable {
    let remainingPercent: Double
    let resetAt: String
  }

  let schemaVersion: Int
  let profileID: String
  let connectionID: String
  let sequence: Int
  let observedAt: String
  let status: Status
  let accountFingerprint: String?
  let organizationFingerprint: String?
  let principalFingerprint: String?
  let weekly: Window?
  let fiveHour: Window?

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= NativeMessageFraming.maximumBytes else {
      throw ClaudeBrowserBridgeError.inputTooLarge
    }
    do { return try JSONDecoder().decode(Self.self, from: data) } catch {
      throw ClaudeBrowserBridgeError.invalidMessage
    }
  }

  fileprivate func validate(now: Date) throws -> Date {
    guard schemaVersion == 1, UUID(uuidString: profileID) != nil,
      UUID(uuidString: connectionID) != nil, (0...9_007_199_254_740_991).contains(sequence),
      let observed = Self.date(observedAt), observed.timeIntervalSince1970 > 0,
      observed <= now.addingTimeInterval(30),
      (status != .ok && status != .connected) || now.timeIntervalSince(observed) <= 300
    else { throw ClaudeBrowserBridgeError.invalidMessage }
    if status == .ok {
      guard Self.isFingerprint(accountFingerprint), Self.isFingerprint(organizationFingerprint),
        Self.isFingerprint(principalFingerprint), weekly != nil
      else { throw ClaudeBrowserBridgeError.invalidMessage }
      _ = try Self.window(weekly, duration: 604_800, maximum: 691_200, observedAt: observed)
      _ = try Self.window(fiveHour, duration: 18_000, maximum: 21_600, observedAt: observed)
    } else {
      guard weekly == nil, fiveHour == nil else { throw ClaudeBrowserBridgeError.invalidMessage }
    }
    return min(observed, now)
  }

  fileprivate static func date(_ value: String) -> Date? {
    guard
      value.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#,
        options: .regularExpression) != nil
    else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  fileprivate static func isFingerprint(_ value: String?) -> Bool {
    guard let value, value.utf8.count == 64 else { return false }
    return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  fileprivate static func window(
    _ input: Window?, duration: TimeInterval, maximum: TimeInterval, observedAt: Date
  ) throws -> QuotaWindow? {
    guard let input else { return nil }
    guard input.remainingPercent.isFinite, (0...100).contains(input.remainingPercent),
      let reset = date(input.resetAt), reset > observedAt,
      reset.timeIntervalSince(observedAt) <= maximum
    else { throw ClaudeBrowserBridgeError.invalidMessage }
    return QuotaWindow(
      remainingPercent: input.remainingPercent, durationSeconds: duration, resetAt: reset)
  }
}

public struct ClaudeBrowserRecord: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let profileID: String
  let connectionID: String
  let lastSequence: Int
  let lastStatus: ClaudeBrowserMessage.Status
  let retiredConnectionIDs: [String]
  let accountFingerprint: String?
  let organizationFingerprint: String?
  let principalFingerprint: String?
  let lastMessageAt: Date
  let enabled: Bool
  let snapshot: ProviderSnapshot

  public static func applying(
    _ message: ClaudeBrowserMessage, to previous: Self?, now: Date
  ) throws -> Self {
    let observed = try message.validate(now: now)
    // The app may revoke without the extension's next sequence. A later explicit
    // extension Disconnect acknowledges that same revocation without reopening it.
    if let previous, !previous.enabled, previous.lastStatus == .disconnected,
      message.status == .disconnected,
      UUID(uuidString: previous.profileID) == UUID(uuidString: message.profileID),
      UUID(uuidString: previous.connectionID) == UUID(uuidString: message.connectionID),
      message.sequence >= previous.lastSequence
    {
      return previous
    }
    // A lost ACK can replay a value-free control message without changing the
    // observation time. Successful quota observations are never replayed.
    if let previous, message.status != .ok, message.status == previous.lastStatus,
      UUID(uuidString: previous.profileID) == UUID(uuidString: message.profileID),
      UUID(uuidString: previous.connectionID) == UUID(uuidString: message.connectionID),
      message.sequence == previous.lastSequence,
      previous.snapshot.weekly == nil, previous.snapshot.fiveHour == nil
    {
      return previous
    }
    if message.status == .connected {
      guard message.sequence == 0, previous?.enabled != true,
        previous.map({ observed >= $0.lastMessageAt }) ?? true,
        previous?.retiredConnectionIDs.contains(message.connectionID.lowercased()) != true,
        previous.map({ UUID(uuidString: $0.connectionID) != UUID(uuidString: message.connectionID) }
        )
          ?? true
      else { throw ClaudeBrowserBridgeError.connectionMismatch }
      guard (previous?.retiredConnectionIDs.count ?? 0) < 128 else {
        throw ClaudeBrowserBridgeError.connectionLimitReached
      }
    } else {
      guard let previous, previous.enabled,
        UUID(uuidString: previous.connectionID) == UUID(uuidString: message.connectionID)
      else { throw ClaudeBrowserBridgeError.connectionMismatch }
      guard UUID(uuidString: previous.profileID) == UUID(uuidString: message.profileID) else {
        throw ClaudeBrowserBridgeError.profileMismatch
      }
      guard message.sequence > previous.lastSequence else {
        throw ClaudeBrowserBridgeError.staleMessage
      }
    }
    if message.status == .ok, previous?.enabled == true, let old = previous?.accountFingerprint {
      guard old == message.accountFingerprint,
        previous?.organizationFingerprint == message.organizationFingerprint,
        previous?.principalFingerprint == message.principalFingerprint
      else { throw ClaudeBrowserBridgeError.accountMismatch }
    }

    let snapshot: ProviderSnapshot
    if message.status == .ok {
      snapshot = ProviderSnapshot(
        provider: .claude, source: .claudeBrowser, capturedAt: observed,
        weekly: try ClaudeBrowserMessage.window(
          message.weekly, duration: 604_800, maximum: 691_200, observedAt: observed),
        fiveHour: try ClaudeBrowserMessage.window(
          message.fiveHour, duration: 18_000, maximum: 21_600, observedAt: observed),
        lastAttemptAt: observed, sourceState: .observationSucceeded,
        claudeAccountFingerprint: message.accountFingerprint,
        claudeOrganizationFingerprint: message.organizationFingerprint)
    } else {
      let temporary = message.status == .unavailable || message.status == .rateLimited
      let retained = temporary && previous?.enabled == true ? previous?.snapshot : nil
      snapshot = AcquisitionRecords.preservingFailure(
        previous: retained, provider: .claude, source: .claudeBrowser,
        attemptedAt: observed, state: .attemptFailed,
        error: message.status == .signedOut
          ? .authenticationRequired
          : (message.status == .rateLimited ? .temporaryFailure : .sourceUnavailable))
    }
    let binding = previous?.enabled == true ? previous : nil
    var retired = previous?.retiredConnectionIDs ?? []
    if message.status == .disconnected {
      retired.append(message.connectionID.lowercased())
    }
    return Self(
      schemaVersion: 1, profileID: message.profileID.lowercased(),
      connectionID: message.connectionID.lowercased(), lastSequence: message.sequence,
      lastStatus: message.status,
      retiredConnectionIDs: retired,
      accountFingerprint: message.status == .ok
        ? message.accountFingerprint : binding?.accountFingerprint,
      organizationFingerprint: message.status == .ok
        ? message.organizationFingerprint : binding?.organizationFingerprint,
      principalFingerprint: message.status == .ok
        ? message.principalFingerprint : binding?.principalFingerprint,
      lastMessageAt: max(observed, snapshot.capturedAt ?? observed),
      enabled: message.status != .disconnected, snapshot: snapshot)
  }
}

public struct ClaudeBrowserStore: Sendable {
  public static let filename = "browser-observation.json"
  public static let observationMaximumAge: TimeInterval = 15 * 60
  public let url: URL

  public init(directory: URL) { self.url = directory.appendingPathComponent(Self.filename) }

  public func load() throws -> ClaudeBrowserRecord? {
    guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: .default) else {
      throw ClaudeAutomaticAdapterError.unsafePath
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try FileBoundedLocalDataReader().read(
      from: url, limit: NormalizedSnapshotStore.maximumRecordBytes)
    let record = try JSONDecoder().decode(ClaudeBrowserRecord.self, from: data)
    guard record.schemaVersion == 1, UUID(uuidString: record.profileID) != nil,
      UUID(uuidString: record.connectionID) != nil,
      (0...9_007_199_254_740_991).contains(record.lastSequence),
      record.retiredConnectionIDs.count <= 128,
      record.retiredConnectionIDs.allSatisfy({
        UUID(uuidString: $0) != nil && $0 == $0.lowercased()
      }),
      Set(record.retiredConnectionIDs).count == record.retiredConnectionIDs.count,
      !record.enabled || !record.retiredConnectionIDs.contains(record.connectionID.lowercased()),
      record.lastMessageAt.timeIntervalSince1970.isFinite,
      record.snapshot.source == .claudeBrowser, record.snapshot.provider == .claude,
      record.lastMessageAt.timeIntervalSince1970 > 0,
      record.snapshot.capturedAt.map({ $0 <= record.lastMessageAt }) ?? true,
      record.snapshot.lastAttemptAt.map({ $0 <= record.lastMessageAt }) ?? true,
      [record.accountFingerprint, record.organizationFingerprint, record.principalFingerprint]
        .allSatisfy({ $0 == nil || ClaudeBrowserMessage.isFingerprint($0) })
    else { throw ClaudeBrowserBridgeError.invalidMessage }
    if record.snapshot.weekly != nil || record.snapshot.fiveHour != nil {
      guard ClaudeBrowserMessage.isFingerprint(record.accountFingerprint),
        ClaudeBrowserMessage.isFingerprint(record.principalFingerprint),
        ClaudeBrowserMessage.isFingerprint(record.organizationFingerprint),
        record.snapshot.claudeAccountFingerprint == record.accountFingerprint,
        record.snapshot.claudeOrganizationFingerprint == record.organizationFingerprint
      else { throw ClaudeBrowserBridgeError.invalidMessage }
    }
    _ = try NormalizedSnapshotCodec.encode(record.snapshot)
    return record
  }

  public func ingest(_ data: Data, now: Date) throws {
    try withConnectionLock { try ingestLocked(data, now: now) }
  }

  // A local, explicit revocation also works after the extension was removed.
  // Retiring the current connection rejects queued/late native-host messages.
  public func disconnect(now: Date) throws {
    try withConnectionLock {
      guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0 else {
        throw ClaudeBrowserBridgeError.invalidMessage
      }
      guard let previous = try load(), previous.enabled else { return }
      let disconnected = ClaudeBrowserRecord(
        schemaVersion: 1, profileID: previous.profileID, connectionID: previous.connectionID,
        lastSequence: previous.lastSequence, lastStatus: .disconnected,
        retiredConnectionIDs: previous.retiredConnectionIDs + [previous.connectionID],
        accountFingerprint: nil, organizationFingerprint: nil, principalFingerprint: nil,
        lastMessageAt: max(now, previous.lastMessageAt), enabled: false,
        snapshot: ProviderSnapshot(
          provider: .claude, source: .claudeBrowser, capturedAt: nil, weekly: nil,
          sourceState: .neverObserved))
      try FileAtomicDataWriter().write(JSONEncoder().encode(disconnected), to: url)
    }
  }

  private func ingestLocked(_ data: Data, now: Date) throws {
    let message = try ClaudeBrowserMessage.decode(data)
    let previous = try load()
    let record: ClaudeBrowserRecord
    do {
      record = try ClaudeBrowserRecord.applying(message, to: previous, now: now)
    } catch ClaudeBrowserBridgeError.accountMismatch {
      // A verified message for another owner revokes old display values, but
      // cannot silently rebind the browser connection to the new account.
      let invalidation = ClaudeBrowserMessage(
        schemaVersion: 1, profileID: message.profileID, connectionID: message.connectionID,
        sequence: message.sequence, observedAt: message.observedAt,
        status: .accountChanged, accountFingerprint: nil, organizationFingerprint: nil,
        principalFingerprint: nil, weekly: nil, fiveHour: nil)
      let revoked = try ClaudeBrowserRecord.applying(invalidation, to: previous, now: now)
      try FileAtomicDataWriter().write(JSONEncoder().encode(revoked), to: url)
      throw ClaudeBrowserBridgeError.accountMismatch
    }
    if record != previous {
      try FileAtomicDataWriter().write(JSONEncoder().encode(record), to: url)
    }
  }

  private func withConnectionLock<T>(_ action: () throws -> T) throws -> T {
    guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: .default) else {
      throw ClaudeAutomaticAdapterError.unsafePath
    }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lockURL = directory.appendingPathComponent("host.lock")
    let descriptor = open(
      lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw ClaudeBrowserBridgeError.invalidMessage }
    defer { close(descriptor) }
    var identity = stat()
    guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG,
      identity.st_uid == geteuid(), identity.st_nlink == 1, identity.st_mode & 0o7777 == 0o600
    else { throw ClaudeBrowserBridgeError.invalidMessage }
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
        throw ClaudeBrowserBridgeError.bridgeBusy
      }
      usleep(10_000)
    }
    defer { flock(descriptor, LOCK_UN) }
    var current = stat()
    guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: .default),
      lstat(lockURL.path, &current) == 0, current.st_dev == identity.st_dev,
      current.st_ino == identity.st_ino
    else { throw ClaudeBrowserBridgeError.invalidMessage }
    return try action()
  }

  // A connected browser owns the whole Claude observation. It never lends just
  // its reset to a Desktop or CLI observation with a potentially different owner.
  public func selectedSnapshot(now: Date) -> ProviderSnapshot? {
    do {
      guard let record = try load(), record.enabled else { return nil }
      let snapshot = record.snapshot
      guard record.lastMessageAt <= now.addingTimeInterval(30) else {
        throw ClaudeBrowserBridgeError.invalidMessage
      }
      if let capturedAt = snapshot.capturedAt,
        now.timeIntervalSince(capturedAt) > Self.observationMaximumAge
      {
        // Expiry hides values, not ownership. Returning nil would allow a
        // different local account/probe to bypass browser pinning or 429 waits.
        // Neither error traffic nor UI refresh renews the successful capture.
        return ProviderSnapshot(
          provider: .claude, source: .claudeBrowser, capturedAt: nil, weekly: nil,
          lastAttemptAt: snapshot.lastAttemptAt, sourceState: .attemptFailed,
          errorCode: snapshot.errorCode ?? .sourceUnavailable)
      }
      return snapshot
    } catch {
      return ProviderSnapshot(
        provider: .claude, source: .claudeBrowser, capturedAt: nil, weekly: nil,
        sourceState: .attemptFailed, errorCode: .invalidResponse)
    }
  }
}
