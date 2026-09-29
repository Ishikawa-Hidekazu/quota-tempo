import CryptoKit
import Foundation
import Testing

@testable import QuotaTempoCore

private struct SignedOutPTY: ClaudeUsageProbing {
  func capture(executable: URL, workingDirectory: URL) throws -> Data {
    throw ClaudeUsagePTYProbeError.authenticationRequired
  }
}

private final class CountingCacheReader: BoundedLocalDataReading, @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0

  var readCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  func read(from url: URL, limit: Int) throws -> Data {
    lock.lock()
    reads += 1
    lock.unlock()
    return try FileBoundedLocalDataReader().read(from: url, limit: limit)
  }
}

struct ClaudeDesktopUsageCacheTests {
  private static let org = "123e4567-e89b-12d3-a456-426614174000"
  private static let otherOrg = "123e4567-e89b-12d3-a456-426614174001"
  private static let now = ISO8601DateFormatter().date(from: "2026-09-29T02:00:00Z")!
  private static let topLevelFrame = Data(
    base64Encoded:
      "KLUv/QRYBQMA8gUVGoDHOdCI3TQ1N3AiQU+KhMCQIFVy8+mGzBkB7/lI1ETNwcCjD4QFUMgy23yej19/xRuZUB4V6clqt1Rz21bxIQg1kjC3CmzA3OJGrSyJQC3DAm4CAgBEJNAUXjADzz+hzA=="
  )!
  private static let limitsFrame = Data(
    base64Encoded:
      "KLUv/QRY5QMAUgcZHGBr23Dmgsdjih+DhLZ0FxQFJbHgT6M2IEMQLBdPAdAay6W5NI9kYcIDBcsiGkMrjMbsLtDzAaIi6sIkVUpMAYXq+seUftubOEIQvWv4sQY3foqju4a7t69fHDN3CPp+fOB2JwcATMyQseQ2ARkArSDBoEAvKUU4A+AtXpw="
  )!

  private func entry(
    org: String = Self.org, frame: Data = Self.topLevelFrame,
    httpDate: String = "Tue, 29 Sep 2026 02:00:00 GMT"
  ) -> Data {
    simpleEntry(
      key: "https://claude.ai/api/organizations/\(org)/usage?source=desktop",
      frame: frame,
      headers: Data("\0HTTP/1.1 200 OK\0Date:\(httpDate)\0content-encoding:zstd\0".utf8))
  }

  private func simpleEntry(key: String, frame: Data, headers: Data) -> Data {
    func word(_ value: UInt32) -> [UInt8] {
      (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }
    let initialMagic: [UInt8] = [0x30, 0x5C, 0x72, 0xA7, 0x1B, 0x6D, 0xFB, 0xFC]
    let finalMagic: [UInt8] = [0xD8, 0x41, 0x0D, 0x97, 0x45, 0x6F, 0xFA, 0xF4]
    func crc32(_ bytes: Data) -> UInt32 {
      var value: UInt32 = 0xFFFF_FFFF
      for byte in bytes {
        value ^= UInt32(byte)
        for _ in 0..<8 {
          value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320)
        }
      }
      return ~value
    }
    let keyData = Data([0, 0, 0, 0]) + Data(key.utf8)
    var data = Data(initialMagic)
    data.append(contentsOf: word(5))
    data.append(contentsOf: word(UInt32(keyData.count)))
    data.append(contentsOf: word(0))
    data.append(contentsOf: word(0))
    data.append(keyData)
    data.append(frame)
    data.append(contentsOf: finalMagic)
    data.append(contentsOf: word(1))
    data.append(contentsOf: word(crc32(frame)))
    data.append(contentsOf: word(0))
    data.append(contentsOf: word(0))
    data.append(headers)
    data.append(contentsOf: SHA256.hash(data: keyData))
    data.append(contentsOf: finalMagic)
    data.append(contentsOf: word(3))
    data.append(contentsOf: word(crc32(headers)))
    data.append(contentsOf: word(UInt32(headers.count)))
    data.append(contentsOf: word(0))
    return data
  }

