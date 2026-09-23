import Foundation
import Testing

@testable import QuotaTempoCore

@Suite("Claude /usage text parsing")
struct ClaudeUsageTextParserTests {
  private let now = ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z")!

  @Test("Parses explicitly dated windows without mixing model-scoped quotas")
  func exactWindows() {
    let result = self.parse(
      """
      Usage
      Current session
      35% used
      Resets 2026-09-22T03:00:00Z
      Current week (all models)
      41% used
      Resets 2026-09-25T05:00:00Z
      Current week (Sonnet)
      95% used
      Resets 2026-09-23T05:00:00Z
      """)
    #expect(result?.fiveHour?.remainingPercent == 65)
    #expect(result?.weekly?.remainingPercent == 59)
    #expect(result?.weekly?.durationSeconds == 604_800)
    #expect(result?.weekly?.resetAt == ISO8601DateFormatter().date(from: "2026-09-25T05:00:00Z"))
    #expect(result?.weekly?.isResetEstimated == false)
  }

  @Test("ANSI color and cursor controls do not change parsed values")
  func ansi() {
    let result = self.parse(
      "\u{001B}[32mCurrent session\u{001B}[0m\n20%\nResets 2026-09-22T02:00:00+00:00")
    #expect(result?.fiveHour?.remainingPercent == 80)
  }

  @Test("Only the latest panel is considered")
  func latestPanel() {
    let result = self.parse(
      """
      Current session
      20% used
      Resets 2026-09-22T02:00:00Z
      Current week (all models)
      30% used
      Resets 2026-09-25T05:00:00Z
      Current session
      50% used
      Resets 2026-09-22T04:00:00Z
      """)
    #expect(result?.fiveHour?.remainingPercent == 50)
    #expect(result?.weekly == nil)
  }

  @Test("Loading or error after a complete old panel is not accepted")
  func loadingAndErrors() {
    let old = "Current session\n20% used\nResets 2026-09-22T02:00:00Z\n"
    #expect(self.parse(old + "Loading usage data...") == nil)
    #expect(self.parse(old + "Failed to load usage data") == nil)
    #expect(self.parse("Loading usage data...") == nil)
    #expect(self.parse(old + "Rate limited; showing last known usage as of 10:00") == nil)
  }

  @Test("Yearless, relative, timezone-free, and missing resets are not exact")
  func ambiguousDates() {
    for reset in ["Resets Sep 22 at 5am", "Resets in 3 hours", "Resets 2026-09-22 05:00", ""] {
      #expect(self.parse("Current session\n20% used\n\(reset)") == nil)
    }
  }

  @Test("CLI redraw with compact labels and timezone resolves only the matching windows")
  func compactRenderedPanel() {
    let result = self.parse(
      """
      Currentsession
      ████ 20%used
      Resets11am(Asia/Tokyo)
      Currentweek(allmodels)
      █████ 45%used
      ResetsSep25at5am(Asia/Tokyo)
      Current week (Fable)
      ███████ 95% used
      Resets Sep 23 at 5am (Asia/Tokyo)
      """)
    #expect(result?.fiveHour?.remainingPercent == 80)
    #expect(result?.fiveHour?.resetAt == ISO8601DateFormatter().date(from: "2026-09-22T02:00:00Z"))
    #expect(result?.weekly?.remainingPercent == 55)
    #expect(result?.weekly?.resetAt == ISO8601DateFormatter().date(from: "2026-09-24T20:00:00Z"))
  }

  @Test("Three-part IANA timezone identifiers are parsed")
  func multipartTimezone() {
    let result = self.parse(
      """
      Current session
      20% used
      Resets Sep 21 at 10pm (America/Argentina/Buenos_Aires)
      Current week (all models)
      45% used
      Resets Sep 25 at 5am (America/Argentina/Buenos_Aires)
      """)
    #expect(result?.fiveHour?.remainingPercent == 80)
    #expect(result?.weekly?.remainingPercent == 55)
  }

  @Test("Hyphenated and Etc IANA timezone identifiers are parsed")
  func symbolicTimezone() {
    let hyphenated = self.parse(
      "Current session\n20% used\nResets Sep 21 at 11pm (America/Port-au-Prince)")
    #expect(hyphenated?.fiveHour?.remainingPercent == 80)
    let etc = self.parse(
      "Current session\n20% used\nResets Sep 21 at 7pm (Etc/GMT+9)")
    #expect(etc?.fiveHour?.remainingPercent == 80)
  }

  @Test("Only the final 256 KB of a bounded PTY capture is parsed")
  func largeCaptureTail() {
    let prefix = Data(repeating: UInt8(ascii: "x"), count: 300_000)
    let panel = Data(
      "\nCurrent session\n20% used\nResets 2026-09-22T02:00:00Z".utf8)
    let result = ClaudeUsageTextParser.parse(prefix + panel, now: self.now)
    #expect(result?.fiveHour?.remainingPercent == 80)
  }

  @Test("A multibyte character split at the tail boundary does not discard the panel")
  func multibyteTailBoundary() {
    var prefix = Data(repeating: UInt8(ascii: "x"), count: 300_000)
    prefix.append(Data("羊".utf8))
    let panel = Data("\nCurrent session\n20% used\nResets 2026-09-22T02:00:00Z".utf8)
    let targetCount = 256_001
    let padding = targetCount - panel.count
    let data = prefix.suffix(padding) + panel
    let result = ClaudeUsageTextParser.parse(data, now: self.now)
    #expect(result?.fiveHour?.remainingPercent == 80)
  }

  @Test("Yearless weekly reset crosses December without guessing beyond the current window")
  func yearBoundary() {
    let now = ISO8601DateFormatter().date(from: "2026-12-30T00:00:00Z")!
    let output = Data(
      """
      Currentsession
      20%used
      Resets11am(Asia/Tokyo)
      Currentweek(allmodels)
      45%used
      ResetsJan2at5am(Asia/Tokyo)
      """.utf8)
    let result = ClaudeUsageTextParser.parse(output, now: now)
    #expect(result?.weekly?.resetAt == ISO8601DateFormatter().date(from: "2027-01-01T20:00:00Z"))
  }

  @Test("Ambiguous daylight-saving reset time is not presented as exact")
  func ambiguousDST() {
    let now = ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z")!
    let output = Data(
      """
      Currentsession
      20%used
      Resets5pm(America/Los_Angeles)
      Currentweek(allmodels)
      45%used
      ResetsNov1at1:30am(America/Los_Angeles)
      """.utf8)
    let result = ClaudeUsageTextParser.parse(output, now: now)
    #expect(result?.weekly == nil)
  }

  @Test("Malformed percentages and expired or implausibly distant resets are rejected")
  func invalidValues() {
    #expect(self.parse("Current session\n120% used\nResets 2026-09-22T02:00:00Z") == nil)
    #expect(self.parse("Current session\n1200% used\nResets 2026-09-22T02:00:00Z") == nil)
    #expect(self.parse("Current session\n20% used\nResets 2026-09-21T02:00:00Z") == nil)
    #expect(self.parse("Current session\n20% used\nResets 2026-09-25T02:00:00Z") == nil)
  }

  @Test("A valid weekly window can be returned without session data")
  func weeklyOnly() {
    let result = self.parse(
      "Current session\nCurrent week (all models)\n45% used\nResets 2026-09-25T05:00:00Z")
    #expect(result?.fiveHour == nil)
    #expect(result?.weekly?.remainingPercent == 55)
  }

  private func parse(_ text: String) -> ClaudeUsageTextParser.Result? {
    ClaudeUsageTextParser.parse(Data(text.utf8), now: self.now)
  }
}
