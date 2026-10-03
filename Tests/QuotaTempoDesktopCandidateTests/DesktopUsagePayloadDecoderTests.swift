import Foundation
import QuotaTempoCore
import Testing

@testable import QuotaTempoDesktopCandidate

@Suite("Desktop candidate usage payload decoding")
struct DesktopUsagePayloadDecoderTests {
  private let now = Date(timeIntervalSince1970: 1_790_726_400)
  private let weeklyReset = "2026-10-06T00:00:00Z"
  private let sessionReset = "2026-09-30T05:00:00Z"

  @Test("Decodes exact weekly and five-hour windows without rounding utilization")
  func exactWindows() throws {
    let values = try self.decode(
      self.payload(
        weekly: self.window(utilization: "12.3456789", reset: self.weeklyReset),
        fiveHour: self.window(utilization: "73.5", reset: self.sessionReset)))
    #expect(abs(values.weekly.remainingPercent - 87.6543211) < 0.000_000_1)
    #expect(values.weekly.durationSeconds == 604_800)
    #expect(values.weekly.resetAt == self.now.addingTimeInterval(6 * 86_400))
    #expect(values.weekly.isResetEstimated == false)
    #expect(values.weekly.resetAtIsEstimated == nil)
    #expect(values.fiveHour?.remainingPercent == 26.5)
    #expect(values.fiveHour?.durationSeconds == 18_000)
    #expect(values.fiveHour?.resetAt == self.now.addingTimeInterval(18_000))
    #expect(values.fiveHour?.isResetEstimated == false)
    #expect(values == DesktopUsageValues(weekly: values.weekly, fiveHour: values.fiveHour))
  }

  @Test("The optional five-hour window may be absent or null", arguments: [nil, "null"])
  func optionalSession(_ fiveHour: String?) throws {
    let result = try self.decode(self.payload(fiveHour: fiveHour))
    #expect(result.fiveHour == nil)
    #expect(result.weekly.remainingPercent == 80)
  }

  @Test(
    "Inactive five-hour windows preserve the exact weekly observation",
    arguments: [
      nil, "2026-09-30T00:00:00Z", "2026-09-29T23:59:59.999Z",
      "2026-09-30T09:00:00+09:00",
    ])
  func inactiveSession(_ reset: String?) throws {
    let weeklyOnly = try self.decode(self.payload())
    for utilization in ["0", "-0", "20.5", "100"] {
      let result = try self.decode(
        self.payload(fiveHour: self.window(utilization: utilization, reset: reset)))
      #expect(result == weeklyOnly)
    }
  }

  @Test("An inactive five-hour window cannot rescue an invalid weekly window")
  func inactiveSessionInvalidWeekly() {
    for sessionReset in [nil, "2026-09-30T00:00:00Z"] {
      let session = self.window(reset: sessionReset)
      self.expectError(.unavailableWeekly, "{\"five_hour\":\(session)}")
      self.expectError(.unavailableWeekly, self.payload(weekly: "null", fiveHour: session))
      for reset in [nil, "2026-09-30T00:00:00Z", "2026-10-08T00:00:00.001Z"] {
        self.expectError(
          .invalidWindow,
          self.payload(weekly: self.window(reset: reset), fiveHour: session))
      }
    }
  }

  @Test(
    "Missing and null weekly windows are unavailable", arguments: ["{}", "{\"seven_day\":null}"])
  func unavailableWeekly(_ payload: String) {
    self.expectError(.unavailableWeekly, payload)
  }

  @Test("Model-specific quotas never substitute for the all-model weekly window")
  func modelWindows() throws {
    let extra = """
      "seven_day_sonnet":{"utilization":99,"resets_at":"2026-10-01T00:00:00Z"},
      "seven_day_opus":{"utilization":null,"resets_at":false},
      "seven_day_oauth_apps":42,
      "extra_usage":{"is_enabled":true,"used_credits":900},
      "future_field":[null,true,{"arbitrary":"value"}]
      """
    let result = try self.decode(self.payload(extra: extra))
    #expect(result.weekly.remainingPercent == 80)
    #expect(result.weekly.resetAt == self.now.addingTimeInterval(6 * 86_400))
    self.expectError(.unavailableWeekly, "{\(extra)}")
  }