  @Test("Chromium cache integrity fields reject corruption")
  func rejectsCorruptIntegrityFields() throws {
    let good = entry()
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(good) != nil)

    var version = good
    version[8] = 9
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(version) == nil)

    var header = good
    let encoding = try #require(header.range(of: Data("content-encoding:zstd".utf8)))
    header[encoding.upperBound - 4] = 90  // Zstd still parses after lowercasing.
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(header) == nil)

    var body = good
    body[24 + 4 + 100] ^= 1
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(body) == nil)

    var hash = good
    hash[hash.count - 24 - 32] ^= 1
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(hash) == nil)
  }

  @Test("Desktop cache decoder takes exact weekly and session resets from the top-level body")
  func parsesTopLevelUsage() throws {
    let observation = try #require(
      FileClaudeDesktopUsageCacheReader.parseEntry(entry()))
    #expect(observation.organizationUUID == Self.org)
    #expect(observation.weeklyUtilization == 3)
    #expect(observation.weeklyResetAt == ISO8601DateFormatter().date(from: "2026-10-05T19:59:59Z"))
    #expect(observation.fiveHourUtilization == 33)
  }

  @Test("Conflicting same-second Desktop responses are not selected arbitrarily")
  func rejectsConflictingResponses() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("first_0")
    let second = root.appendingPathComponent("second_0")
    try entry().write(to: first)
    try entry().write(to: second)
    for url in [first, second] {
      try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: url.path)
    }
    let reader = FileClaudeDesktopUsageCacheReader(directory: root)
    #expect(try reader.latest(now: Self.now, organizationFingerprint: nil) != nil)

    try entry(frame: Self.limitsFrame).write(to: second)
    try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: second.path)
    #expect(throws: ClaudeAutomaticAdapterError.conflictingResponse) {
      try reader.latest(now: Self.now, organizationFingerprint: nil)
    }
  }

  @Test("A later conflicting response clears a previously stored exact reset")
  func conflictClearsStoredReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org).write(to: historyURL)
    let firstURL = cacheDirectory.appendingPathComponent("first_0")
    try entry().write(to: firstURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: firstURL.path)
    let adapter = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe"))
    let first = adapter.refresh(previous: nil, now: Self.now)
    #expect(first.weekly?.resetAt != nil)

    let conflictingURL = cacheDirectory.appendingPathComponent("conflicting_0")
    try entry(frame: Self.limitsFrame).write(to: conflictingURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: conflictingURL.path)
    let rejected = adapter.refresh(previous: first, now: Self.now)
    #expect(rejected.weekly?.resetAt == nil)
    #expect(rejected.sourceState == .attemptFailed)
    #expect(rejected.errorCode == .invalidResponse)
  }

  @Test("A newer response wins over conflicting older responses regardless of file order")
  func newerResponseWins() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let olderA = root.appendingPathComponent("older-a_0")
    let olderB = root.appendingPathComponent("older-b_0")
    let newer = root.appendingPathComponent("newer_0")
    let olderDate = "Tue, 29 Sep 2026 01:59:59 GMT"
    try entry(httpDate: olderDate).write(to: olderA)
    try entry(frame: Self.limitsFrame, httpDate: olderDate).write(to: olderB)
    try entry(httpDate: "Tue, 29 Sep 2026 02:00:00 GMT").write(to: newer)
    for url in [olderA, olderB] {
      try FileManager.default.setAttributes(
        [.modificationDate: Self.now.addingTimeInterval(30)], ofItemAtPath: url.path)
    }
    try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: newer.path)

    let observation = try #require(
      try FileClaudeDesktopUsageCacheReader(directory: root).latest(
        now: Self.now, organizationFingerprint: nil))
    #expect(observation.capturedAt == Self.now)
    #expect(observation.fiveHourUtilization == 33)
  }

  @Test("Chromium body-before-headers cache layout supplies an exact reset")
  func parsesChromiumLayout() throws {
    let key = "https://claude.ai/api/organizations/\(Self.org)/usage?source=desktop"
    let data = simpleEntry(
      key: key, frame: Self.topLevelFrame,
      headers: Data(
        "\0HTTP/1.1 200 OK\0date:Tue, 29 Sep 2026 02:00:00 GMT\0content-encoding:zstd\0".utf8))
    let observation = try #require(FileClaudeDesktopUsageCacheReader.parseEntry(data))
    #expect(observation.weeklyResetAt == ISO8601DateFormatter().date(from: "2026-10-05T19:59:59Z"))
    #expect(observation.capturedAt == Self.now)
    let spaced = simpleEntry(
      key: key, frame: Self.topLevelFrame,
      headers: Data(
        "\0HTTP/1.1 200 OK\0date:Tue, 29 Sep 2026 02:00:00 GMT\0content-encoding: zstd\0".utf8))
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(spaced)?.weeklyResetAt != nil)
  }

  @Test("The all-model weekly row is selected instead of a scoped model")
  func parsesLimitsUsage() throws {
    let observation = try #require(
      FileClaudeDesktopUsageCacheReader.parseEntry(entry(frame: Self.limitsFrame)))
    #expect(observation.weeklyUtilization == 3)
    #expect(observation.fiveHourUtilization == 44)
  }

  @Test("Unrelated keys, truncated frames, and malformed endpoint suffixes fail closed")
  func rejectsInvalidEntries() {
    #expect(
      FileClaudeDesktopUsageCacheReader.parseEntry(Data("unrelated".utf8))
        == nil)
    #expect(
      FileClaudeDesktopUsageCacheReader.parseEntry(
        entry(frame: Data(Self.topLevelFrame.prefix(10)))) == nil)
    let key = "https://claude.ai/api/organizations/\(Self.org)/usage?source=desktop"
    let badKey = simpleEntry(
      key: "https://claude.ai/api/organizations/\(Self.org)/usage-billing",
      frame: Self.topLevelFrame,
      headers: Data(
        "\0HTTP/1.1 200 OK\0Date:Tue, 29 Sep 2026 02:00:00 GMT\0content-encoding:zstd\0".utf8))
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(badKey) == nil)
    let missingDate = simpleEntry(
      key: key, frame: Self.topLevelFrame,
      headers: Data("\0HTTP/1.1 200 OK\0content-encoding:zstd\0".utf8))
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(missingDate) == nil)
    let notSuccessful = simpleEntry(
      key: key, frame: Self.topLevelFrame,
      headers: Data(
        "\0HTTP/1.1 304 Not Modified\0Date:Tue, 29 Sep 2026 02:00:00 GMT\0content-encoding:zstd\0"
          .utf8))
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(notSuccessful) == nil)
    let mixedResponses = simpleEntry(
      key: key, frame: Self.topLevelFrame,
      headers: Data(
        "\0HTTP/1.1 200 OK\0Date:Tue, 29 Sep 2026 02:00:00 GMT\0content-encoding:zstd\0HTTP/1.1 304 Not Modified\0"
          .utf8))
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(mixedResponses) == nil)
    let mixedOrganizations = entry(org: Self.org) + entry(org: Self.otherOrg)
    #expect(FileClaudeDesktopUsageCacheReader.parseEntry(mixedOrganizations) == nil)
  }

  @Test("A signed-out CLI cannot erase an exact reset from matching Desktop usage")
  func desktopOnlyRestoresPlan() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org).write(to: historyURL)
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry().write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: Self.now)

    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.source == .claudeDesktopCache)
    #expect(snapshot.weekly?.remainingPercent == 97)
    #expect(snapshot.weekly?.resetAt == ISO8601DateFormatter().date(from: "2026-10-05T19:59:59Z"))
    #expect(snapshot.errorCode == nil)
  }

  @Test("A different organization never lends its reset to Desktop history")
  func rejectsOtherOrganization() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.otherOrg).write(to: historyURL)
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry().write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: Self.now)
    #expect(snapshot.weekly?.remainingPercent == 97)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.errorCode == .authenticationRequired)
  }

  @Test("A newer Desktop balance inherits the exact reset from the same weekly window")
  func newerHistoryKeepsReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let now = Self.now.addingTimeInterval(20 * 60)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org, at: now).write(to: historyURL)
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry().write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now)
    #expect(snapshot.source == .claudeLocalMerged)
    #expect(snapshot.capturedAt == now)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(QuotaPlanner.evaluate(snapshot, now: now).vsTarget != nil)
  }

  @Test("A signed-out or unrelated CLI account does not block matching Desktop evidence")
  func unrelatedCLIIdentityDoesNotBlockDesktop() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    let cliURL = root.appendingPathComponent("claude.json")
    try history(org: Self.org).write(to: historyURL)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "other-account", "organizationUuid": Self.otherOrg]
    ]).write(to: cliURL)
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry().write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: cliURL,
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: Self.now)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
  }

  @Test("A stale Desktop cache cannot be assigned to a newly selected CLI organization")
  func rejectsOldDesktopAfterAccountSwitch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    let cliURL = root.appendingPathComponent("claude.json")
    try history(org: Self.org).write(to: historyURL)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-b", "organizationUuid": Self.otherOrg]
    ]).write(to: cliURL)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-b"
    ]).write(to: root.appendingPathComponent("config.json"))
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry().write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: cliURL,
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: Self.now)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.claudeAccountFingerprint == nil)
  }

  @Test("Current Desktop account selects its usage cache before older history")
  func selectsNewDesktopAccountAfterSwitch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    let cliURL = root.appendingPathComponent("claude.json")
    try history(org: Self.org).write(to: historyURL)
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-b", "organizationUuid": Self.otherOrg]
    ]).write(to: cliURL)
    let configURL = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-b"
    ]).write(to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30)], ofItemAtPath: configURL.path)
    let oldEntry = cacheDirectory.appendingPathComponent("old_0")
    let currentEntry = cacheDirectory.appendingPathComponent("current_0")
    try entry(org: Self.org).write(to: oldEntry)
    try entry(org: Self.otherOrg).write(to: currentEntry)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(30)], ofItemAtPath: oldEntry.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: currentEntry.path)

    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopCache,
      capturedAt: Self.now,
      weekly: QuotaWindow(
        remainingPercent: 75, durationSeconds: 7 * 24 * 60 * 60,
        resetAt: Self.now.addingTimeInterval(5 * 24 * 60 * 60)),
      fiveHour: nil, sourceState: .observationSucceeded,
      claudeOrganizationFingerprint: SHA256.hash(data: Data(Self.org.utf8))
        .map { String(format: "%02x", $0) }.joined(),
      claudeDesktopPrincipalFingerprint: SHA256.hash(data: Data("account-a".utf8))
        .map { String(format: "%02x", $0) }.joined())

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: cliURL,
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: previous, now: Self.now)
    #expect(snapshot.source == .claudeDesktopCache)
    #expect(snapshot.weekly?.resetAt != nil)
    #expect(snapshot.sourceState == .observationSucceeded)
    #expect(snapshot.weekly?.remainingPercent == 97)
    #expect(
      snapshot.claudeDesktopPrincipalFingerprint != previous.claudeDesktopPrincipalFingerprint)
  }

  @Test("Desktop-only account switch keeps old quota hidden until new local evidence")
  func desktopOnlySwitchWaitsForNewEvidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    let configURL = root.appendingPathComponent("config.json")
    let oldDate = Self.now.addingTimeInterval(-60 * 60)
    try history(org: Self.org, at: oldDate).write(to: historyURL)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-b"
    ]).write(to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30 * 60)],
      ofItemAtPath: configURL.path)
    let oldEntry = cacheDirectory.appendingPathComponent("old_0")
    try entry(httpDate: "Tue, 29 Sep 2026 01:00:00 GMT").write(to: oldEntry)
    try FileManager.default.setAttributes(
      [.modificationDate: oldDate], ofItemAtPath: oldEntry.path)
    let oldPrincipal = SHA256.hash(data: Data("account-a".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopCache,
      capturedAt: oldDate,
      weekly: QuotaWindow(
        remainingPercent: 75, durationSeconds: 7 * 24 * 60 * 60,
        resetAt: Self.now.addingTimeInterval(5 * 24 * 60 * 60)),
      sourceState: .observationSucceeded,
      claudeDesktopPrincipalFingerprint: oldPrincipal)
    let adapter = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe"))
    let first = adapter.refresh(previous: previous, now: Self.now)
    #expect(first.weekly == nil)
    #expect(first.claudeDesktopPrincipalFingerprint == oldPrincipal)
    let second = adapter.refresh(previous: first, now: Self.now)
    #expect(second.weekly == nil)

    try history(org: Self.otherOrg).write(to: historyURL)
    let newEntry = cacheDirectory.appendingPathComponent("new_0")
    try entry(org: Self.otherOrg).write(to: newEntry)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: newEntry.path)
    let recovered = adapter.refresh(previous: second, now: Self.now)
    #expect(recovered.weekly?.resetAt != nil)
    #expect(recovered.sourceState == .observationSucceeded)
    #expect(recovered.claudeDesktopPrincipalFingerprint != oldPrincipal)
    let restored = try NormalizedSnapshotCodec.decode(NormalizedSnapshotCodec.encode(recovered))
    #expect(
      restored.claudeDesktopPrincipalFingerprint == recovered.claudeDesktopPrincipalFingerprint)
  }

  @Test("A new balance cannot inherit an old reset after a same-organization account switch")
  func sameOrganizationSwitchRejectsOldReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    let configURL = root.appendingPathComponent("config.json")
    try history(org: Self.org).write(to: historyURL)
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-b"
    ]).write(to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30 * 60)],
      ofItemAtPath: configURL.path)
    let oldEntry = cacheDirectory.appendingPathComponent("old_0")
    try entry(httpDate: "Tue, 29 Sep 2026 01:00:00 GMT").write(to: oldEntry)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-60 * 60)],
      ofItemAtPath: oldEntry.path)
    let oldPrincipal = SHA256.hash(data: Data("account-a".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopCache,
      capturedAt: Self.now.addingTimeInterval(-60 * 60),
      weekly: QuotaWindow(
        remainingPercent: 75, durationSeconds: 7 * 24 * 60 * 60,
        resetAt: Self.now.addingTimeInterval(5 * 24 * 60 * 60)),
      sourceState: .observationSucceeded,
      claudeDesktopPrincipalFingerprint: oldPrincipal)
    let adapter = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe"))
    let blocked = adapter.refresh(previous: previous, now: Self.now)
    #expect(blocked.weekly == nil)

    let currentEntry = cacheDirectory.appendingPathComponent("current_0")
    try entry().write(to: currentEntry)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: currentEntry.path)
    let recovered = adapter.refresh(previous: blocked, now: Self.now)
    #expect(recovered.weekly?.resetAt != nil)
    #expect(recovered.sourceState == .observationSucceeded)
  }

  @Test("A matching CLI identity does not assign an older Desktop response to the new account")
  func matchingCLIStillRejectsOldDesktopResponse() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org).write(to: historyURL)
    let configURL = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "account-b"]).write(
      to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30 * 60)], ofItemAtPath: configURL.path)
    let cliURL = root.appendingPathComponent("claude.json")
    try JSONSerialization.data(withJSONObject: [
      "oauthAccount": ["accountUuid": "account-b", "organizationUuid": Self.org]
    ]).write(to: cliURL)
    let oldEntry = cacheDirectory.appendingPathComponent("old_0")
    try entry(httpDate: "Tue, 29 Sep 2026 01:00:00 GMT").write(to: oldEntry)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-60 * 60)], ofItemAtPath: oldEntry.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"), historyURL: historyURL,
      cacheURL: cliURL, ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: Self.now)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.sourceState == .attemptFailed)
  }

  @Test("A temporary Desktop config read failure preserves switch detection")
  func missingConfigDoesNotErasePrincipal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org).write(to: historyURL)
    let oldPrincipal = SHA256.hash(data: Data("account-a".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopHistory,
      capturedAt: Self.now,
      weekly: QuotaWindow(
        remainingPercent: 75, durationSeconds: 7 * 24 * 60 * 60,
        resetAt: Self.now.addingTimeInterval(5 * 24 * 60 * 60)),
      sourceState: .observationSucceeded,
      claudeDesktopPrincipalFingerprint: oldPrincipal)
    let adapter = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe"))
    let unreadable = adapter.refresh(previous: previous, now: Self.now)
    #expect(unreadable.weekly == nil)
    #expect(unreadable.claudeDesktopPrincipalFingerprint == oldPrincipal)

    let configURL = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-b"
    ]).write(to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30 * 60)],
      ofItemAtPath: configURL.path)
    let afterSwitch = adapter.refresh(previous: unreadable, now: Self.now)
    #expect(afterSwitch.weekly == nil)
    #expect(afterSwitch.claudeDesktopPrincipalFingerprint == oldPrincipal)
  }

  @Test("Legacy exact snapshots cannot bind an old cache to a new Desktop account")
  func legacySnapshotWaitsForCurrentCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org).write(to: historyURL)
    let configURL = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: [
      "lastKnownAccountUuid": "account-b"
    ]).write(to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30 * 60)],
      ofItemAtPath: configURL.path)
    let oldEntry = cacheDirectory.appendingPathComponent("old_0")
    try entry(httpDate: "Tue, 29 Sep 2026 01:00:00 GMT").write(to: oldEntry)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-60 * 60)],
      ofItemAtPath: oldEntry.path)
    let legacy = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopCache,
      capturedAt: Self.now,
      weekly: QuotaWindow(
        remainingPercent: 75, durationSeconds: 7 * 24 * 60 * 60,
        resetAt: Self.now.addingTimeInterval(5 * 24 * 60 * 60)),
      sourceState: .observationSucceeded)
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: legacy, now: Self.now)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.sourceState == .attemptFailed)
  }

  @Test("A unique Desktop session directory cannot prove ownership of an older cache")
  func uniqueSessionOrganizationDoesNotBindExistingCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = "123e4567-e89b-12d3-a456-426614174010"
    let sessions = root.appendingPathComponent("claude-code-sessions/\(account)/\(Self.org)")
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    let observedAt = Self.now.addingTimeInterval(-60 * 60)
    try history(org: Self.org, at: observedAt).write(to: historyURL)
    let configURL = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account]).write(
      to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30 * 60)], ofItemAtPath: configURL.path)
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry(httpDate: "Tue, 29 Sep 2026 01:00:00 GMT").write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: observedAt], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"), historyURL: historyURL,
      cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: Self.now)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.sourceState == .attemptFailed)
  }

  @Test("Multiple Desktop session accounts cannot authorize an old cache")
  func ambiguousSessionDirectoriesDoNotBindCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = "123e4567-e89b-12d3-a456-426614174010"
    let otherAccount = "123e4567-e89b-12d3-a456-426614174011"
    let sessions = root.appendingPathComponent("claude-code-sessions")
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(
      at: sessions.appendingPathComponent("\(account)/\(Self.org)"),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: sessions.appendingPathComponent("\(otherAccount)/\(Self.otherOrg)"),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org, at: Self.now.addingTimeInterval(-60 * 60)).write(to: historyURL)
    let configURL = root.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account]).write(
      to: configURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-30 * 60)], ofItemAtPath: configURL.path)
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry(httpDate: "Tue, 29 Sep 2026 01:00:00 GMT").write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(-60 * 60)], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"), historyURL: historyURL,
      cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: Self.now)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.sourceState == .attemptFailed)
  }

  @Test("A recent Desktop organization switch drops the previous account reset")
  func recentOrganizationSwitchDropsPrevious() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.otherOrg, at: Self.now.addingTimeInterval(-120)).write(to: historyURL)
    let oldOrganization = SHA256.hash(data: Data(Self.org.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let previous = ProviderSnapshot(
      provider: .claude, source: .claudeCLI,
      capturedAt: Self.now.addingTimeInterval(-60),
      weekly: QuotaWindow(
        remainingPercent: 75, durationSeconds: 7 * 24 * 60 * 60,
        resetAt: Self.now.addingTimeInterval(5 * 24 * 60 * 60)),
      fiveHour: nil, sourceState: .observationSucceeded,
      claudeOrganizationFingerprint: oldOrganization)
    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: previous, now: Self.now)
    #expect(snapshot.source == .claudeDesktopHistory)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.weekly?.remainingPercent == 97)
  }

  @Test("An expired cached weekly reset cannot cross the next rollover")
  func expiredResetIsRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheDirectory = root.appendingPathComponent("Cache/Cache_Data")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-10-06T02:00:00Z")!
    let historyURL = root.appendingPathComponent("plan-usage-history.json")
    try history(org: Self.org, at: now).write(to: historyURL)
    let entryURL = cacheDirectory.appendingPathComponent("usage_0")
    try entry().write(to: entryURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: entryURL.path)

    let snapshot = ClaudeAutomaticAdapter(
      cliExecutable: URL(fileURLWithPath: "/mock/claude"),
      historyURL: historyURL, cacheURL: root.appendingPathComponent("missing-claude.json"),
      ptyProbeEnabled: true, ptyProbe: SignedOutPTY(),
      probeDirectory: root.appendingPathComponent("probe")
    ).refresh(previous: nil, now: now)
    #expect(snapshot.weekly?.resetAt == nil)
    #expect(snapshot.errorCode == .authenticationRequired)
  }

  @Test("A symlinked cache directory fails closed")
  func cacheSymlinkIsUnsafe() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    let link = root.appendingPathComponent("Cache_Data")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: ClaudeAutomaticAdapterError.unsafePath) {
      try FileClaudeDesktopUsageCacheReader(directory: link).latest(
        now: Self.now, organizationFingerprint: nil)
    }
  }

  @Test("More than 256 newer unrelated entries cannot hide usage or trigger full-body reads")
  func scansPastUnrelatedEntries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let usage = root.appendingPathComponent("usage_0")
    try entry().write(to: usage)
    try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: usage.path)
    for index in 0..<320 {
      let unrelated = root.appendingPathComponent("other-\(index)_0")
      try Data("private unrelated response".utf8).write(to: unrelated)
      try FileManager.default.setAttributes(
        [.modificationDate: Self.now.addingTimeInterval(30)],
        ofItemAtPath: unrelated.path)
    }
    let reader = CountingCacheReader()
    let observation = try FileClaudeDesktopUsageCacheReader(
      directory: root, reader: reader
    ).latest(now: Self.now, organizationFingerprint: nil)
    #expect(observation?.weeklyResetAt != nil)
    #expect(reader.readCount == 1)
  }

  @Test("A newer cache response from another organization cannot hide the current one")
  func selectsCurrentOrganization() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let current = root.appendingPathComponent("current_0")
    let unrelated = root.appendingPathComponent("unrelated_0")
    try entry(org: Self.org).write(to: current)
    try entry(org: Self.otherOrg).write(to: unrelated)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now], ofItemAtPath: current.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.now.addingTimeInterval(30)], ofItemAtPath: unrelated.path)
    let fingerprint = SHA256.hash(data: Data(Self.org.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let reader = CountingCacheReader()
    let observation = try FileClaudeDesktopUsageCacheReader(directory: root, reader: reader)
      .latest(now: Self.now, organizationFingerprint: fingerprint)
    #expect(observation?.organizationUUID == Self.org)
    #expect(observation?.weeklyResetAt != nil)
    #expect(reader.readCount == 1)
  }

  private func history(org: String, at: Date = Self.now) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "samples": [
        [
          "t": Int64(at.timeIntervalSince1970 * 1_000),
          "org": org,
          "u": ["sd": 3.0, "fh": 33.0],
        ]
      ]
    ])
  }

}
