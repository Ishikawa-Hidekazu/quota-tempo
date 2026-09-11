import Foundation
import ServiceManagement
import Testing

@testable import QuotaTempoCore

@Suite("Normalized storage hardening", .serialized)
struct StorageHardeningTests {
  private let now = Date(timeIntervalSince1970: 1_789_300_800)

  @Test("Versioned records round-trip and the previous unversioned schema remains readable")
  func schemaCompatibility() throws {
    let snapshot = self.snapshot(provider: .codex, source: .codexAppServer)
    let current = try NormalizedSnapshotCodec.encode(snapshot)
    let object = try #require(
      try JSONSerialization.jsonObject(with: current) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == NormalizedSnapshotCodec.schemaVersion)
    #expect(try NormalizedSnapshotCodec.decode(current) == snapshot)

    let legacyEncoder = JSONEncoder()
    legacyEncoder.dateEncodingStrategy = .iso8601
    let legacy = try legacyEncoder.encode(snapshot)
    #expect(try NormalizedSnapshotCodec.decode(legacy) == snapshot)

    var future = object
    future["schemaVersion"] = NormalizedSnapshotCodec.schemaVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: future)
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.decode(futureData)
    }
  }

  @Test("Oversized normalized input is rejected and recovers as never observed")
  func oversizedRecord() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = NormalizedSnapshotStore(directory: root)
    try Data(repeating: 0x20, count: NormalizedSnapshotStore.maximumRecordBytes + 1)
      .write(to: store.url(for: .codex))

    #expect(throws: SnapshotStoreError.inputTooLarge) { try store.load(.codex) }
    let recovered = try #require(
      store.scenario(now: self.now).snapshots.first { $0.provider == .codex }
    )
    #expect(recovered.sourceState == .neverObserved)
    #expect(recovered.capturedAt == nil)
  }

  @Test("A symlink in normalized storage ancestry is rejected")
  func symlinkAncestor() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    let linked = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    let store = NormalizedSnapshotStore(directory: linked)
    try NormalizedSnapshotCodec.encode(self.snapshot(provider: .codex, source: .codexAppServer))
      .write(to: real.appendingPathComponent("codex.json"))

    #expect(throws: SnapshotStoreError.unsafeOutput) { try store.load(.codex) }
    let recovered = try #require(
      store.scenario(now: self.now).snapshots.first { $0.provider == .codex }
    )
    #expect(recovered.sourceState == .neverObserved)
  }

  @Test("Corrupt normalized input is discarded safely")
  func corruptRecordRecovery() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = NormalizedSnapshotStore(directory: root)
    try Data("{broken".utf8).write(to: store.url(for: .claude))

    #expect(throws: SnapshotStoreError.invalidRecord) { try store.load(.claude) }
    let recovered = try #require(
      store.scenario(now: self.now).snapshots.first { $0.provider == .claude }
    )
    #expect(recovered.sourceState == .neverObserved)
    #expect(recovered.capturedAt == nil)
  }

  @Test("Provider identity and source semantics fail closed")
  func providerAndSourceSemantics() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = NormalizedSnapshotStore(directory: root)

    let claude = self.snapshot(provider: .claude, source: .claudeLocalCache)
    try NormalizedSnapshotCodec.encode(claude).write(to: store.url(for: .codex))
    #expect(throws: SnapshotStoreError.invalidRecord) { try store.load(.codex) }

    var object = try #require(
      try JSONSerialization.jsonObject(
        with: NormalizedSnapshotCodec.encode(
          self.snapshot(provider: .codex, source: .codexAppServer)
        )
      ) as? [String: Any]
    )
    var nested = try #require(object["snapshot"] as? [String: Any])
    nested["source"] = SnapshotSource.claudeLocalCache.rawValue
    object["snapshot"] = nested
    let mismatchedSource = try JSONSerialization.data(withJSONObject: object)
    try mismatchedSource.write(to: store.url(for: .codex))
    #expect(throws: SnapshotStoreError.invalidRecord) { try store.load(.codex) }
  }

  @Test("Invalid normalized percentages durations and timestamps are rejected")
  func semanticBounds() {
    let invalidPercent = ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: self.now,
      weekly: QuotaWindow(
        remainingPercent: 101,
        durationSeconds: 7 * 24 * 60 * 60,
        resetAt: self.now.addingTimeInterval(300)
      ),
      sourceState: .observationSucceeded
    )
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.encode(invalidPercent)
    }

    let invalidDuration = ProviderSnapshot(
      provider: .claude,
      source: .claudeDesktopHistory,
      capturedAt: self.now,
      weekly: QuotaWindow(
        remainingPercent: 50,
        durationSeconds: 60,
        resetAt: nil
      ),
      sourceState: .observationSucceeded
    )
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.encode(invalidDuration)
    }

    let invalidTimestamp = ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: Date(timeIntervalSince1970: -1),
      weekly: nil,
      lastAttemptAt: self.now,
      sourceState: .attemptFailed,
      errorCode: .sourceUnavailable
    )
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.encode(invalidTimestamp)
    }
  }

  @Test("Executable metadata is provider scoped and normalized")
  func executableMetadata() {
    let claudeWithCodexMetadata = ProviderSnapshot(
      provider: .claude,
      source: .claudeDesktopHistory,
      capturedAt: nil,
      weekly: nil,
      sourceState: .neverObserved,
      codexExecutableSource: .desktopBundled
    )
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.encode(claudeWithCodexMetadata)
    }

    let versionWithoutSource = ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: nil,
      weekly: nil,
      sourceState: .attemptFailed,
      errorCode: .versionTooOld,
      codexExecutableVersion: "0.133.0"
    )
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.encode(versionWithoutSource)
    }

    for unsafeVersion in [
      "codex-cli 0.133.0", "00.133.0", "0.133.0\n/path/to/codex", "123456.1.1",
    ] {
      let snapshot = ProviderSnapshot(
        provider: .codex,
        source: .codexAppServer,
        capturedAt: nil,
        weekly: nil,
        sourceState: .attemptFailed,
        errorCode: .versionTooOld,
        codexExecutableSource: .packageManager,
        codexExecutableVersion: unsafeVersion
      )
      #expect(throws: SnapshotStoreError.invalidRecord) {
        try NormalizedSnapshotCodec.encode(snapshot)
      }
    }

    let normalized = ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: nil,
      weekly: nil,
      sourceState: .attemptFailed,
      errorCode: .versionTooOld,
      codexExecutableSource: .packageManager,
      codexExecutableVersion: "0.133.0"
    )
    #expect((try? NormalizedSnapshotCodec.encode(normalized)) != nil)
  }

  @Test("Exact-path normalized reads enforce the same bounds and provider identity")
  func exactPathReader() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("bridge-output.json")
    try NormalizedSnapshotCodec.encode(
      self.snapshot(provider: .codex, source: .codexAppServer)
    ).write(to: output)

    #expect(
      try NormalizedSnapshotStore.load(from: output, expectedProvider: .codex)?.provider == .codex
    )
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotStore.load(from: output, expectedProvider: .claude)
    }

    try Data(repeating: 0x20, count: NormalizedSnapshotStore.maximumRecordBytes + 1)
      .write(to: output)
    #expect(throws: SnapshotStoreError.inputTooLarge) {
      try NormalizedSnapshotStore.load(from: output, expectedProvider: .codex)
    }
  }

  @Test("ServiceManagement not-found remains registrable for a first launch")
  func loginItemNotFound() {
    #expect(LoginItemState.from(.notRegistered) == .disabled)
    #expect(LoginItemState.from(.notFound) == .disabled)
    #expect(LoginItemState.canRegister(.notFound))
  }

  private func snapshot(provider: ProviderID, source: SnapshotSource) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: provider,
      source: source,
      capturedAt: self.now,
      weekly: QuotaWindow(
        remainingPercent: 60,
        durationSeconds: 7 * 24 * 60 * 60,
        resetAt: self.now.addingTimeInterval(300_000)
      ),
      fiveHour: QuotaWindow(
        remainingPercent: 70,
        durationSeconds: 5 * 60 * 60,
        resetAt: self.now.addingTimeInterval(10_000)
      ),
      lastAttemptAt: self.now,
      sourceState: .observationSucceeded
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "QuotaTempoStorageHardeningTests.\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