  @Test("Unknown fields inside valid windows are ignored")
  func unknownWindowFields() throws {
    let weekly = """
      {"utilization":20,"resets_at":"\(self.weeklyReset)","future":{"utilization":false}}
      """
    #expect(try self.decode(self.payload(weekly: weekly)).weekly.remainingPercent == 80)
  }

  @Test(
    "Usage endpoints and numeric exponent notation are accepted",
    arguments: ["0", "100", "1e2", "-0"])
  func utilizationEndpoints(_ utilization: String) throws {
    let result = try self.decode(
      self.payload(weekly: self.window(utilization: utilization, reset: self.weeklyReset)))
    #expect(result.weekly.remainingPercent == 100 - Double(utilization)!)
  }

  @Test(
    "Invalid utilization is rejected without coercion or clamping",
    arguments: [
      "-0.0001", "100.0001", "true", "false", "\"20\"", "null", "[]", "{}", "\"NaN\"",
      "\"Infinity\"",
    ])
  func invalidUtilization(_ utilization: String) {
    for field in ["seven_day", "five_hour"] {
      let invalid = self.window(utilization: utilization, reset: self.sessionReset)
      let payload =
        field == "seven_day" ? self.payload(weekly: invalid) : self.payload(fiveHour: invalid)
      self.expectError(.invalidWindow, payload)
    }
    for reset in [nil, "2026-09-30T00:00:00Z", "2026-09-29T23:59:59Z"] {
      self.expectError(
        .invalidWindow, self.payload(fiveHour: self.window(utilization: utilization, reset: reset)))
    }
  }

  @Test("Missing utilization is rejected")
  func missingUtilization() {
    self.expectError(
      .invalidWindow, self.payload(weekly: "{\"resets_at\":\"\(self.weeklyReset)\"}"))
    for reset in ["null", "\"\(self.sessionReset)\"", "\"2026-09-30T00:00:00Z\""] {
      self.expectError(.invalidWindow, self.payload(fiveHour: "{\"resets_at\":\(reset)}"))
    }
  }

  @Test(
    "Present malformed windows fail the entire payload",
    arguments: ["false", "true", "20", "\"window\"", "[]", "{}"])
  func malformedWindow(_ window: String) {
    self.expectError(.invalidWindow, self.payload(weekly: window))
    self.expectError(.invalidWindow, self.payload(fiveHour: window))
  }

  @Test(
    "Reset keys must be present and only optional five-hour resets may be null",
    arguments: [nil, "null", "true", "false", "42", "[]", "{}"])
  func resetTypes(_ reset: String?) {
    let suffix = reset.map { ",\"resets_at\":\($0)" } ?? ""
    let window = "{\"utilization\":20\(suffix)}"
    self.expectError(.invalidWindow, self.payload(weekly: window))
    if reset != "null" {
      self.expectError(.invalidWindow, self.payload(fiveHour: window))
    }
  }

  @Test(
    "Ambiguous and malformed reset dates are not inferred",
    arguments: [
      "", "tomorrow", "2026-10-01", "2026-10-01T00:00:00", "2026-10-01 00:00:00Z",
      "2026-10-01T00:00:00Zextra", "2026-10-01T00:00:00Z\n", " 2026-10-01T00:00:00Z",
      "2026-10-01T00:00:00.Z", "2026-10-01T00:00:00.1234567890Z",
      "2026-09-31T00:00:00Z", "2026-10-00T00:00:00Z", "2026-13-01T00:00:00Z",
      "2026-10-01T24:00:00Z", "2026-10-01T00:60:00Z", "2026-10-01T00:00:60Z",
      "2026-10-01T00:00:00+24:00", "2026-10-01T00:00:00+09:60",
      "2026-10-01T00:00:00+0900", "2026-10-01T00:00:00+09",
      "26-10-01T00:00:00Z", "+002026-10-01T00:00:00Z", "2026-W40-4T00:00:00Z",
      "2026-274T00:00:00Z", "2026-10-01t00:00:00z",
      "2026-02-30T00:00:00Z", "2026-09-29T24:00:00Z", "2026-09-29T23:59:59",
    ])
  func invalidDates(_ reset: String) {
    self.expectError(.invalidWindow, self.payload(weekly: self.window(reset: reset)))
    self.expectError(.invalidWindow, self.payload(fiveHour: self.window(reset: reset)))
  }

