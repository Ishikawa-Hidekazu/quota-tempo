import CoreFoundation
import Foundation

enum CodeUsageComparisonStatus: String, Sendable {
  case disconnected, preparing, waitingForConnection, waitingForMeasurement
  case comparisonOnly, stale, resetPassed, multipleSessions, unavailable, invalidClock
  case storageUnavailable
}

struct CodeUsageComparisonWindow: Equatable, Sendable {
  let remainingPercent: Double
  let resetAt: Date
}

// Deliberately not a ProviderSnapshot: no identity, provider freshness or plan.
struct CodeUsageComparisonView: Equatable, Sendable {
  let status: CodeUsageComparisonStatus
  let weekly: CodeUsageComparisonWindow?
  let fiveHour: CodeUsageComparisonWindow?
  let receivedAt: Date?

  init(
    status: CodeUsageComparisonStatus,
    weekly: CodeUsageComparisonWindow? = nil,
    fiveHour: CodeUsageComparisonWindow? = nil,
    receivedAt: Date? = nil
  ) {
    self.status = status
    self.weekly = weekly
    self.fiveHour = fiveHour
    self.receivedAt = receivedAt
  }
}

enum CodeComparisonProtocol {
  static let maximumBytes = 16 * 1_024
  static let maximumAge: TimeInterval = 300

  static func uuid(_ value: String) -> Bool {
    value.utf8.count == 36
      && value.range(
        of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
        options: .regularExpression) != nil
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(_ value: Any?) -> Date? {
    guard let value = value as? String,
      value.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
        options: .regularExpression) != nil
    else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: value), timestamp(date) == value else { return nil }
    return date
  }

  static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
    else { return nil }
    return number.doubleValue
  }

  static func keys(_ object: [String: Any], _ keys: Set<String>) -> Bool {
    Set(object.keys) == keys
  }
}

struct CodeComparisonDecoder: Sendable {
  private struct Row: Sendable {
    let kind: String
    let used: Double
    let reset: Date
    let first: Date
    let last: Date
  }

  private let connectionID: String
  private let streamID: String
  private var sequence: Double = 0
  private var clockWatermark = Date.distantPast
  private var lastData: Data?
  private var rows: [Row] = []
  private var view = CodeUsageComparisonView(status: .waitingForMeasurement)
  private static let reasons: Set<String> = [
    "invalid_read_at", "invalid_usage", "invalid_rate_limits", "invalid_limit", "unknown_kind",
    "duplicate_kind", "invalid_percent_used", "missing_reset", "invalid_reset", "expired_reset",
    "getter_failed", "clock_failed", "clock_regressed", "disconnected", "export_failed",
  ]

  init(connectionID: String, streamID: String) {
    self.connectionID = connectionID
    self.streamID = streamID
  }

  mutating func unavailable() -> CodeUsageComparisonView {
    // Keep the replay watermark/text: the same file cannot restore a lost view.
    view = CodeUsageComparisonView(status: .unavailable)
    return view
  }

  mutating func current(now: Date) -> CodeUsageComparisonView {
    guard now.timeIntervalSince1970.isFinite, now >= clockWatermark else {
      view = CodeUsageComparisonView(status: .invalidClock)
      return view
    }
    clockWatermark = now
    return expire(now: now)
  }

  mutating func consume(_ data: Data, now: Date) -> CodeUsageComparisonView {
    guard now.timeIntervalSince1970.isFinite, now >= clockWatermark else {
      view = CodeUsageComparisonView(status: .invalidClock)
      return view
    }
    clockWatermark = now
    if data == lastData {
      return expire(now: now)
    }
    guard data.count > 0, data.count <= CodeComparisonProtocol.maximumBytes,
      CodeComparisonProtocol.uuid(connectionID), CodeComparisonProtocol.uuid(streamID),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      CodeComparisonProtocol.keys(
        object, ["schemaVersion", "connectionID", "streamID", "sequence", "result"]),
      CodeComparisonProtocol.number(object["schemaVersion"]) == 1,
      object["connectionID"] as? String == connectionID,
      object["streamID"] as? String == streamID,
      let nextSequence = CodeComparisonProtocol.number(object["sequence"]),
      nextSequence.rounded(.down) == nextSequence,
      nextSequence > sequence, nextSequence <= 9_007_199_254_740_991,
      let result = object["result"] as? [String: Any],
      CodeComparisonProtocol.keys(
        result, ["schemaVersion", "status", "reason", "readAt", "rateLimits"]),
      CodeComparisonProtocol.number(result["schemaVersion"]) == 1,
      let status = result["status"] as? String,
      let values = result["rateLimits"] as? [[String: Any]]
    else { return unavailable() }

    if status != "valid" {
      guard ["invalid", "unavailable"].contains(status), values.isEmpty,
        let reason = result["reason"] as? String, Self.reasons.contains(reason),
        result["readAt"] is NSNull || CodeComparisonProtocol.date(result["readAt"]) != nil
      else { return unavailable() }
      sequence = nextSequence
      lastData = data
      view = CodeUsageComparisonView(
        status: reason == "disconnected" ? .disconnected : .unavailable)
      return view
    }

    guard result["reason"] is NSNull,
      let read = CodeComparisonProtocol.date(result["readAt"]),
      read <= now.addingTimeInterval(5), (1...2).contains(values.count)
    else { return unavailable() }
    var nextRows: [Row] = []
    for value in values {
      guard
        CodeComparisonProtocol.keys(
          value, ["kind", "percentUsed", "resetsAt", "firstSeenAt", "lastReadAt"]),
        let kind = value["kind"] as? String, ["five_hour", "seven_day"].contains(kind),
        !nextRows.contains(where: { $0.kind == kind }),
        let used = CodeComparisonProtocol.number(value["percentUsed"]), (0...100).contains(used),
        let reset = CodeComparisonProtocol.date(value["resetsAt"]), reset > read,
        reset.timeIntervalSince(read) <= (kind == "seven_day" ? 691_200 : 21_600),
        let first = CodeComparisonProtocol.date(value["firstSeenAt"]), first <= read,
        let last = CodeComparisonProtocol.date(value["lastReadAt"]), last == read
      else { return unavailable() }
      let previous = rows.first { $0.kind == kind && $0.used == used && $0.reset == reset }
      // Even a new sequence cannot make an unchanged tuple young again.
      nextRows.append(
        Row(
          kind: kind, used: used, reset: reset, first: min(previous?.first ?? first, first),
          last: last)
      )
    }
    sequence = nextSequence
    lastData = data
    rows = nextRows
    view = CodeUsageComparisonView(
      status: .comparisonOnly, weekly: window("seven_day"), fiveHour: window("five_hour"),
      receivedAt: read)
    return expire(now: now)
  }

  private func window(_ kind: String) -> CodeUsageComparisonWindow? {
    rows.first(where: { $0.kind == kind }).map {
      CodeUsageComparisonWindow(remainingPercent: 100 - $0.used, resetAt: $0.reset)
    }
  }

  private mutating func expire(now: Date) -> CodeUsageComparisonView {
    guard view.status == .comparisonOnly else { return view }
    if rows.contains(where: {
      now.timeIntervalSince($0.first) > CodeComparisonProtocol.maximumAge
        || now.timeIntervalSince($0.last) > CodeComparisonProtocol.maximumAge
    }) {
      view = CodeUsageComparisonView(status: .stale)
    } else if rows.contains(where: { $0.reset <= now }) {
      view = CodeUsageComparisonView(status: .resetPassed)
    }
    return view
  }
}
