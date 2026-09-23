import Foundation

public protocol AtomicDataWriting: Sendable {
  func write(_ data: Data, to url: URL) throws
}

public struct FileAtomicDataWriter: AtomicDataWriting {
  public init() {}

  public func write(_ data: Data, to url: URL) throws {
    let manager = FileManager.default
    guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: manager) else {
      throw SnapshotStoreError.unsafeOutput
    }
    let parent = url.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
      guard values.isSymbolicLink != true, values.isRegularFile == true else {
        throw SnapshotStoreError.unsafeOutput
      }
    }

    let temporary = parent.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.atomic])
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if manager.fileExists(atPath: url.path) {
      _ = try manager.replaceItemAt(url, withItemAt: temporary)
    } else {
      try manager.moveItem(at: temporary, to: url)
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

enum LocalPathSafety {
  static func containsSymlink(atOrAbove url: URL, fileManager: FileManager) -> Bool {
    let standardized = url.standardizedFileURL
    let canonicalPath: String
    if standardized.path == "/tmp" || standardized.path.hasPrefix("/tmp/") {
      canonicalPath = "/private\(standardized.path)"
    } else if standardized.path == "/var" || standardized.path.hasPrefix("/var/") {
      canonicalPath = "/private\(standardized.path)"
    } else {
      canonicalPath = standardized.path
    }

    var candidate = URL(fileURLWithPath: "/")
    for component in URL(fileURLWithPath: canonicalPath).pathComponents.dropFirst() {
      candidate.appendPathComponent(component)
      if (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
        return true
      }
      guard fileManager.fileExists(atPath: candidate.path) else { continue }
      if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        return true
      }
    }
    return false
  }
}

public enum SnapshotStoreError: Error, Equatable {
  case unsafeOutput
  case inputTooLarge
  case invalidRecord
}

public struct NormalizedSnapshotStore: Sendable {
  public static let maximumRecordBytes = 64 * 1_024

  public let directory: URL
  private let writer: any AtomicDataWriting

  public init(directory: URL, writer: any AtomicDataWriting = FileAtomicDataWriter()) {
    self.directory = directory
    self.writer = writer
  }

  public func url(for provider: ProviderID) -> URL {
    self.directory.appendingPathComponent("\(provider.rawValue).json")
  }

  public func load(_ provider: ProviderID) throws -> ProviderSnapshot? {
    try Self.load(from: self.url(for: provider), expectedProvider: provider)
  }

  public static func load(
    from url: URL,
    expectedProvider provider: ProviderID
  ) throws -> ProviderSnapshot? {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return nil }
    guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: manager) else {
      throw SnapshotStoreError.unsafeOutput
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw SnapshotStoreError.unsafeOutput }
    guard let size = values.fileSize, size <= self.maximumRecordBytes else {
      throw SnapshotStoreError.inputTooLarge
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: self.maximumRecordBytes + 1) ?? Data()
    guard data.count <= self.maximumRecordBytes else {
      throw SnapshotStoreError.inputTooLarge
    }
    let snapshot = try NormalizedSnapshotCodec.decode(data)
    guard snapshot.provider == provider else { throw SnapshotStoreError.invalidRecord }
    return snapshot
  }

  public func save(_ snapshot: ProviderSnapshot) throws {
    guard snapshot.source != .fixture else { throw SnapshotStoreError.invalidRecord }
    try self.writer.write(
      try NormalizedSnapshotCodec.encode(snapshot), to: self.url(for: snapshot.provider))
  }

  public func scenario(now: Date) -> FixtureScenario {
    let snapshots = ProviderID.allCases.map { provider -> ProviderSnapshot in
      if let snapshot = try? self.load(provider) { return snapshot }
      return ProviderSnapshot(
        provider: provider,
        source: provider == .codex ? .codexAppServer : .claudeDesktopHistory,
        capturedAt: nil,
        weekly: nil,
        sourceState: .neverObserved
      )
    }
    return FixtureScenario(id: "normalized-local", now: now, snapshots: snapshots)
  }

}

public enum SnapshotScenarioOverlay {
  public static func currentSnapshot(
    for provider: ProviderID,
    stored: ProviderSnapshot?,
    overrides: [ProviderID: ProviderSnapshot]
  ) -> ProviderSnapshot? {
    overrides[provider] ?? stored
  }

  public static func apply(
    _ overrides: [ProviderID: ProviderSnapshot],
    to scenario: FixtureScenario,
    now: Date
  ) -> FixtureScenario {
    let snapshots = scenario.snapshots.map { overrides[$0.provider] ?? $0 }
    return FixtureScenario(id: scenario.id, now: now, snapshots: snapshots)
  }
}

public enum NormalizedSnapshotCodec {
  public static let schemaVersion = 1

  public static func encode(_ snapshot: ProviderSnapshot) throws -> Data {
    guard self.isSemanticallyValid(snapshot) else { throw SnapshotStoreError.invalidRecord }
    return try self.encoder.encode(
      VersionedNormalizedSnapshot(schemaVersion: self.schemaVersion, snapshot: snapshot)
    )
  }

