import Foundation
import Testing

@testable import QuotaTempoApp

// Pure decoder fixtures only: fixed time, synthetic UUIDs, no provider or account data.
@Suite("Code comparison protocol decoding")
struct CodeComparisonDecoderTests {
  @Test("An unavailable interval cannot renew the first-seen watermark for the same tuple")
  func failurePreservesAge() throws {
    var decoder = Fixture.decoder()
    #expect(decoder.consume(try Fixture.data(), now: Fixture.now).status == .comparisonOnly)
    _ = decoder.unavailable()
    let later = Fixture.now.addingTimeInterval(301)
    let oldReset = Fixture.timestamp(Fixture.now.addingTimeInterval(86_400))
    let repeated = try Fixture.data(
      sequence: 2, read: later, kinds: ["seven_day"],
      rowOverrides: [
        "resetsAt": oldReset, "percentUsed": 25.5,
      ])
    #expect(decoder.consume(repeated, now: later).status == .stale)
  }
  @Test(
    "Both windows and either subset retain exact remaining percentages and resets",
    arguments: [
      ["seven_day", "five_hour"], ["five_hour", "seven_day"], ["seven_day"], ["five_hour"],
    ])
  func validWindows(_ kinds: [String]) throws {
    let read = Fixture.now.addingTimeInterval(-2)
    var decoder = Fixture.decoder()
    let view = decoder.consume(try Fixture.data(read: read, kinds: kinds), now: Fixture.now)
    #expect(view.status == .comparisonOnly)
    #expect(view.receivedAt == read)
    #expect(
      view.weekly
        == (kinds.contains("seven_day")
          ? CodeUsageComparisonWindow(
            remainingPercent: 74.5, resetAt: read.addingTimeInterval(86_400))
          : nil))
    #expect(
      view.fiveHour
        == (kinds.contains("five_hour")
          ? CodeUsageComparisonWindow(
            remainingPercent: 26.75, resetAt: read.addingTimeInterval(3_600))
          : nil))
  }

  @Test(
    "Percent endpoints and fractional utilization are not clamped",
    arguments: [0.0, 100.0, 12.345])
  func validPercent(_ used: Double) throws {
    var decoder = Fixture.decoder()
    let view = decoder.consume(
      try Fixture.data(rowOverrides: ["percentUsed": used]), now: Fixture.now)
    #expect(view.status == .comparisonOnly)
    #expect(view.weekly?.remainingPercent == 100 - used)
    #expect(view.fiveHour?.remainingPercent == 100 - used)
  }

  @Test(
    "Sequence accepts both safe integer endpoints", arguments: [Int64(1), 9_007_199_254_740_991])
  func validSequence(_ sequence: Int64) throws {
    var decoder = Fixture.decoder()
    #expect(
      decoder.consume(try Fixture.data(sequence: sequence), now: Fixture.now).status
        == .comparisonOnly)
  }

  @Test(
    "Invalid numeric types and ranges clear previously displayed values",
    arguments: ["envelopeSchema", "resultSchema", "sequence", "percentUsed"])
  func invalidNumbers(_ field: String) throws {
    var values: [Any] = [true, false, "1", NSNull(), [], ["value": 1]]
    switch field {
    case "sequence": values += [0, -1, 1.5, Int64(9_007_199_254_740_992)]
    case "percentUsed": values += [-0.001, 100.001, "NaN", "Infinity"]
    default: values += [0, 2, 1.5]
    }
    for value in values {
      let data: Data
      switch field {
      case "envelopeSchema":
        data = try Fixture.data(sequence: 2, envelopeOverrides: ["schemaVersion": value])
      case "resultSchema":
        data = try Fixture.data(sequence: 2, resultOverrides: ["schemaVersion": value])
      case "sequence": data = try Fixture.data(sequence: value)
      default: data = try Fixture.data(sequence: 2, rowOverrides: ["percentUsed": value])
      }
      try expectRejected(data)
    }
  }

  @Test(
    "Nonfinite tokens are malformed JSON, not valid numeric observations",
    arguments: ["NaN", "Infinity", "-Infinity", "1e999"])
  func nonfiniteJSON(_ token: String) throws {
    let text = String(decoding: try Fixture.data(sequence: 2), as: UTF8.self)
    try #require(text.contains("\"percentUsed\":25.5"))
    let malformed = text.replacingOccurrences(
      of: "\"percentUsed\":25.5", with: "\"percentUsed\":\(token)")
    try expectRejected(Data(malformed.utf8))
  }

  @Test("Every protocol layer requires exact keys", arguments: ["envelope", "result", "row"])
  func exactKeys(_ layer: String) throws {
    var object = Fixture.envelope(sequence: 2)
    let keys: [String]
    switch layer {
    case "envelope": keys = ["schemaVersion", "connectionID", "streamID", "sequence", "result"]
    case "result": keys = ["schemaVersion", "status", "reason", "readAt", "rateLimits"]
    default: keys = ["kind", "percentUsed", "resetsAt", "firstSeenAt", "lastReadAt"]
    }
    for key in keys {
      var missing = object
      Fixture.edit(&missing, layer: layer) { $0.removeValue(forKey: key) }
      try expectRejected(Fixture.encode(missing))
    }
    Fixture.edit(&object, layer: layer) { $0["unknownField"] = "synthetic" }
    try expectRejected(Fixture.encode(object))
  }

  @Test(
    "Unknown and model-scoped kinds never substitute for all-model windows",
    arguments: [
      "unknown", "seven_day_sonnet", "seven_day_opus", "five_hour_sonnet", "SEVEN_DAY", "",
    ])
  func invalidKind(_ kind: String) throws {
    try expectRejected(Fixture.data(sequence: 2, rowOverrides: ["kind": kind]))
  }

  @Test("Duplicate kinds and empty or oversized window lists are rejected")
  func invalidWindowLists() throws {
    for kinds in [
      [], ["seven_day", "seven_day"], ["five_hour", "five_hour"],
      ["seven_day", "five_hour", "seven_day"],
    ] {
      try expectRejected(Fixture.data(sequence: 2, kinds: kinds))
    }
    let invalidLists: [Any] = [NSNull(), true, "windows", [1], ["seven_day": [String: Any]()]]
    for value in invalidLists {
      try expectRejected(Fixture.data(sequence: 2, resultOverrides: ["rateLimits": value]))
    }
    let invalidResults: [Any] = [NSNull(), true, "result", [Any]()]
    for value in invalidResults {
      try expectRejected(Fixture.data(sequence: 2, envelopeOverrides: ["result": value]))
    }
  }

  @Test(
    "Identifiers must be matching lowercase UUIDv4 values", arguments: ["connectionID", "streamID"])
  func invalidIdentifiers(_ field: String) throws {
    let valid = field == "connectionID" ? Fixture.connectionID : Fixture.streamID
    let invalid = [
      valid.uppercased(), valid.replacingOccurrences(of: "-4", with: "-1"),
      valid.replacingOccurrences(of: "-8", with: "-7"), "not-a-uuid", " " + valid, valid + "\n",
    ]
    for value in invalid {
      var decoder = CodeComparisonDecoder(
        connectionID: field == "connectionID" ? value : Fixture.connectionID,
        streamID: field == "streamID" ? value : Fixture.streamID)
      expectClear(
        decoder.consume(try Fixture.data(envelopeOverrides: [field: value]), now: Fixture.now))
    }
    let mismatches: [Any] = [
      valid.uppercased(), "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", NSNull(), true,
    ]
    for value in mismatches {
      try expectRejected(Fixture.data(sequence: 2, envelopeOverrides: [field: value]))
    }
  }

  @Test(
    "Unavailable and invalid results accept only the reason allowlist and clear all fields",
    arguments: ["invalid", "unavailable"],
    [
      "invalid_read_at", "invalid_usage", "invalid_rate_limits", "invalid_limit", "unknown_kind",
      "duplicate_kind", "invalid_percent_used", "missing_reset", "invalid_reset", "expired_reset",
      "getter_failed", "clock_failed", "clock_regressed", "disconnected",
    ])
  func nonvalidResults(_ status: String, _ reason: String) throws {
    let readTimes: [Any] = [NSNull(), "2023-11-14T22:13:20.000Z"]
    for read in readTimes {
      var decoder = Fixture.decoder()
      try #require(decoder.consume(try Fixture.data(), now: Fixture.now).status == .comparisonOnly)
      let data = try Fixture.data(
        sequence: 2, kinds: [],
        resultOverrides: [
          "status": status, "reason": reason, "readAt": read,
        ])
      expectClear(
        decoder.consume(data, now: Fixture.now),
        status: reason == "disconnected" ? .disconnected : .unavailable)
    }
  }

  @Test("Invalid status, reason, readAt and nonempty failure windows fail closed")
  func invalidResultSemantics() throws {
    let invalidStatuses: [Any] = ["ok", "connected", "VALID", "", true, NSNull()]
    for status in invalidStatuses {
      try expectRejected(Fixture.data(sequence: 2, resultOverrides: ["status": status]))
    }
    let invalidValidReasons: [Any] = ["getter_failed", "", true, 0]
    for reason in invalidValidReasons {
      try expectRejected(Fixture.data(sequence: 2, resultOverrides: ["reason": reason]))
    }
    for status in ["invalid", "unavailable"] {
      let invalidFailureReasons: [Any] = [NSNull(), "unknown_reason", true, 0]
      for reason in invalidFailureReasons {
        try expectRejected(
          Fixture.data(
            sequence: 2, kinds: [], resultOverrides: ["status": status, "reason": reason]))
      }
      try expectRejected(
        Fixture.data(
          sequence: 2, resultOverrides: ["status": status, "reason": "getter_failed"]))
      try expectRejected(
        Fixture.data(
          sequence: 2, kinds: [],
          resultOverrides: [
            "status": status, "reason": "getter_failed", "readAt": "2023-11-14T22:13:20Z",
          ]))
    }
  }

  @Test(
    "Timestamp fields reject noncanonical and impossible calendar values",
    arguments: ["readAt", "resetsAt", "firstSeenAt", "lastReadAt"])
  func invalidDates(_ field: String) throws {
    let values: [Any] = [
      NSNull(), true, 1_700_000_000, "", "tomorrow", "2023-11-14",
      "2023-11-14T22:13:20Z", "2023-11-14T22:13:20.00Z", "2023-11-14T22:13:20.0000Z",
      "2023-11-14T22:13:20.000+00:00", "2023-11-15T07:13:20.000+09:00",
      "2023-11-14t22:13:20.000z", "2023-11-14T22:13:20.000Z\n",
      " 2023-11-14T22:13:20.000Z", "2023-02-29T22:13:20.000Z",
      "2023-02-30T22:13:20.000Z", "2023-04-31T22:13:20.000Z",
      "2023-13-14T22:13:20.000Z", "2023-00-14T22:13:20.000Z",
      "2023-11-00T22:13:20.000Z", "2023-11-14T24:13:20.000Z",
      "2023-11-14T22:60:20.000Z", "2023-11-14T22:13:60.000Z",
    ]
    for value in values {
      try expectRejected(
        Fixture.data(
          sequence: 2, rowOverrides: field == "readAt" ? [:] : [field: value],
          resultOverrides: field == "readAt" ? [field: value] : [:]))
    }
  }

  @Test("First seen cannot follow read time and last read must equal read time")
  func observationOrdering() throws {
    try expectRejected(
      Fixture.data(
        sequence: 2,
        rowOverrides: [
          "firstSeenAt": Fixture.timestamp(Fixture.now.addingTimeInterval(0.001))
        ]))
    for offset in [-0.001, 0.001] {
      try expectRejected(
        Fixture.data(
          sequence: 2,
          rowOverrides: [
            "lastReadAt": Fixture.timestamp(Fixture.now.addingTimeInterval(offset))
          ]))
    }
  }

  @Test("Missing or expired reset is never inferred", arguments: ["seven_day", "five_hour"])
  func requiredFutureReset(_ kind: String) throws {
    var missing = Fixture.envelope(sequence: 2, kinds: [kind])
    Fixture.edit(&missing, layer: "row") { $0.removeValue(forKey: "resetsAt") }
    try expectRejected(Fixture.encode(missing))
    let resets: [Any] = [
      NSNull(), "", Fixture.timestamp(Fixture.now),
      Fixture.timestamp(Fixture.now.addingTimeInterval(-0.001)),
    ]
    for value in resets {
      try expectRejected(
        Fixture.data(
          sequence: 2, kinds: [kind], rowOverrides: ["resetsAt": value]))
    }
  }

  @Test(
    "Future reset horizons are inclusive and measured from read time",
    arguments: ["seven_day", "five_hour"])
  func resetHorizon(_ kind: String) throws {
    let horizon: TimeInterval = kind == "seven_day" ? 8 * 86_400 : 6 * 3_600
    let read = Fixture.now.addingTimeInterval(-2)
    for offset in [0.001, horizon - 0.001, horizon] {
      var decoder = Fixture.decoder()
      let data = try Fixture.data(
        read: read, kinds: [kind],
        rowOverrides: [
          "resetsAt": Fixture.timestamp(read.addingTimeInterval(offset))
        ])
      let view = decoder.consume(data, now: read)
      #expect(view.status == .comparisonOnly)
      let reset = try #require((view.weekly ?? view.fiveHour)?.resetAt)
      #expect(Fixture.timestamp(reset) == Fixture.timestamp(read.addingTimeInterval(offset)))
    }
    // This is within the horizon from local now, but outside it from readAt.
    try expectRejected(
      Fixture.data(
        sequence: 2, read: read, kinds: [kind],
        rowOverrides: [
          "resetsAt": Fixture.timestamp(read.addingTimeInterval(horizon + 0.001))
        ]))
  }

  @Test("Future read clock skew accepts exactly five seconds", arguments: [4.999, 5.0, 5.001])
  func futureClockBoundary(_ offset: TimeInterval) throws {
    var decoder = Fixture.decoder()
    let read = Fixture.now.addingTimeInterval(offset)
    let view = decoder.consume(try Fixture.data(read: read), now: Fixture.now)
    if offset <= 5 {
      #expect(view.status == .comparisonOnly)
      let received = try #require(view.receivedAt)
      #expect(Fixture.timestamp(received) == Fixture.timestamp(read))
    } else {
      expectClear(view)
    }
  }

  @Test("A regressed local clock clears values before even an identical reread")
  func clockRegression() throws {
    var decoder = Fixture.decoder()
    let data = try Fixture.data()
    try #require(decoder.consume(data, now: Fixture.now).status == .comparisonOnly)
    #expect(decoder.consume(data, now: Fixture.now).status == .comparisonOnly)
    expectClear(
      decoder.consume(data, now: Fixture.now.addingTimeInterval(-0.001)), status: .invalidClock)
    expectClear(decoder.consume(data, now: Fixture.now), status: .invalidClock)
    #expect(
      decoder.consume(try Fixture.data(sequence: 2), now: Fixture.now).status == .comparisonOnly)
  }

  @Test(
    "Nonfinite local clocks fail closed",
    arguments: [Double.nan, Double.infinity, -Double.infinity])
  func nonfiniteClock(_ seconds: Double) throws {
    var decoder = Fixture.decoder()
    try #require(decoder.consume(try Fixture.data(), now: Fixture.now).status == .comparisonOnly)
    expectClear(
      decoder.consume(try Fixture.data(sequence: 2), now: Date(timeIntervalSince1970: seconds)),
      status: .invalidClock)
  }

  @Test(
    "Different bytes with duplicate or lower sequence clear the view",
    arguments: [Int64(9), Int64(10)])
  func replaySequences(_ sequence: Int64) throws {
    var decoder = Fixture.decoder()
    let original = try Fixture.data(sequence: 10)
    try #require(decoder.consume(original, now: Fixture.now).status == .comparisonOnly)
    // Trailing JSON whitespace changes bytes without changing any observation.
    expectClear(
      decoder.consume(try Fixture.data(sequence: sequence) + Data(" ".utf8), now: Fixture.now))
    expectClear(decoder.consume(original, now: Fixture.now))
    #expect(
      decoder.consume(try Fixture.data(sequence: 11), now: Fixture.now).status == .comparisonOnly)
  }

  @Test("Identical rereads preserve read time and cannot refresh age")
  func unchangedReread() throws {
    var decoder = Fixture.decoder()
    let data = try Fixture.data()
    let initial = decoder.consume(data, now: Fixture.now)
    try #require(initial.status == .comparisonOnly)
    #expect(decoder.consume(data, now: Fixture.now.addingTimeInterval(299)) == initial)
    #expect(decoder.consume(data, now: Fixture.now.addingTimeInterval(300)) == initial)
    expectClear(decoder.consume(data, now: Fixture.now.addingTimeInterval(300.001)), status: .stale)
    expectClear(decoder.consume(data, now: Fixture.now.addingTimeInterval(301)), status: .stale)
  }

  @Test("Explicit unavailability retains replay watermark and old bytes cannot restore values")
  func explicitUnavailable() throws {
    var decoder = Fixture.decoder()
    let data = try Fixture.data()
    try #require(decoder.consume(data, now: Fixture.now).status == .comparisonOnly)
    expectClear(decoder.unavailable())
    expectClear(decoder.unavailable())
    expectClear(decoder.consume(data, now: Fixture.now))
    expectClear(decoder.consume(data + Data(" ".utf8), now: Fixture.now))
    #expect(
      decoder.consume(try Fixture.data(sequence: 2), now: Fixture.now).status == .comparisonOnly)
  }

  @Test("Disconnect clears values, advances sequence and cannot restore an old observation")
  func disconnectClears() throws {
    var decoder = Fixture.decoder()
    let data = try Fixture.data()
    try #require(decoder.consume(data, now: Fixture.now).status == .comparisonOnly)
    let disconnected = try Fixture.data(
      sequence: 2, kinds: [],
      resultOverrides: [
        "status": "unavailable", "reason": "disconnected", "readAt": NSNull(),
      ])
    expectClear(decoder.consume(disconnected, now: Fixture.now), status: .disconnected)
    expectClear(decoder.consume(disconnected, now: Fixture.now), status: .disconnected)
    expectClear(decoder.consume(data, now: Fixture.now))
    expectClear(decoder.consume(try Fixture.data(sequence: 2), now: Fixture.now))
    #expect(
      decoder.consume(try Fixture.data(sequence: 3), now: Fixture.now).status == .comparisonOnly)
  }

  @Test(
    "Higher sequence and newer firstSeen cannot renew an unchanged tuple",
    arguments: ["seven_day", "five_hour"])
  func unchangedTupleCannotRenew(_ kind: String) throws {
    var decoder = Fixture.decoder()
    try #require(
      decoder.consume(try Fixture.data(kinds: [kind]), now: Fixture.now).status == .comparisonOnly)
    let read = Fixture.now.addingTimeInterval(299)
    let reset = Fixture.now.addingTimeInterval(kind == "seven_day" ? 86_400 : 3_600)
    let updated = try Fixture.data(
      sequence: 2, read: read, kinds: [kind],
      rowOverrides: [
        "resetsAt": Fixture.timestamp(reset)
      ])
    let view = decoder.consume(updated, now: read)
    #expect(view.status == .comparisonOnly)
    #expect(view.receivedAt == read)
    #expect((view.weekly ?? view.fiveHour)?.resetAt == reset)
    #expect(
      decoder.consume(updated, now: Fixture.now.addingTimeInterval(300)).status == .comparisonOnly)
    expectClear(
      decoder.consume(updated, now: Fixture.now.addingTimeInterval(300.001)), status: .stale)
  }

  @Test(
    "A genuinely changed tuple can start a new observation", arguments: ["percentUsed", "resetsAt"])
  func changedTupleCanRefresh(_ field: String) throws {
    var decoder = Fixture.decoder()
    try #require(
      decoder.consume(try Fixture.data(kinds: ["seven_day"]), now: Fixture.now).status
        == .comparisonOnly)
    let read = Fixture.now.addingTimeInterval(299)
    var changes: [String: Any] = [
      "resetsAt": Fixture.timestamp(Fixture.now.addingTimeInterval(86_400))
    ]
    if field == "percentUsed" {
      changes[field] = 26.5
    } else {
      changes[field] = Fixture.timestamp(Fixture.now.addingTimeInterval(86_401))
    }
    let data = try Fixture.data(
      sequence: 2, read: read, kinds: ["seven_day"], rowOverrides: changes)
    #expect(decoder.consume(data, now: read).status == .comparisonOnly)
    #expect(
      decoder.consume(data, now: Fixture.now.addingTimeInterval(301)).status == .comparisonOnly)
  }

  @Test(
    "Freshness cutoff is inclusive for both firstSeen and lastRead",
    arguments: ["firstSeenAt", "readAt"])
  func freshnessCutoff(_ field: String) throws {
    for age in [299.999, 300.0, 300.001] {
      var decoder = Fixture.decoder()
      let earlier = Fixture.now.addingTimeInterval(-age)
      let data = try Fixture.data(
        read: field == "readAt" ? earlier : Fixture.now,
        rowOverrides: field == "firstSeenAt" ? [field: Fixture.timestamp(earlier)] : [:])
      let view = decoder.consume(data, now: Fixture.now)
      if age <= 300 {
        #expect(view.status == .comparisonOnly)
      } else {
        expectClear(view, status: .stale)
      }
    }
  }

  @Test("One stale window clears the entire comparison instead of keeping its fresh sibling")
  func partialStalenessClearsBoth() throws {
    var object = Fixture.envelope()
    Fixture.edit(&object, layer: "row") {
      $0["firstSeenAt"] = Fixture.timestamp(Fixture.now.addingTimeInterval(-300.001))
    }
    var decoder = Fixture.decoder()
    expectClear(decoder.consume(try Fixture.encode(object), now: Fixture.now), status: .stale)
  }

  @Test(
    "Reset crossing clears both windows and never infers a renewed quota",
    arguments: ["seven_day", "five_hour"])
  func resetCrossing(_ kind: String) throws {
    var decoder = Fixture.decoder()
    var object = Fixture.envelope()
    var result = try #require(object["result"] as? [String: Any])
    var rows = try #require(result["rateLimits"] as? [[String: Any]])
    let index = try #require(rows.firstIndex { $0["kind"] as? String == kind })
    rows[index]["resetsAt"] = Fixture.timestamp(Fixture.now.addingTimeInterval(10))
    result["rateLimits"] = rows
    object["result"] = result
    let data = try Fixture.encode(object)
    #expect(
      decoder.consume(data, now: Fixture.now.addingTimeInterval(9.999)).status == .comparisonOnly)
    expectClear(
      decoder.consume(data, now: Fixture.now.addingTimeInterval(10)), status: .resetPassed)
    expectClear(
      decoder.consume(data, now: Fixture.now.addingTimeInterval(11)), status: .resetPassed)
  }

  @Test("Exactly 16 KiB is accepted and the next byte clears a prior valid view")
  func byteLimit() throws {
    let base = try Fixture.data()
    try #require(base.count < 16 * 1_024)
    let exact = base + Data(repeating: 0x20, count: 16 * 1_024 - base.count)
    var decoder = Fixture.decoder()
    #expect(exact.count == 16 * 1_024)
    #expect(decoder.consume(exact, now: Fixture.now).status == .comparisonOnly)
    expectClear(decoder.consume(exact + Data([0x20]), now: Fixture.now))
    expectClear(decoder.consume(exact, now: Fixture.now))
  }

  @Test("Empty, large, malformed and invalid UTF-8 inputs clear all cached values")
  func malformedInput() throws {
    for data in [
      Data(), Data(repeating: 0x20, count: 16 * 1_024 + 1), Data([0xFF, 0xFE]),
      Data("{".utf8), Data("null".utf8), Data("[]".utf8), Data("true".utf8),
      Data("{} trailing".utf8), Data("{\"result\":}".utf8),
    ] {
      try expectRejected(data)
    }
    var invalidUTF8 = try Fixture.data(sequence: 2)
    let index = try #require(invalidUTF8.firstIndex(of: 0x61))
    invalidUTF8[index] = 0xFF
    try expectRejected(invalidUTF8)
  }

  private func expectRejected(
    _ data: Data, sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    var decoder = Fixture.decoder()
    try #require(
      decoder.consume(try Fixture.data(), now: Fixture.now).status == .comparisonOnly,
      sourceLocation: sourceLocation)
    expectClear(decoder.consume(data, now: Fixture.now), sourceLocation: sourceLocation)
  }

  private func expectClear(
    _ view: CodeUsageComparisonView, status: CodeUsageComparisonStatus = .unavailable,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(view == CodeUsageComparisonView(status: status), sourceLocation: sourceLocation)
  }
}

