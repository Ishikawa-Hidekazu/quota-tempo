import Darwin
import Foundation
import Testing

@testable import QuotaTempoCore

@Suite("Claude browser bridge synthetic QA")
struct ClaudeBrowserBridgeTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let profileID = "10000000-0000-4000-8000-000000000001"
  private let connectionID = "30000000-0000-4000-8000-000000000003"

  @Test("Native framing uses a little-endian byte count and preserves UTF-8")
  func framingRoundTrip() throws {
    let payload = Data("{\"label\":\"\u{65e5}\u{672c}\u{8a9e}\u{1f680}\"}".utf8)
    let framed = try NativeMessageFraming.frame(payload)
    #expect(Array(framed.prefix(4)) == [UInt8(payload.count), 0, 0, 0])
    #expect(try self.readFrame(framed) == payload)

    let maximum = Data(repeating: 0x61, count: NativeMessageFraming.maximumBytes)
    let maximumFrame = try NativeMessageFraming.frame(maximum)
    #expect(Array(maximumFrame.prefix(4)) == [0, 64, 0, 0])
    #expect(try self.readFrame(maximumFrame) == maximum)
  }

  @Test("Empty and oversized native messages are rejected before reading a body")
  func framingBounds() throws {
    for payload in [Data(), Data(repeating: 0, count: NativeMessageFraming.maximumBytes + 1)] {
      #expect(throws: ClaudeBrowserBridgeError.inputTooLarge) {
        try NativeMessageFraming.frame(payload)
      }
    }
    for header in [Data([0, 0, 0, 0]), Data([1, 64, 0, 0]), Data([255, 255, 255, 255])] {
      #expect(throws: ClaudeBrowserBridgeError.inputTooLarge) { try self.readFrame(header) }
    }
  }

  @Test("Truncated native headers and bodies fail closed")
  func truncatedFrames() throws {
    let complete = try NativeMessageFraming.frame(Data("valid".utf8))
    for length in 0..<complete.count {
      #expect(throws: ClaudeBrowserBridgeError.truncatedMessage) {
        try self.readFrame(Data(complete.prefix(length)))
      }
    }
  }

  @Test("Fragmented pipe reads preserve multibyte UTF-8 and stop at one frame")
  func fragmentedFrames() throws {
    let first = Data("{\"text\":\"\u{65e5}\u{1f680}\"}".utf8)
    let second = Data("{\"next\":true}".utf8)
    let frames = try NativeMessageFraming.frame(first) + NativeMessageFraming.frame(second)
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    let writer = pipe.fileHandleForWriting
    DispatchQueue.global().async {
      defer { try? writer.close() }
      for byte in frames {
        do { try writer.write(contentsOf: Data([byte])) } catch { return }
        Thread.sleep(forTimeInterval: 0.001)
      }
    }
    #expect(try NativeMessageFraming.read(from: pipe.fileHandleForReading) == first)
    #expect(try NativeMessageFraming.read(from: pipe.fileHandleForReading) == second)
    #expect(throws: ClaudeBrowserBridgeError.truncatedMessage) {
      try NativeMessageFraming.read(from: pipe.fileHandleForReading)
    }
  }

  @Test("Envelope preserves exact observation/reset timestamps and canonical durations")
  func exactWindows() throws {
    var object = self.envelope()
    let observed = self.now.addingTimeInterval(-0.125)
    object["observedAt"] = self.iso(observed)
    object["weekly"] = [
      "remainingPercent": 0.0, "resetAt": "2027-01-16T18:00:00.250+09:00",
    ]
    object["fiveHour"] = [
      "remainingPercent": 100.0, "resetAt": self.iso(self.now.addingTimeInterval(3_600)),
    ]
    let record = try self.apply(object)
    #expect(record.snapshot.provider == .claude)
    #expect(record.snapshot.source == .claudeBrowser)
    #expect(record.snapshot.capturedAt == observed)
    #expect(record.snapshot.lastAttemptAt == observed)
    #expect(record.snapshot.sourceState == .observationSucceeded)
    #expect(record.snapshot.errorCode == nil)
    #expect(record.snapshot.weekly?.remainingPercent == 0)
    #expect(record.snapshot.weekly?.durationSeconds == 604_800)
    #expect(record.snapshot.weekly?.resetAt == Date(timeIntervalSince1970: 1_800_090_000.250))
    #expect(record.snapshot.weekly?.isResetEstimated == false)
    #expect(record.snapshot.fiveHour?.remainingPercent == 100)
    #expect(record.snapshot.fiveHour?.durationSeconds == 18_000)

    object.removeValue(forKey: "fiveHour")
    #expect(try self.apply(object).snapshot.fiveHour == nil)
  }

  @Test("Observation age and future clock skew enforce inclusive bounds")
  func observationTimeBounds() throws {
    for offset in [-300.0, 0.0, 30.0] {
      var object = self.envelope()
      object["observedAt"] = self.iso(self.now.addingTimeInterval(offset))
      #expect(
        try self.apply(object).lastMessageAt == min(self.now, self.now.addingTimeInterval(offset)))
    }
    for timestamp in [
      self.iso(self.now.addingTimeInterval(-301)), self.iso(self.now.addingTimeInterval(31)),
      "1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "not-a-date", "2027-01-15",
    ] {
      var object = self.envelope()
      object["observedAt"] = timestamp
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(object) }
    }
  }

  @Test("Exact ISO timestamps reject trailing non-date text")
  func timestampsMustConsumeWholeValue() {
    var observed = self.envelope()
    observed["observedAt"] = self.iso(self.now) + "not-a-date"
    #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(observed) }
    for key in ["weekly", "fiveHour"] {
      var object = self.envelope()
      object[key] = [
        "remainingPercent": 50,
        "resetAt": self.iso(self.now.addingTimeInterval(60)) + "not-a-date",
      ]
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(object) }
    }
  }

  @Test("Schema, profile, status, required weekly window and fingerprints are validated")
  func envelopeIdentityValidation() throws {
    let invalid: [(String, [Any])] = [
      ("schemaVersion", [0, 2, "1", NSNull()]),
      ("profileID", ["", "not-a-uuid", 42, NSNull()]),
      ("connectionID", ["", "not-a-uuid", 42, NSNull()]),
      ("sequence", [-1, 9_007_199_254_740_992, 1.5, "1", NSNull()]),
      ("status", ["unknown", NSNull()]),
      ("weekly", [NSNull()]),
      ("accountFingerprint", ["", String(repeating: "a", count: 63), NSNull()]),
      ("organizationFingerprint", [String(repeating: "A", count: 64), NSNull()]),
      ("principalFingerprint", [String(repeating: "g", count: 64), NSNull()]),
    ]
    for (key, values) in invalid {
      for value in values {
        var object = self.envelope()
        object[key] = value
        #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(object) }
      }
      var missing = self.envelope()
      missing.removeValue(forKey: key)
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(missing) }
    }
  }

  @Test("Percent and exact reset bounds are checked for both quota windows")
  func windowValidation() throws {
    for (key, maximum) in [("weekly", 691_200.0), ("fiveHour", 21_600.0)] {
      for percent in [-0.01, 100.01] {
        var object = self.envelope()
        object[key] = [
          "remainingPercent": percent, "resetAt": self.iso(self.now.addingTimeInterval(60)),
        ]
        #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(object) }
      }
      for reset: Any in [
        NSNull(), "soon", "2027-01-16", self.iso(self.now),
        self.iso(self.now.addingTimeInterval(-1)),
        self.iso(self.now.addingTimeInterval(maximum + 1)),
      ] {
        var object = self.envelope()
        object[key] = ["remainingPercent": 50, "resetAt": reset]
        #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(object) }
      }
      for percent: Any in ["NaN", "Infinity", NSNull()] {
        var object = self.envelope()
        object[key] = [
          "remainingPercent": percent, "resetAt": self.iso(self.now.addingTimeInterval(60)),
        ]
        #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(object) }
      }
      var boundary = self.envelope()
      boundary[key] = [
        "remainingPercent": 50, "resetAt": self.iso(self.now.addingTimeInterval(maximum)),
      ]
      let snapshot = try self.apply(boundary).snapshot
      #expect(
        (key == "weekly" ? snapshot.weekly : snapshot.fiveHour)?.resetAt
          == self.now.addingTimeInterval(maximum))
    }
  }

  @Test("Malformed JSON, invalid UTF-8 and oversized envelopes cannot be decoded")
  func invalidEncodedMessages() throws {
    for data in [Data(), Data("{broken".utf8), Data([0x7b, 0x22, 0xff, 0x22, 0x7d])] {
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) {
        try ClaudeBrowserMessage.decode(data)
      }
    }
    #expect(throws: ClaudeBrowserBridgeError.inputTooLarge) {
      try ClaudeBrowserMessage.decode(
        Data(repeating: 0x20, count: NativeMessageFraming.maximumBytes + 1))
    }
    let string = String(decoding: try self.data(self.envelope()), as: UTF8.self)
    let nonfinite = Data(string.replacingOccurrences(of: "73.5", with: "1e999").utf8)
    #expect(throws: ClaudeBrowserBridgeError.invalidMessage) {
      try ClaudeBrowserRecord.applying(
        ClaudeBrowserMessage.decode(nonfinite), to: nil, now: self.now)
    }
  }

  @Test("Every non-success status rejects embedded quota data")
  func errorsCannotSmuggleWindows() {
    for status in [
      "signedOut", "accountChanged", "unavailable", "rateLimited", "organizationSelectionRequired",
      "connected",
      "disconnected",
    ] {
      for key in ["weekly", "fiveHour"] {
        var object = self.envelope(status: status)
        object[key] = self.envelope()[key]
        #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try self.apply(object) }
      }
    }
  }

  @Test("Owner mismatches throw and atomically revoke old quotas without accepting a new binding")
  func accountSwitchIsolation() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for key in ["accountFingerprint", "organizationFingerprint", "principalFingerprint"] {
      let store = ClaudeBrowserStore(directory: root.appendingPathComponent(key))
      try self.connect(store)
      try store.ingest(self.data(self.envelope(offset: -10)), now: self.now)
      let original = try #require(try store.load())
      var changed = self.envelope()
      changed[key] = String(repeating: "d", count: 64)
      #expect(throws: ClaudeBrowserBridgeError.accountMismatch) {
        try self.apply(changed, previous: original)
      }
      #expect(throws: ClaudeBrowserBridgeError.accountMismatch) {
        try store.ingest(self.data(changed), now: self.now)
      }
      let revoked = try #require(try store.load())
      #expect(revoked.profileID == original.profileID)
      #expect(revoked.accountFingerprint == original.accountFingerprint)
      #expect(revoked.organizationFingerprint == original.organizationFingerprint)
      #expect(revoked.principalFingerprint == original.principalFingerprint)
      #expect(revoked.enabled)
      #expect(revoked.lastMessageAt == self.now)
      #expect(revoked.snapshot.capturedAt == nil)
      #expect(revoked.snapshot.weekly == nil)
      #expect(revoked.snapshot.fiveHour == nil)
      #expect(revoked.snapshot.sourceState == .attemptFailed)
      #expect(revoked.snapshot.errorCode == .sourceUnavailable)
      #expect(store.selectedSnapshot(now: self.now)?.weekly == nil)
      let failure = try self.apply(
        self.envelope(status: "rateLimited", offset: 1), previous: revoked)
      #expect(failure.snapshot.weekly == nil)
      #expect(failure.snapshot.capturedAt == nil)
    }
  }

  @Test("Equivalent profile and connection UUID case is canonicalized")
  func canonicalProfileIdentity() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    let uuid = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    let connection = "fedcbafe-dcba-4cba-8cba-fedcbafedcba"
    try self.connect(store, profileID: uuid.uppercased(), connectionID: connection.uppercased())
    var first = self.envelope(offset: -10, connectionID: connection)
    first["profileID"] = uuid.uppercased()
    try store.ingest(self.data(first), now: self.now)
    #expect(try store.load()?.profileID == uuid)
    #expect(try store.load()?.connectionID == connection)
    var next = self.envelope(connectionID: connection.uppercased())
    next["profileID"] = uuid
    try store.ingest(self.data(next), now: self.now)
    #expect(try store.load()?.lastMessageAt == self.now)
    #expect(try store.load()?.profileID == uuid)
    #expect(try store.load()?.connectionID == connection)
  }

  @Test("A sequence-zero handshake is required and cannot replace an active connection")
  func connectionHandshakeRequired() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    for status in ["ok", "unavailable", "signedOut", "disconnected"] {
      let message = try self.data(self.envelope(status: status, sequence: 1))
      #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
        try ClaudeBrowserRecord.applying(
          ClaudeBrowserMessage.decode(message), to: nil, now: self.now)
      }
      #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
        try store.ingest(message, now: self.now)
      }
      #expect(try store.load() == nil)
    }
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try store.ingest(self.data(self.envelope(status: "connected", sequence: 1)), now: self.now)
    }
    try self.connect(store)
    let connected = try #require(try store.load())
    #expect(connected.enabled)
    #expect(connected.lastSequence == 0)
    #expect(connected.connectionID == self.connectionID)
    #expect(connected.snapshot.weekly == nil)
    #expect(connected.snapshot.fiveHour == nil)
    #expect(connected.accountFingerprint == nil)
    try self.connect(store)
    #expect(try store.load()?.snapshot == connected.snapshot)
    #expect(try store.load()?.lastMessageAt == connected.lastMessageAt)
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try self.connect(store, connectionID: "40000000-0000-4000-8000-000000000004")
    }
    #expect(try store.load()?.snapshot == connected.snapshot)
    try store.ingest(self.data(self.envelope(sequence: 1)), now: self.now)
    #expect(try store.load()?.snapshot.weekly?.remainingPercent == 73.5)
  }

  @Test("Lost control ACKs retry idempotently without rewriting bytes or advancing timestamps")
  func lostControlAcknowledgementIsIdempotent() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for status in [
      "connected", "signedOut", "accountChanged", "organizationSelectionRequired", "disconnected",
      "unavailable", "rateLimited",
    ] {
      let store = ClaudeBrowserStore(directory: root.appendingPathComponent(status))
      try self.connect(store)
      let sequence = status == "connected" ? 0 : 2
      if status != "connected" {
        if status != "unavailable" && status != "rateLimited" {
          try store.ingest(self.data(self.envelope(offset: -120, sequence: 1)), now: self.now)
        }
        try store.ingest(
          self.data(self.envelope(status: status, offset: -60, sequence: sequence)), now: self.now)
      }
      let original = try #require(try store.load())
      let bytes = try Data(contentsOf: store.url)
      let sentinel = self.now.addingTimeInterval(-1_800)
      try FileManager.default.setAttributes(
        [.modificationDate: sentinel], ofItemAtPath: store.url.path)
      let replay = self.envelope(status: status, sequence: sequence)
      try store.ingest(self.data(replay), now: self.now)
      let duplicate = try #require(try store.load())
      #expect(duplicate.lastStatus.rawValue == status)
      #expect(duplicate.lastSequence == original.lastSequence)
      #expect(duplicate.lastMessageAt == original.lastMessageAt)
      #expect(duplicate.snapshot == original.snapshot)
      #expect(duplicate.enabled == original.enabled)
      #expect(try Data(contentsOf: store.url) == bytes)
      let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
      #expect(attributes[.modificationDate] as? Date == sentinel)
    }
  }

  @Test("An explicit renewed handshake can recover a lost ACK without rewriting host history")
  func renewedHandshakeAfterLostACK() throws {
    let original = try ClaudeBrowserMessage.decode(self.data(self.envelope(status: "connected")))
    let accepted = try ClaudeBrowserRecord.applying(original, to: nil, now: self.now)
    let later = self.now.addingTimeInterval(301)
    #expect(throws: ClaudeBrowserBridgeError.invalidMessage) {
      try ClaudeBrowserRecord.applying(original, to: accepted, now: later)
    }
    var renewedObject = self.envelope(status: "connected")
    renewedObject["observedAt"] = self.iso(later)
    let renewed = try ClaudeBrowserMessage.decode(self.data(renewedObject))
    let replayed = try ClaudeBrowserRecord.applying(renewed, to: accepted, now: later)
    #expect(replayed == accepted)
    #expect(replayed.lastMessageAt == self.now)
    let firstAccepted = try ClaudeBrowserRecord.applying(renewed, to: nil, now: later)
    #expect(firstAccepted.lastMessageAt == later)
    #expect(firstAccepted.snapshot.weekly == nil)
    #expect(firstAccepted.snapshot.capturedAt == nil)
  }

  @Test("ACK idempotency does not accept quota replay or changed control identity/status")
  func acknowledgementReplayBoundaries() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    let success = self.envelope(sequence: 1)
    try store.ingest(self.data(success), now: self.now)
    #expect(throws: ClaudeBrowserBridgeError.staleMessage) {
      try store.ingest(self.data(success), now: self.now)
    }
    let signedOut = self.envelope(status: "signedOut", sequence: 2)
    try store.ingest(self.data(signedOut), now: self.now)
    let original = try Data(contentsOf: store.url)
    for key in ["profileID", "connectionID", "status", "weekly"] {
      var wrong = signedOut
      switch key {
      case "profileID", "connectionID": wrong[key] = "40000000-0000-4000-8000-000000000004"
      case "status": wrong[key] = "disconnected"
      default: wrong[key] = self.envelope()["weekly"]
      }
      #expect(throws: (any Error).self) { try store.ingest(self.data(wrong), now: self.now) }
      #expect(try Data(contentsOf: store.url) == original)
    }
  }

  @Test("Delayed pending invalidations remain valid but stale success and handshakes do not")
  func pendingInvalidationAge() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(sequence: 1)), now: self.now)
    #expect(throws: ClaudeBrowserBridgeError.invalidMessage) {
      try store.ingest(self.data(self.envelope(offset: -301, sequence: 2)), now: self.now)
    }
    let pendingSignout = self.envelope(status: "signedOut", offset: -3_600, sequence: 2)
    try store.ingest(self.data(pendingSignout), now: self.now)
    #expect(try store.load()?.snapshot.weekly == nil)
    #expect(try store.load()?.lastStatus == .signedOut)
    try store.ingest(self.data(pendingSignout), now: self.now.addingTimeInterval(86_400))
    #expect(try store.load()?.snapshot.lastAttemptAt == self.now.addingTimeInterval(-3_600))
    let pendingDisconnect = self.envelope(status: "disconnected", offset: -3_600, sequence: 3)
    try store.ingest(self.data(pendingDisconnect), now: self.now)
    try store.ingest(self.data(pendingDisconnect), now: self.now.addingTimeInterval(86_400))
    #expect(try store.load()?.enabled == false)
    #expect(store.selectedSnapshot(now: self.now) == nil)
    let newConnection = "40000000-0000-4000-8000-000000000004"
    #expect(throws: ClaudeBrowserBridgeError.invalidMessage) {
      try store.ingest(
        self.data(self.envelope(status: "connected", offset: -301, connectionID: newConnection)),
        now: self.now)
    }
    for timestamp in ["not-a-date", self.iso(self.now.addingTimeInterval(31))] {
      var malformed = pendingDisconnect
      malformed["observedAt"] = timestamp
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) {
        try store.ingest(self.data(malformed), now: self.now)
      }
    }
  }

  @Test("Delayed observations and failures after disconnect cannot re-enable the connection")
  func disconnectedRejectsDelayedMessages() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(sequence: 1)), now: self.now)
    try store.ingest(self.data(self.envelope(status: "disconnected", sequence: 2)), now: self.now)
    let disconnected = try Data(contentsOf: store.url)
    for status in ["ok", "unavailable", "rateLimited", "signedOut"] {
      #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
        try store.ingest(self.data(self.envelope(status: status, sequence: 3)), now: self.now)
      }
      #expect(try Data(contentsOf: store.url) == disconnected)
      #expect(try store.load()?.enabled == false)
      #expect(store.selectedSnapshot(now: self.now) == nil)
    }
    try store.ingest(self.data(self.envelope(status: "disconnected", sequence: 3)), now: self.now)
    #expect(try Data(contentsOf: store.url) == disconnected)
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) { try self.connect(store) }
    #expect(try Data(contentsOf: store.url) == disconnected)
  }

  @Test("Profile transfer requires disconnect and a new connection handshake")
  func profileTransferRequiresNewConnection() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    let nextProfile = "20000000-0000-4000-8000-000000000002"
    let nextConnection = "40000000-0000-4000-8000-000000000004"
    try self.connect(store)
    try store.ingest(self.data(self.envelope(sequence: 1)), now: self.now)
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try self.connect(store, profileID: nextProfile, connectionID: nextConnection)
    }
    try store.ingest(self.data(self.envelope(status: "disconnected", sequence: 2)), now: self.now)
    var next = self.envelope(connectionID: nextConnection, sequence: 1)
    next["profileID"] = nextProfile
    next["accountFingerprint"] = String(repeating: "d", count: 64)
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try store.ingest(self.data(next), now: self.now)
    }
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try self.connect(store, profileID: nextProfile)
    }
    try self.connect(store, profileID: nextProfile, connectionID: nextConnection)
    #expect(try store.load()?.accountFingerprint == nil)
    #expect(try store.load()?.snapshot.weekly == nil)
    try store.ingest(self.data(next), now: self.now)
    let rebound = try #require(try store.load())
    #expect(rebound.profileID == nextProfile)
    #expect(rebound.connectionID == nextConnection)
    #expect(rebound.accountFingerprint == String(repeating: "d", count: 64))
    let bytes = try Data(contentsOf: store.url)
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try store.ingest(
        self.data(self.envelope(status: "disconnected", sequence: 100)), now: self.now)
    }
    #expect(try Data(contentsOf: store.url) == bytes)
  }

  @Test("Retired connection A cannot reconnect after connection B has also disconnected")
  func olderRetiredConnectionCannotReplay() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    let connectionA = "aaaaaaaa-0000-4000-8000-000000000001"
    let connectionB = "bbbbbbbb-0000-4000-8000-000000000002"
    for connection in [connectionA, connectionB] {
      try self.connect(store, connectionID: connection.uppercased())
      try store.ingest(
        self.data(self.envelope(connectionID: connection, sequence: 1)), now: self.now)
      try store.ingest(
        self.data(
          self.envelope(status: "disconnected", connectionID: connection.uppercased(), sequence: 2)),
        now: self.now)
    }
    let retired = try #require(try store.load())
    #expect(retired.retiredConnectionIDs == [connectionA, connectionB])
    #expect(retired.connectionID == connectionB)
    #expect(!retired.enabled)
    let original = try Data(contentsOf: store.url)
    for connection in [connectionA, connectionA.uppercased()] {
      for status in ["connected", "ok"] {
        let replay = self.envelope(
          status: status, connectionID: connection, sequence: status == "connected" ? 0 : 100)
        #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
          try store.ingest(self.data(replay), now: self.now)
        }
        #expect(try Data(contentsOf: store.url) == original)
        #expect(store.selectedSnapshot(now: self.now) == nil)
      }
    }
  }

  @Test("128 retired connections block a fresh handshake without deleting tombstones")
  func retiredConnectionLimit() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    var previous: ClaudeBrowserRecord?
    for index in 1...128 {
      let connection = String(format: "a0000000-0000-4000-8000-%012d", index)
      let handshake = self.envelope(status: "connected", connectionID: connection, sequence: 0)
      let connected = try ClaudeBrowserRecord.applying(
        ClaudeBrowserMessage.decode(self.data(handshake)), to: previous, now: self.now)
      #expect(connected.enabled)
      #expect(connected.retiredConnectionIDs.count == index - 1)
      previous = try ClaudeBrowserRecord.applying(
        ClaudeBrowserMessage.decode(
          self.data(
            self.envelope(
              status: "disconnected", connectionID: connection, sequence: 1))),
        to: connected, now: self.now)
    }
    let exhausted = try #require(previous)
    try JSONEncoder().encode(exhausted).write(to: store.url)
    #expect(try store.load()?.retiredConnectionIDs.count == 128)
    #expect(try store.load()?.enabled == false)
    let original = try Data(contentsOf: store.url)
    #expect(throws: ClaudeBrowserBridgeError.connectionLimitReached) {
      try self.connect(store, connectionID: "a0000000-0000-4000-8000-000000000129")
    }
    #expect(try Data(contentsOf: store.url) == original)
    #expect(store.selectedSnapshot(now: self.now) == nil)
    try store.ingest(
      self.data(
        self.envelope(status: "disconnected", connectionID: exhausted.connectionID, sequence: 1)),
      now: self.now)
    #expect(try Data(contentsOf: store.url) == original)
    #expect(try store.load()?.retiredConnectionIDs.count == 128)
  }

  @Test("Sequence, not the observation clock, orders messages and protects replay")
  func sequenceOrdersMessages() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(sequence: 1)), now: self.now)
    try store.ingest(self.data(self.envelope(offset: -1, sequence: 2)), now: self.now)
    #expect(try store.load()?.lastSequence == 2)
    #expect(try store.load()?.snapshot.capturedAt == self.now.addingTimeInterval(-1))
    let current = try Data(contentsOf: store.url)
    for sequence in [0, 1, 2] {
      #expect(throws: ClaudeBrowserBridgeError.staleMessage) {
        try store.ingest(self.data(self.envelope(offset: 10, sequence: sequence)), now: self.now)
      }
      #expect(try Data(contentsOf: store.url) == current)
    }
    try store.ingest(self.data(self.envelope(sequence: 9_007_199_254_740_991)), now: self.now)
    #expect(try store.load()?.lastSequence == 9_007_199_254_740_991)
  }

  @Test("Accepted future skew is clamped and cannot block a higher-sequence signout")
  func futureClockCannotBlockSignout() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(offset: 30, sequence: 1)), now: self.now)
    #expect(try store.load()?.snapshot.capturedAt == self.now)
    #expect(try store.load()?.snapshot.lastAttemptAt == self.now)
    try store.ingest(
      self.data(self.envelope(status: "signedOut", offset: -1, sequence: 2)), now: self.now)
    let signedOut = try #require(try store.load())
    #expect(signedOut.lastSequence == 2)
    #expect(signedOut.snapshot.errorCode == .authenticationRequired)
    #expect(signedOut.snapshot.capturedAt == nil)
    #expect(signedOut.snapshot.weekly == nil)
    #expect(signedOut.snapshot.fiveHour == nil)
  }

  @Test(
    "A higher-sequence transient error with an earlier clock retains a loadable true observation")
  func regressedTransientClockKeepsRecordLoadable() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(offset: 30, sequence: 1)), now: self.now)
    try store.ingest(
      self.data(self.envelope(status: "unavailable", offset: -1, sequence: 2)), now: self.now)
    let retained = try #require(try store.load())
    #expect(retained.lastSequence == 2)
    #expect(retained.snapshot.capturedAt == self.now)
    #expect(retained.snapshot.weekly?.remainingPercent == 73.5)
    #expect(retained.snapshot.lastAttemptAt == self.now.addingTimeInterval(-1))
    #expect(retained.snapshot.sourceState == .attemptFailed)
  }

  @Test("Another profile cannot submit observations or clear the selected profile")
  func profileSwitchIsolation() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(offset: -10)), now: self.now)
    let original = try Data(contentsOf: store.url)
    let previous = try self.apply(self.envelope(offset: -10))
    for status in ["ok", "signedOut", "accountChanged", "unavailable", "disconnected"] {
      var object = self.envelope(status: status)
      object["profileID"] = "20000000-0000-4000-8000-000000000002"
      #expect(throws: ClaudeBrowserBridgeError.profileMismatch) {
        try self.apply(object, previous: previous)
      }
      #expect(throws: ClaudeBrowserBridgeError.profileMismatch) {
        try store.ingest(self.data(object), now: self.now)
      }
      #expect(try Data(contentsOf: store.url) == original)
    }
  }

  @Test("Malformed or replayed owner changes cannot revoke the last valid quota")
  func invalidOwnerChangesDoNotRevoke() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(offset: -10)), now: self.now)
    let original = try Data(contentsOf: store.url)
    var invalidWindow = self.envelope()
    invalidWindow["accountFingerprint"] = String(repeating: "d", count: 64)
    invalidWindow["weekly"] = [
      "remainingPercent": 101, "resetAt": self.iso(self.now.addingTimeInterval(60)),
    ]
    #expect(throws: ClaudeBrowserBridgeError.invalidMessage) {
      try store.ingest(self.data(invalidWindow), now: self.now)
    }
    #expect(try Data(contentsOf: store.url) == original)
    var replayed = self.envelope(offset: -10)
    replayed["accountFingerprint"] = String(repeating: "d", count: 64)
    #expect(throws: ClaudeBrowserBridgeError.staleMessage) {
      try store.ingest(self.data(replayed), now: self.now)
    }
    #expect(try Data(contentsOf: store.url) == original)
  }

  @Test("Replay and out-of-order errors are rejected without changing persisted data")
  func replayProtection() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(offset: -10)), now: self.now)
    let original = try Data(contentsOf: store.url)
    for offset in [-10.0, -11.0] {
      for status in ["ok", "signedOut", "disconnected"] {
        #expect(throws: ClaudeBrowserBridgeError.staleMessage) {
          try store.ingest(self.data(self.envelope(status: status, offset: offset)), now: self.now)
        }
        #expect(try Data(contentsOf: store.url) == original)
      }
    }
    try store.ingest(self.data(self.envelope()), now: self.now)
    #expect(try store.load()?.lastMessageAt == self.now)
  }

  @Test("Transient failures retain the actual successful timestamp, not the attempt time")
  func transientFailuresRetainObservation() throws {
    let observed = try self.apply(self.envelope(offset: -120))
    var previous = observed
    for (status, offset) in [("unavailable", -60.0), ("rateLimited", 0.0)] {
      let failed = try self.apply(self.envelope(status: status, offset: offset), previous: previous)
      #expect(failed.lastMessageAt == self.now.addingTimeInterval(offset))
      #expect(failed.snapshot.lastAttemptAt == failed.lastMessageAt)
      #expect(failed.snapshot.capturedAt == observed.snapshot.capturedAt)
      #expect(failed.snapshot.weekly == observed.snapshot.weekly)
      #expect(failed.snapshot.fiveHour == observed.snapshot.fiveHour)
      #expect(
        failed.snapshot.claudeAccountFingerprint == observed.snapshot.claudeAccountFingerprint)
      #expect(failed.snapshot.sourceState == .attemptFailed)
      #expect(
        failed.snapshot.errorCode
          == (status == "rateLimited" ? .temporaryFailure : .sourceUnavailable))
      let empty = try self.apply(self.envelope(status: status))
      #expect(empty.snapshot.capturedAt == nil)
      #expect(empty.snapshot.weekly == nil)
      previous = failed
    }
  }

  @Test(
    "Silent browser observations expire without releasing the connection or renewing timestamps")
  func silentObservationExpires() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope()), now: self.now)
    let original = try #require(try store.load())
    let bytes = try Data(contentsOf: store.url)
    #expect(store.selectedSnapshot(now: self.now.addingTimeInterval(900)) == original.snapshot)

    for age in [901.0, 3_601, 604_800] {
      let expired = try #require(store.selectedSnapshot(now: self.now.addingTimeInterval(age)))
      #expect(expired.source == .claudeBrowser)
      #expect(expired.weekly == nil)
      #expect(expired.fiveHour == nil)
      #expect(expired.capturedAt == nil)
      #expect(expired.lastAttemptAt == original.snapshot.lastAttemptAt)
      #expect(expired.sourceState == .attemptFailed)
      #expect(expired.errorCode == .sourceUnavailable)
      #expect(expired.claudeAccountFingerprint == nil)
      #expect(expired.claudeOrganizationFingerprint == nil)
    }
    #expect(try store.load() == original)
    #expect(try Data(contentsOf: store.url) == bytes)
    #expect(original.enabled)
  }

  @Test("Error messages cannot rejuvenate old quotas or turn saved 429 waits into fallback")
  func errorMessagesDoNotRenewQuotaAge() throws {
    for status in ["unavailable", "rateLimited"] {
      let root = try self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = ClaudeBrowserStore(directory: root)
      try self.connect(store)
      try store.ingest(self.data(self.envelope()), now: self.now)
      let later = self.now.addingTimeInterval(901)
      try store.ingest(self.data(self.envelope(status: status, offset: 901)), now: later)
      let bytes = try Data(contentsOf: store.url)
      for age in [901.0, 1_801, 4_502] {
        let expired = try #require(store.selectedSnapshot(now: self.now.addingTimeInterval(age)))
        #expect(expired.weekly == nil)
        #expect(expired.fiveHour == nil)
        #expect(expired.capturedAt == nil)
        #expect(expired.lastAttemptAt == later)
        #expect(
          expired.errorCode == (status == "rateLimited" ? .temporaryFailure : .sourceUnavailable))
      }
      #expect(try Data(contentsOf: store.url) == bytes)
      #expect(try store.load()?.lastStatus.rawValue == status)
    }
  }

  @Test(
    "Expiry preserves replay and owner guards, and only fresh same-owner success restores quotas")
  func expiredConnectionRetainsBinding() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope()), now: self.now)
    let later = self.now.addingTimeInterval(901)
    #expect(try #require(store.selectedSnapshot(now: later)).weekly == nil)
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try store.ingest(
        self.data(
          self.envelope(
            status: "connected", offset: 901,
            connectionID: "40000000-0000-4000-8000-000000000004")), now: later)
    }
    #expect(throws: ClaudeBrowserBridgeError.staleMessage) {
      try store.ingest(self.data(self.envelope(offset: 901, sequence: 301)), now: later)
    }
    var mismatch = self.envelope(offset: 901)
    mismatch["principalFingerprint"] = String(repeating: "d", count: 64)
    #expect(throws: ClaudeBrowserBridgeError.accountMismatch) {
      try store.ingest(self.data(mismatch), now: later)
    }
    #expect(store.selectedSnapshot(now: later)?.weekly == nil)
    try store.ingest(self.data(self.envelope(offset: 902)), now: later.addingTimeInterval(1))
    let recovered = try #require(store.selectedSnapshot(now: later.addingTimeInterval(1)))
    #expect(recovered.weekly?.remainingPercent == 73.5)
    #expect(recovered.capturedAt == later.addingTimeInterval(1))
    #expect(recovered.claudeAccountFingerprint == String(repeating: "a", count: 64))
  }

  @Test("Signout, account ambiguity and disconnect clear both windows without resurrecting them")
  func clearSnapshots() throws {
    let original = try self.apply(self.envelope(offset: -120))
    for status in ["signedOut", "accountChanged", "organizationSelectionRequired", "disconnected"] {
      let cleared = try self.apply(self.envelope(status: status, offset: -60), previous: original)
      #expect(cleared.snapshot.capturedAt == nil)
      #expect(cleared.snapshot.weekly == nil)
      #expect(cleared.snapshot.fiveHour == nil)
      #expect(cleared.snapshot.lastAttemptAt == self.now.addingTimeInterval(-60))
      #expect(cleared.enabled == (status != "disconnected"))
      #expect(
        cleared.snapshot.errorCode
          == (status == "signedOut" ? .authenticationRequired : .sourceUnavailable))
      if status == "disconnected" {
        #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
          try self.apply(self.envelope(status: "unavailable"), previous: cleared)
        }
        continue
      }
      let laterFailure = try self.apply(self.envelope(status: "unavailable"), previous: cleared)
      #expect(laterFailure.snapshot.capturedAt == nil)
      #expect(laterFailure.snapshot.weekly == nil)
      #expect(laterFailure.snapshot.fiveHour == nil)
    }
  }

  @Test("Explicit disconnect permits a new account on the same profile without merging windows")
  func disconnectThenRebind() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(offset: -120)), now: self.now)
    try store.ingest(self.data(self.envelope(status: "disconnected", offset: -60)), now: self.now)
    #expect(store.selectedSnapshot(now: self.now) == nil)
    let newConnection = "40000000-0000-4000-8000-000000000004"
    try self.connect(store, connectionID: newConnection)
    var next = self.envelope(connectionID: newConnection, sequence: 1)
    next["accountFingerprint"] = String(repeating: "d", count: 64)
    next["organizationFingerprint"] = String(repeating: "e", count: 64)
    next["principalFingerprint"] = String(repeating: "f", count: 64)
    next.removeValue(forKey: "fiveHour")
    try store.ingest(self.data(next), now: self.now)
    let rebound = try #require(store.selectedSnapshot(now: self.now))
    #expect(rebound.claudeAccountFingerprint == String(repeating: "d", count: 64))
    #expect(rebound.claudeOrganizationFingerprint == String(repeating: "e", count: 64))
    #expect(rebound.fiveHour == nil)
    #expect(rebound.capturedAt == self.now)
  }

  @Test(
    "App disconnect retires ownership and rejects late extension messages without the extension")
  func appDisconnectRetiresConnection() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope(offset: -60)), now: self.now)
    try store.disconnect(now: self.now)
    let disconnected = try #require(try store.load())
    #expect(!disconnected.enabled)
    #expect(disconnected.lastStatus == .disconnected)
    #expect(disconnected.retiredConnectionIDs == [self.connectionID])
    #expect(disconnected.accountFingerprint == nil)
    #expect(disconnected.organizationFingerprint == nil)
    #expect(disconnected.principalFingerprint == nil)
    #expect(disconnected.snapshot.weekly == nil)
    #expect(disconnected.snapshot.fiveHour == nil)
    #expect(disconnected.snapshot.capturedAt == nil)
    #expect(store.selectedSnapshot(now: self.now) == nil)
    let bytes = try Data(contentsOf: store.url)
    try store.disconnect(now: self.now.addingTimeInterval(1))
    #expect(try Data(contentsOf: store.url) == bytes)
    try store.ingest(self.data(self.envelope(status: "disconnected", offset: 1)), now: self.now)
    #expect(try Data(contentsOf: store.url) == bytes)
    for status in ["ok", "unavailable", "rateLimited", "connected"] {
      #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
        try store.ingest(self.data(self.envelope(status: status, offset: 1)), now: self.now)
      }
      #expect(try Data(contentsOf: store.url) == bytes)
    }
    let next = "40000000-0000-4000-8000-000000000004"
    #expect(throws: ClaudeBrowserBridgeError.connectionMismatch) {
      try store.ingest(
        self.data(
          self.envelope(
            status: "connected", offset: -1, connectionID: next)), now: self.now)
    }
    try store.ingest(
      self.data(
        self.envelope(
          status: "connected", offset: 1, connectionID: next)), now: self.now)
    try store.ingest(self.data(self.envelope(offset: 2, connectionID: next)), now: self.now)
    #expect(store.selectedSnapshot(now: self.now)?.weekly?.remainingPercent == 73.5)
  }

  @Test("App and native host writers use the same lock and never write through contention")
  func sharedWriterLock() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    try store.ingest(self.data(self.envelope()), now: self.now)
    let bytes = try Data(contentsOf: store.url)
    let descriptor = open(root.appendingPathComponent("host.lock").path, O_RDWR)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: ClaudeBrowserBridgeError.bridgeBusy) { try store.disconnect(now: self.now) }
    #expect(throws: ClaudeBrowserBridgeError.bridgeBusy) {
      try store.ingest(self.data(self.envelope(offset: 1)), now: self.now)
    }
    #expect(try Data(contentsOf: store.url) == bytes)
    #expect(flock(descriptor, LOCK_UN) == 0)
    try store.disconnect(now: self.now)
    #expect(try store.load()?.enabled == false)
  }

  @Test(
    "Unsafe lock objects cannot authorize disconnect or ingestion",
    arguments: ["symlink", "hardlink", "mode"])
  func unsafeWriterLocks(kind: String) throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    let bytes = try Data(contentsOf: store.url)
    let lock = root.appendingPathComponent("host.lock")
    let other = root.appendingPathComponent("other-lock")
    if kind == "symlink" {
      try FileManager.default.moveItem(at: lock, to: other)
      try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: other)
    } else if kind == "hardlink" {
      try FileManager.default.linkItem(at: lock, to: other)
    } else {
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
    }
    #expect(throws: (any Error).self) { try store.disconnect(now: self.now) }
    #expect(throws: (any Error).self) {
      try store.ingest(self.data(self.envelope()), now: self.now)
    }
    #expect(try Data(contentsOf: store.url) == bytes)
  }

  @Test("Browser persistence round-trips normalized metadata with private permissions")
  func persistenceRoundTrip() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root.appendingPathComponent("BrowserBridge"))
    #expect(try store.load() == nil)
    #expect(store.selectedSnapshot(now: self.now) == nil)
    try self.connect(store)
    var message = self.envelope()
    message["unrecognizedRawResponse"] = "synthetic-payload-not-for-storage"
    try store.ingest(self.data(message), now: self.now)
    let restored = try #require(
      try ClaudeBrowserStore(directory: store.url.deletingLastPathComponent()).load())
    #expect(restored.snapshot == (try self.apply(self.envelope()).snapshot))
    #expect(restored.profileID == self.profileID)
    #expect(restored.principalFingerprint == String(repeating: "c", count: 64))
    #expect(
      !String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains(
        "synthetic-payload-not-for-storage"))
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: store.url.deletingLastPathComponent().path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("Symlink files and ancestor directories cannot redirect browser reads or writes")
  func symlinkPersistence() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    let originalStore = ClaudeBrowserStore(directory: real)
    try self.connect(originalStore)
    try originalStore.ingest(self.data(self.envelope(offset: -60)), now: self.now)
    let original = try Data(contentsOf: originalStore.url)
    let linkedDirectory = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: real)
    let fileDirectory = root.appendingPathComponent("file-link")
    try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
    let linkedFileStore = ClaudeBrowserStore(directory: fileDirectory)
    try FileManager.default.createSymbolicLink(
      at: linkedFileStore.url, withDestinationURL: originalStore.url)
    let danglingStore = ClaudeBrowserStore(directory: root.appendingPathComponent("dangling"))
    try FileManager.default.createDirectory(
      at: danglingStore.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let missingTarget = root.appendingPathComponent("missing-target.json")
    try FileManager.default.createSymbolicLink(
      at: danglingStore.url, withDestinationURL: missingTarget)
    for store in [ClaudeBrowserStore(directory: linkedDirectory), linkedFileStore, danglingStore] {
      #expect(throws: ClaudeAutomaticAdapterError.unsafePath) { try store.load() }
      #expect(throws: ClaudeAutomaticAdapterError.unsafePath) {
        try store.ingest(self.data(self.envelope()), now: self.now)
      }
      self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
      #expect(try Data(contentsOf: originalStore.url) == original)
    }
    #expect(!FileManager.default.fileExists(atPath: missingTarget.path))
  }

  @Test("Oversized and corrupt records fail closed and are not silently overwritten")
  func invalidPersistence() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    let oversized = Data(repeating: 0x20, count: NormalizedSnapshotStore.maximumRecordBytes + 1)
    try oversized.write(to: store.url)
    #expect(throws: ClaudeAutomaticAdapterError.inputTooLarge) { try store.load() }
    for bytes in [oversized, Data("{broken".utf8), Data()] {
      try bytes.write(to: store.url)
      #expect(throws: (any Error).self) { try store.load() }
      self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
      #expect(throws: (any Error).self) {
        try store.ingest(self.data(self.envelope()), now: self.now)
      }
      #expect(try Data(contentsOf: store.url) == bytes)
    }
  }

  @Test("Persisted schema, identity and normalized snapshot semantics are revalidated")
  func persistedRecordValidation() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    let good = try JSONEncoder().encode(self.apply(self.envelope()))
    let base = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
    for (key, value) in [
      ("schemaVersion", 2 as Any), ("profileID", "invalid" as Any),
      ("connectionID", "invalid" as Any), ("lastSequence", -1 as Any),
      ("lastSequence", 9_007_199_254_740_992 as Any),
      ("principalFingerprint", "bad" as Any),
    ] {
      var object = base
      object[key] = value
      try self.data(object).write(to: store.url)
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try store.load() }
      self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
    }
    for (key, value) in [("provider", "codex"), ("source", "claudeCLI")] {
      var object = base
      var snapshot = try #require(object["snapshot"] as? [String: Any])
      snapshot[key] = value
      object["snapshot"] = snapshot
      try self.data(object).write(to: store.url)
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try store.load() }
      self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
    }
    var object = base
    var snapshot = try #require(object["snapshot"] as? [String: Any])
    var weekly = try #require(snapshot["weekly"] as? [String: Any])
    weekly["remainingPercent"] = 101
    snapshot["weekly"] = weekly
    object["snapshot"] = snapshot
    try self.data(object).write(to: store.url)
    #expect(throws: SnapshotStoreError.invalidRecord) { try store.load() }
    self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
  }

  @Test("Persisted quota ownership hashes must match the record binding")
  func persistedOwnershipConsistency() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    let good = try JSONEncoder().encode(self.apply(self.envelope()))
    let base = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
    for key in ["claudeAccountFingerprint", "claudeOrganizationFingerprint"] {
      for value: Any in [String(repeating: "d", count: 64), NSNull()] {
        var object = base
        var snapshot = try #require(object["snapshot"] as? [String: Any])
        snapshot[key] = value
        object["snapshot"] = snapshot
        try self.data(object).write(to: store.url)
        #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try store.load() }
        self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
      }
    }
    for key in ["accountFingerprint", "organizationFingerprint", "principalFingerprint"] {
      var object = base
      object.removeValue(forKey: key)
      try self.data(object).write(to: store.url)
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try store.load() }
      self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
    }
  }

  @Test("Persisted capture and attempt timestamps cannot exceed the last validated message")
  func persistedTimestampOrdering() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    let good = try JSONEncoder().encode(self.apply(self.envelope()))
    let base = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
    for key in ["capturedAt", "lastAttemptAt"] {
      var object = base
      var snapshot = try #require(object["snapshot"] as? [String: Any])
      snapshot[key] = self.now.addingTimeInterval(1).timeIntervalSinceReferenceDate
      object["snapshot"] = snapshot
      try self.data(object).write(to: store.url)
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try store.load() }
      self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
    }
    for lastMessageAt in [self.now.addingTimeInterval(-1), Date(timeIntervalSince1970: 0)] {
      var object = base
      object["lastMessageAt"] = lastMessageAt.timeIntervalSinceReferenceDate
      try self.data(object).write(to: store.url)
      #expect(throws: ClaudeBrowserBridgeError.invalidMessage) { try store.load() }
      self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now))
    }
    try good.write(to: store.url)
    #expect(try store.load()?.lastMessageAt == self.now)
  }

  @Test("An expired browser week never produces a rolled-forward P or remaining balance")
  func expiredWeeklyDoesNotPlan() throws {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClaudeBrowserStore(directory: root)
    try self.connect(store)
    var message = self.envelope()
    let reset = self.now.addingTimeInterval(60)
    message["weekly"] = ["remainingPercent": 73.5, "resetAt": self.iso(reset)]
    try store.ingest(self.data(message), now: self.now)
    for date in [reset, reset.addingTimeInterval(1)] {
      let snapshot = try #require(store.selectedSnapshot(now: date))
      let plan = QuotaPlanner.evaluate(snapshot, now: date)
      #expect(snapshot.weekly?.resetAt == reset)
      #expect(snapshot.capturedAt == self.now)
      #expect(plan.status == .resetElapsed)
      #expect(plan.weeklyRemaining == nil)
      #expect(plan.targetNow == nil)
      #expect(plan.vsTarget == nil)
      #expect(plan.availableUntilCheckpoint == nil)
    }
    let expired = try #require(store.selectedSnapshot(now: reset.addingTimeInterval(604_800)))
    #expect(expired.weekly == nil)
    #expect(expired.capturedAt == nil)
    self.expectInvalidSnapshot(store.selectedSnapshot(now: self.now.addingTimeInterval(-31)))
  }

  @Test("Browser source survives normalized codec and is rejected for Codex")
  func browserSourceCodec() throws {
    let snapshot = try self.apply(self.envelope()).snapshot
    let encoded = try NormalizedSnapshotCodec.encode(snapshot)
    #expect(try NormalizedSnapshotCodec.decode(encoded) == snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let nested = try #require(object["snapshot"] as? [String: Any])
    #expect(nested["source"] as? String == "claudeBrowser")
    let wrongProvider = ProviderSnapshot(
      provider: .codex, source: .claudeBrowser, capturedAt: self.now,
      weekly: snapshot.weekly, sourceState: .observationSucceeded)
    #expect(throws: SnapshotStoreError.invalidRecord) {
      try NormalizedSnapshotCodec.encode(wrongProvider)
    }
  }

  private func envelope(
    status: String = "ok", offset: TimeInterval = 0,
    connectionID: String? = nil, sequence: Int? = nil
  ) -> [String: Any] {
    var object: [String: Any] = [
      "schemaVersion": 1, "profileID": self.profileID,
      "connectionID": connectionID ?? self.connectionID,
      "sequence": sequence ?? (status == "connected" ? 0 : Int(offset) + 301),
      "observedAt": self.iso(self.now.addingTimeInterval(offset)), "status": status,
    ]
    if status == "ok" {
      object["accountFingerprint"] = String(repeating: "a", count: 64)
      object["organizationFingerprint"] = String(repeating: "b", count: 64)
      object["principalFingerprint"] = String(repeating: "c", count: 64)
      object["weekly"] = [
        "remainingPercent": 73.5, "resetAt": self.iso(self.now.addingTimeInterval(259_200)),
      ]
      object["fiveHour"] = [
        "remainingPercent": 20.0, "resetAt": self.iso(self.now.addingTimeInterval(3_600)),
      ]
    }
    return object
  }

  private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func data(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func apply(_ object: [String: Any], previous: ClaudeBrowserRecord? = nil) throws
    -> ClaudeBrowserRecord
  {
    // Validation tests use an established connection unless they explicitly test the handshake.
    let connected =
      try previous
      ?? ClaudeBrowserRecord.applying(
        ClaudeBrowserMessage.decode(self.data(self.envelope(status: "connected", offset: -300))),
        to: nil, now: self.now)
    return try ClaudeBrowserRecord.applying(
      ClaudeBrowserMessage.decode(self.data(object)), to: connected, now: self.now)
  }

  private func connect(
    _ store: ClaudeBrowserStore, profileID: String? = nil, connectionID: String? = nil
  ) throws {
    let offset = try store.load()?.lastMessageAt.timeIntervalSince(self.now) ?? -300
    var handshake = self.envelope(status: "connected", offset: offset, connectionID: connectionID)
    handshake["profileID"] = profileID ?? self.profileID
    try store.ingest(self.data(handshake), now: self.now)
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClaudeBrowserBridgeTests.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func readFrame(_ bytes: Data) throws -> Data {
    let root = try self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("frame.bin")
    try bytes.write(to: url)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try NativeMessageFraming.read(from: handle)
  }

  private func expectInvalidSnapshot(_ snapshot: ProviderSnapshot?) {
    #expect(snapshot?.source == .claudeBrowser)
    #expect(snapshot?.sourceState == .attemptFailed)
    #expect(snapshot?.errorCode == .invalidResponse)
    #expect(snapshot?.capturedAt == nil)
    #expect(snapshot?.weekly == nil)
    #expect(snapshot?.fiveHour == nil)
  }
}