  public static func decode(_ data: Data) throws -> ProviderSnapshot {
    let snapshot: ProviderSnapshot
    do {
      let probe = try self.decoder.decode(NormalizedSnapshotSchemaProbe.self, from: data)
      if probe.containsSchemaVersion {
        guard probe.schemaVersion == self.schemaVersion else {
          throw SnapshotStoreError.invalidRecord
        }
        snapshot = try self.decoder.decode(VersionedNormalizedSnapshot.self, from: data).snapshot
      } else {
        // RC12 and earlier wrote ProviderSnapshot directly. Keep that one explicit legacy
        // format readable so an update does not discard a valid local observation.
        snapshot = try self.decoder.decode(ProviderSnapshot.self, from: data)
      }
    } catch let error as SnapshotStoreError {
      throw error
    } catch {
      throw SnapshotStoreError.invalidRecord
    }
    guard self.isSemanticallyValid(snapshot) else { throw SnapshotStoreError.invalidRecord }
    return snapshot
  }

  private static func isSemanticallyValid(_ snapshot: ProviderSnapshot) -> Bool {
    guard self.source(snapshot.source, belongsTo: snapshot.provider) else { return false }
    guard self.hasValidExecutableMetadata(snapshot) else { return false }
    guard self.isValidDate(snapshot.capturedAt), self.isValidDate(snapshot.lastAttemptAt) else {
      return false
    }
    guard self.isValidWindow(snapshot.weekly, kind: .weekly),
      self.isValidWindow(snapshot.fiveHour, kind: .fiveHour)
    else { return false }
    if (snapshot.weekly != nil || snapshot.fiveHour != nil) && snapshot.capturedAt == nil {
      return false
    }
    if snapshot.sourceState == .observationSucceeded {
      guard snapshot.capturedAt != nil, snapshot.weekly != nil || snapshot.fiveHour != nil,
        snapshot.errorCode == nil
      else { return false }
    }
    if snapshot.sourceState == .accessRestricted, snapshot.errorCode != .usageRestricted {
      return false
    }
    if snapshot.sourceState == .attemptTimedOut, snapshot.errorCode != .timeout {
      return false
    }
    if snapshot.sourceState == .attemptFailed, snapshot.errorCode == nil { return false }
    return true
  }

  private static func hasValidExecutableMetadata(_ snapshot: ProviderSnapshot) -> Bool {
    switch snapshot.provider {
    case .claude:
      return snapshot.codexExecutableSource == nil && snapshot.codexExecutableVersion == nil
    case .codex:
      guard snapshot.codexExecutableVersion == nil || snapshot.codexExecutableSource != nil else {
        return false
      }
      guard let version = snapshot.codexExecutableVersion else { return true }
      return self.isNormalizedSemanticVersion(version)
    }
  }

  private static func isNormalizedSemanticVersion(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 17 else { return false }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return false }
    return components.allSatisfy { component in
      guard (1...5).contains(component.utf8.count), component.allSatisfy(\.isASCII) else {
        return false
      }
      guard component.allSatisfy(\.isNumber) else { return false }
      return component == "0" || component.first != "0"
    }
  }

  private static func source(_ source: SnapshotSource, belongsTo provider: ProviderID) -> Bool {
    switch provider {
    case .codex:
      return source == .codexAppServer
    case .claude:
      return source == .claudeStatusLine || source == .claudeDesktopHistory
        || source == .claudeLocalCache || source == .claudeLocalMerged || source == .claudeCLI
    }
  }

  private static func isValidDate(_ date: Date?) -> Bool {
    guard let date else { return true }
    let interval = date.timeIntervalSince1970
    return interval.isFinite && interval >= 0
  }

  private static func isValidWindow(_ window: QuotaWindow?, kind: WindowKind) -> Bool {
    guard let window else { return true }
    guard window.remainingPercent.isFinite, (0...100).contains(window.remainingPercent),
      window.durationSeconds.isFinite, kind.durationRange.contains(window.durationSeconds),
      self.isValidDate(window.resetAt)
    else { return false }
    if window.isResetEstimated && window.resetAt == nil { return false }
    return true
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

private struct VersionedNormalizedSnapshot: Codable {
  let schemaVersion: Int
  let snapshot: ProviderSnapshot
}

private struct NormalizedSnapshotSchemaProbe: Decodable {
  let containsSchemaVersion: Bool
  let schemaVersion: Int?

  private enum CodingKeys: String, CodingKey { case schemaVersion }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.containsSchemaVersion = container.contains(.schemaVersion)
    self.schemaVersion = try? container.decode(Int.self, forKey: .schemaVersion)
  }
}

private enum WindowKind {
  case weekly
  case fiveHour

  var durationRange: ClosedRange<TimeInterval> {
    switch self {
    case .weekly:
      return (6 * 24 * 60 * 60)...(8 * 24 * 60 * 60)
    case .fiveHour:
      return (4 * 60 * 60)...(6 * 60 * 60)
    }
  }
}

public enum AcquisitionRecords {
  public static func preservingFailure(
    previous: ProviderSnapshot?,
    provider: ProviderID,
    source: SnapshotSource,
    attemptedAt: Date?,
    state: SourceState,
    error: AcquisitionErrorCode
  ) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: provider,
      source: source,
      capturedAt: previous?.capturedAt,
      weekly: previous?.weekly,
      fiveHour: previous?.fiveHour,
      lastAttemptAt: attemptedAt,
      sourceState: state,
      errorCode: error,
      codexExecutableSource: previous?.codexExecutableSource,
      codexExecutableVersion: previous?.codexExecutableVersion
    )
  }
}