  @Test("Fractional reset precision is preserved", arguments: ["1", "123", "123456", "123456789"])
  func fractionalSeconds(_ fraction: String) throws {
    let result = try self.decode(
      self.payload(weekly: self.window(reset: "2026-10-01T00:00:00.\(fraction)Z")))
    let reset = try #require(result.weekly.resetAt)
    let expected = self.now.addingTimeInterval(86_400 + Double("0.\(fraction)")!)
    #expect(abs(reset.timeIntervalSince(expected)) <= 0.000_001)
  }

  @Test(
    "Explicit offsets are normalized to the same instant",
    arguments: [
      "2026-10-01T09:00:00+09:00", "2026-09-30T17:00:00-07:00", "2026-10-01T00:00:00+00:00",
      "2026-10-01T05:45:00+05:45", "2026-09-30T20:30:00-03:30",
    ])
  func timeZones(_ reset: String) throws {
    let result = try self.decode(self.payload(weekly: self.window(reset: reset)))
    #expect(result.weekly.resetAt == self.now.addingTimeInterval(86_400))
  }

  @Test("Explicit year and offset survive a year boundary without inference")
  func yearBoundary() throws {
    let observedAt = ISO8601DateFormatter().date(from: "2026-12-30T00:00:00Z")!
    let expected = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
    for reset in ["2027-01-01T00:00:00Z", "2026-12-31T20:30:00-03:30"] {
      let result = try DesktopUsagePayloadDecoder.decode(
        Data(self.payload(weekly: self.window(reset: reset)).utf8), observedAt: observedAt)
      #expect(result.weekly.resetAt == expected)
      #expect(!result.weekly.isResetEstimated)
    }
  }

  @Test("The weekly future bound is inclusive and does not alter duration")
  func weeklyFutureBoundary() throws {
    let result = try self.decode(self.payload(weekly: self.window(reset: "2026-10-08T00:00:00Z")))
    #expect(result.weekly.resetAt == self.now.addingTimeInterval(691_200))
    #expect(result.weekly.durationSeconds == 604_800)
    self.expectError(
      .invalidWindow, self.payload(weekly: self.window(reset: "2026-10-08T00:00:00.001Z")))
    self.expectError(
      .invalidWindow, self.payload(weekly: self.window(reset: "2026-10-09T00:00:00Z")))
  }

  @Test("The five-hour future bound is inclusive and does not alter duration")
  func fiveHourFutureBoundary() throws {
    let result = try self.decode(self.payload(fiveHour: self.window(reset: "2026-09-30T06:00:00Z")))
    #expect(result.fiveHour?.resetAt == self.now.addingTimeInterval(21_600))
    #expect(result.fiveHour?.durationSeconds == 18_000)
    self.expectError(
      .invalidWindow, self.payload(fiveHour: self.window(reset: "2026-09-30T06:00:00.001Z")))
    self.expectError(
      .invalidWindow, self.payload(fiveHour: self.window(reset: "2026-09-30T07:00:00Z")))
  }

  @Test(
    "Equal and past weekly reset times are still rejected",
    arguments: ["2026-09-30T00:00:00Z", "2026-09-29T23:59:59.999Z"])
  func expiredResets(_ reset: String) {
    self.expectError(.invalidWindow, self.payload(weekly: self.window(reset: reset)))
  }

  @Test("Five-hour rollover omits inactive windows and never infers a replacement reset")
  func sessionRollover() throws {
    let weekly = try self.decode(self.payload()).weekly
    for (offset, reset, active) in [
      (-0.001, "2026-09-30T00:00:00Z", true),
      (0.0, "2026-09-30T00:00:00Z", false),
      (23.0, "2026-09-30T00:00:00Z", false),
      (300.0, "2026-09-30T05:00:00Z", true),
    ] {
      let observedAt = self.now.addingTimeInterval(offset)
      let result = try DesktopUsagePayloadDecoder.decode(
        Data(self.payload(fiveHour: self.window(reset: reset)).utf8), observedAt: observedAt)
      #expect(result.weekly == weekly)
      if active {
        #expect(result.fiveHour?.resetAt == ISO8601DateFormatter().date(from: reset))
        #expect(result.fiveHour?.isResetEstimated == false)
      } else {
        #expect(result.fiveHour == nil)
      }
    }
  }