private enum Fixture {
  static let now = Date(timeIntervalSince1970: 1_700_000_000)
  static let connectionID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
  static let streamID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"

  static func decoder() -> CodeComparisonDecoder {
    CodeComparisonDecoder(connectionID: connectionID, streamID: streamID)
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func envelope(
    sequence: Any = 1, read: Date = now, kinds: [String] = ["seven_day", "five_hour"],
    rowOverrides: [String: Any] = [:], resultOverrides: [String: Any] = [:],
    envelopeOverrides: [String: Any] = [:]
  ) -> [String: Any] {
    let rows: [[String: Any]] = kinds.map { kind in
      var row: [String: Any] = [
        "kind": kind, "percentUsed": kind == "five_hour" ? 73.25 : 25.5,
        "resetsAt": timestamp(read.addingTimeInterval(kind == "five_hour" ? 3_600 : 86_400)),
        "firstSeenAt": timestamp(read), "lastReadAt": timestamp(read),
      ]
      row.merge(rowOverrides) { _, replacement in replacement }
      return row
    }
    var result: [String: Any] = [
      "schemaVersion": 1, "status": "valid", "reason": NSNull(),
      "readAt": timestamp(read), "rateLimits": rows,
    ]
    result.merge(resultOverrides) { _, replacement in replacement }
    var object: [String: Any] = [
      "schemaVersion": 1, "connectionID": connectionID, "streamID": streamID,
      "sequence": sequence, "result": result,
    ]
    object.merge(envelopeOverrides) { _, replacement in replacement }
    return object
  }

  static func data(
    sequence: Any = 1, read: Date = now, kinds: [String] = ["seven_day", "five_hour"],
    rowOverrides: [String: Any] = [:], resultOverrides: [String: Any] = [:],
    envelopeOverrides: [String: Any] = [:]
  ) throws -> Data {
    try encode(
      envelope(
        sequence: sequence, read: read, kinds: kinds, rowOverrides: rowOverrides,
        resultOverrides: resultOverrides, envelopeOverrides: envelopeOverrides))
  }

  static func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  // These casts touch only dictionaries constructed by this fixture, not decoded input.
  static func edit(
    _ object: inout [String: Any], layer: String, _ change: (inout [String: Any]) -> Void
  ) {
    if layer == "envelope" {
      change(&object)
      return
    }
    var result = object["result"] as! [String: Any]
    if layer == "result" {
      change(&result)
    } else {
      var rows = result["rateLimits"] as! [[String: Any]]
      change(&rows[0])
      result["rateLimits"] = rows
    }
    object["result"] = result
  }
}