  @Test("A future reset one millisecond away remains exact")
  func immediateFutureReset() throws {
    let window = self.window(reset: "2026-09-30T00:00:00.001Z")
    let result = try self.decode(self.payload(weekly: window, fiveHour: window))
    #expect(try #require(result.weekly.resetAt) > self.now)
    #expect(result.fiveHour?.resetAt == result.weekly.resetAt)
  }

  @Test(
    "Observation time must be finite and positive",
    arguments: [Double.nan, .infinity, -.infinity, 0, -1])
  func invalidObservationDates(_ seconds: Double) {
    #expect(throws: DesktopUsagePayloadError.invalidWindow) {
      try DesktopUsagePayloadDecoder.decode(
        Data(self.payload().utf8), observedAt: Date(timeIntervalSince1970: seconds))
    }
  }

  @Test("Nonpositive reset timestamps are rejected")
  func nonpositiveReset() {
    for reset in ["1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "0000-01-01T00:00:00Z"] {
      self.expectError(.invalidWindow, self.payload(weekly: self.window(reset: reset)))
      self.expectError(.invalidWindow, self.payload(fiveHour: self.window(reset: reset)))
    }
  }

  @Test("Invalid calendar dates are rejected while leap day is accepted")
  func leapDays() throws {
    let leapNow = ISO8601DateFormatter().date(from: "2028-02-28T00:00:00Z")!
    let valid = try DesktopUsagePayloadDecoder.decode(
      Data(self.payload(weekly: self.window(reset: "2028-02-29T00:00:00Z")).utf8),
      observedAt: leapNow)
    #expect(valid.weekly.resetAt == leapNow.addingTimeInterval(86_400))
    let ordinaryNow = ISO8601DateFormatter().date(from: "2027-02-28T00:00:00Z")!
    #expect(throws: DesktopUsagePayloadError.invalidWindow) {
      try DesktopUsagePayloadDecoder.decode(
        Data(self.payload(weekly: self.window(reset: "2027-02-29T00:00:00Z")).utf8),
        observedAt: ordinaryNow)
    }
  }

  @Test(
    "Non-object and malformed JSON return a stable payload error",
    arguments: ["", "null", "true", "42", "\"text\"", "[]", "{", "{\"seven_day\":", "{} {}"])
  func malformedJSON(_ payload: String) {
    self.expectError(.invalidPayload, payload)
  }

  @Test("Bounded unknown nesting is ignored without changing weekly values")
  func unknownNesting() throws {
    let nested = String(repeating: "[", count: 32) + "null" + String(repeating: "]", count: 32)
    let result = try self.decode(self.payload(extra: "\"nested\":\(nested)"))
    #expect(result.weekly.remainingPercent == 80)
    #expect(result.weekly.resetAt == self.now.addingTimeInterval(6 * 86_400))
  }

  @Test("Excessively deep JSON is rejected within the byte limit")
  func excessiveNesting() {
    let nested =
      String(repeating: "[", count: 2_048) + "null" + String(repeating: "]", count: 2_048)
    let payload = self.payload(extra: "\"nested\":\(nested)")
    #expect(payload.utf8.count < DesktopUsagePayloadDecoder.maximumBytes)
    self.expectError(.invalidPayload, payload)
  }

  @Test("Malformed nested JSON never yields a partial weekly observation")
  func malformedNesting() {
    let nested = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 127)
    self.expectError(.invalidPayload, self.payload(extra: "\"nested\":\(nested)"))
  }

  @Test("Malformed and oversized inputs preserve bounded error precedence")
  func malformedSizeBoundary() {
    var data = Data("{\"unclosed\":\"".utf8)
    data.append(Data(repeating: 0x78, count: DesktopUsagePayloadDecoder.maximumBytes - data.count))
    #expect(throws: DesktopUsagePayloadError.invalidPayload) {
      try DesktopUsagePayloadDecoder.decode(data, observedAt: self.now)
    }
    data.append(0xFF)
    #expect(throws: DesktopUsagePayloadError.inputTooLarge) {
      try DesktopUsagePayloadDecoder.decode(data, observedAt: self.now)
    }
  }

  @Test("Non-JSON nonfinite number literals are rejected")
  func nonfiniteLiterals() {
    for number in ["NaN", "Infinity", "-Infinity", "1e400"] {
      for payload in [
        self.payload(weekly: self.window(utilization: number, reset: self.weeklyReset)),
        self.payload(fiveHour: self.window(utilization: number, reset: nil)),
        self.payload(fiveHour: self.window(utilization: number, reset: "2026-09-30T00:00:00Z")),
      ] {
        do {
          _ = try self.decode(payload)
          Issue.record("Expected a bounded validation error")
        } catch {
          let error = error as? DesktopUsagePayloadError
          #expect(error == .invalidPayload || error == .invalidWindow)
        }
      }
    }
  }

  @Test("Malformed UTF-8 and UTF-16 payloads are rejected")
  func invalidEncoding() {
    var malformed = Data(self.payload().utf8)
    malformed.append(contentsOf: [0xC3, 0x28])
    for bytes in [
      malformed, Data([0xFF]), Data([0xEF, 0xBB]), self.payload().data(using: .utf16)!,
    ] {
      #expect(throws: DesktopUsagePayloadError.invalidPayload) {
        try DesktopUsagePayloadDecoder.decode(bytes, observedAt: self.now)
      }
    }
  }

  @Test("Valid multibyte UTF-8 in ignored fields is accepted")
  func validUnicode() throws {
    let result = try self.decode(
      self.payload(extra: "\"label\":\"\u{65E5}\u{672C}\u{8A9E}\u{1F600}\""))
    #expect(result.weekly.remainingPercent == 80)
  }

  @Test("Input limit counts bytes and accepts exactly sixteen KiB")
  func sizeBoundary() throws {
    let limit = DesktopUsagePayloadDecoder.maximumBytes
    #expect(limit == 16 * 1_024)
    var data = Data(self.payload().utf8)
    data.append(Data(repeating: 0x20, count: limit - data.count))
    #expect(
      try DesktopUsagePayloadDecoder.decode(data, observedAt: self.now).weekly.remainingPercent
        == 80)
    data.append(0x20)
    #expect(throws: DesktopUsagePayloadError.inputTooLarge) {
      try DesktopUsagePayloadDecoder.decode(data, observedAt: self.now)
    }
    let multibyte = self.payload(
      extra: "\"padding\":\"\(String(repeating: "\u{65E5}", count: 6_000))\"")
    #expect(multibyte.count < limit)
    #expect(multibyte.utf8.count > limit)
    self.expectError(.inputTooLarge, multibyte)
  }

  @Test("Errors never expose raw payload data")
  func boundedErrors() {
    let marker = "synthetic-private-marker"
    do {
      _ = try self.decode(self.payload(weekly: self.window(reset: marker)))
      Issue.record("Expected a validation error")
    } catch {
      #expect(error as? DesktopUsagePayloadError == .invalidWindow)
      #expect(String(describing: error) == "invalidWindow")
      #expect(!String(reflecting: error).contains(marker))
    }
  }

  private func decode(_ payload: String) throws -> DesktopUsageValues {
    try DesktopUsagePayloadDecoder.decode(Data(payload.utf8), observedAt: self.now)
  }

  private func expectError(_ error: DesktopUsagePayloadError, _ payload: String) {
    #expect(throws: error) { try self.decode(payload) }
  }

  private func window(utilization: String = "20", reset: String?) -> String {
    let quotedReset = String(decoding: try! JSONEncoder().encode(reset), as: UTF8.self)
    return "{\"utilization\":\(utilization),\"resets_at\":\(quotedReset)}"
  }

  private func payload(weekly: String? = nil, fiveHour: String? = nil, extra: String? = nil)
    -> String
  {
    var fields = ["\"seven_day\":\(weekly ?? self.window(reset: self.weeklyReset))"]
    if let fiveHour { fields.append("\"five_hour\":\(fiveHour)") }
    if let extra { fields.append(extra) }
    return "{\(fields.joined(separator: ","))}"
  }
}
