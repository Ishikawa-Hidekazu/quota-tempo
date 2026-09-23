import Foundation

public enum ClaudeUsageTextParser {
  public struct Result: Equatable, Sendable {
    public let weekly: QuotaWindow?
    public let fiveHour: QuotaWindow?
  }

  public static func parse(_ raw: Data, now: Date) -> Result? {
    let bounded = raw.suffix(256_000)
    let text = String(decoding: bounded, as: UTF8.self)
    let clean = self.stripTerminalSequences(text)
    let lines = clean.components(separatedBy: .newlines)
      .flatMap { $0.components(separatedBy: "\r") }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard
      let start = lines.lastIndex(where: {
        self.normalizedLabel($0).hasPrefix("currentsession")
      })
    else {
      return nil
    }
    let panel = Array(lines[start...].prefix(32))
    guard !panel.contains(where: { self.isFailure($0) }) else { return nil }
    let session = self.window(in: panel, label: "Current session", duration: 5 * 60 * 60, now: now)
    let weekly = self.window(
      in: panel, label: "Current week (all models)", duration: 7 * 24 * 60 * 60, now: now)
    guard session != nil || weekly != nil else { return nil }
    return Result(weekly: weekly, fiveHour: session)
  }

  static func indicatesStaleUsage(_ raw: Data) -> Bool {
    guard raw.count <= 1_048_576, let text = String(data: raw, encoding: .utf8) else {
      return false
    }
    let lines = self.stripTerminalSequences(text).components(separatedBy: .newlines)
    guard
      let start = lines.lastIndex(where: {
        self.normalizedLabel($0).hasPrefix("currentsession")
      })
    else { return false }
    return lines[start...].prefix(32).contains { line in
      let lower = line.lowercased()
      return lower.contains("last known") || lower.contains("rate limited")
        || lower.contains("as of ")
    }
  }

  private static func window(in lines: [String], label: String, duration: TimeInterval, now: Date)
    -> QuotaWindow?
  {
    let target = self.normalizedLabel(label)
    guard
      let index = lines.firstIndex(where: {
        self.normalizedLabel($0).hasPrefix(target)
      })
    else { return nil }
    let section = Array(lines[index..<min(index + 12, lines.count)])
    let end = section.dropFirst().firstIndex(where: { self.isBoundary($0) }) ?? section.endIndex
    let content = section[..<end]
    let percents = content.compactMap(self.usedPercent)
    let resets = content.compactMap { self.resetDate($0, duration: duration, now: now) }
    guard let used = percents.last, let reset = resets.last else { return nil }
    guard reset > now, reset.timeIntervalSince(now) <= duration + 60 else { return nil }
    return QuotaWindow(remainingPercent: 100 - used, durationSeconds: duration, resetAt: reset)
  }

  private static func usedPercent(_ line: String) -> Double? {
    guard
      let match = line.firstMatch(of: /(?:^|[^0-9])(\d{1,3}(?:\.\d+)?)\s*%\s*(?i:used)/)
        ?? line.wholeMatch(of: /\s*(\d{1,3}(?:\.\d+)?)\s*%\s*/),
      let value = Double(match.1), (0...100).contains(value)
    else { return nil }
    return value
  }

  private static func resetDate(_ line: String, duration: TimeInterval, now: Date) -> Date? {
    if let match = line.wholeMatch(
      of:
        /(?i:Resets?)\s+(?:at\s+)?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))/
    ) {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: String(match.1)) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.date(from: String(match.1))
    }

    guard
      let match = line.wholeMatch(
        of:
          /(?i:Resets?)\s*(?:([A-Za-z]{3})\s*(\d{1,2})\s*(?i:at)\s*)?(\d{1,2})(?::(\d{2}))?\s*((?i:AM|PM))\s*(?:\(([A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*)\))?/
      )
    else { return nil }
    let monthName = match.1.map(String.init)
    let day = match.2.flatMap { Int($0) }
    let minute = match.4.flatMap { Int($0) } ?? 0
    guard let rawHour = Int(match.3),
      (1...12).contains(rawHour), (0...59).contains(minute)
    else { return nil }
    let meridiem = String(match.5).uppercased()
    let hour = rawHour % 12 + (meridiem == "PM" ? 12 : 0)
    guard let zone = match.6, let timeZone = TimeZone(identifier: String(zone)) else {
      return nil
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let current = calendar.dateComponents([.year, .month, .day], from: now)
    guard let year = current.year else { return nil }
    let month: Int
    if let monthName {
      guard
        let index = [
          "Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ].firstIndex(
          where: { $0.caseInsensitiveCompare(monthName) == .orderedSame }
        )
      else { return nil }
      month = index + 1
    } else {
      guard duration <= 5 * 60 * 60, let currentMonth = current.month else { return nil }
      month = currentMonth
    }
    let days: [(Int, Int, Int)]
    if let day {
      days = [(year, month, day), (year + 1, month, day)]
    } else {
      guard let currentDay = current.day,
        let midnight = calendar.date(
          from: DateComponents(year: year, month: month, day: currentDay)),
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: midnight)
      else { return nil }
      let next = calendar.dateComponents([.year, .month, .day], from: tomorrow)
      guard let nextYear = next.year, let nextMonth = next.month, let nextDay = next.day else {
        return nil
      }
      days = [(year, month, currentDay), (nextYear, nextMonth, nextDay)]
    }
    return days.compactMap { candidate -> Date? in
      guard
        let date = calendar.date(
          from: DateComponents(
            year: candidate.0, month: candidate.1, day: candidate.2,
            hour: hour, minute: minute
          ))
      else { return nil }
      let verified = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
      guard verified.year == candidate.0, verified.month == candidate.1,
        verified.day == candidate.2, verified.hour == hour, verified.minute == minute
      else { return nil }
      if let dayStart = calendar.date(
        from: DateComponents(year: candidate.0, month: candidate.1, day: candidate.2))
      {
        let searchStart = dayStart.addingTimeInterval(-1)
        let clock = DateComponents(hour: hour, minute: minute)
        let first = calendar.nextDate(
          after: searchStart, matching: clock, matchingPolicy: .strict,
          repeatedTimePolicy: .first)
        let last = calendar.nextDate(
          after: searchStart, matching: clock, matchingPolicy: .strict,
          repeatedTimePolicy: .last)
        guard first == last else { return nil }
      }
      return date
    }.filter { $0 > now && $0.timeIntervalSince(now) <= duration + 60 }.min()
  }

  private static func isBoundary(_ line: String) -> Bool {
    let normalized = self.normalizedLabel(line)
    return normalized.hasPrefix("currentsession")
      || normalized.hasPrefix("currentweek")
      || normalized.hasPrefix("extrausage")
  }

  private static func normalizedLabel(_ line: String) -> String {
    line.lowercased().filter { !$0.isWhitespace }
  }

  private static func isFailure(_ line: String) -> Bool {
    let lower = line.lowercased()
    return lower.contains("loading usage") || lower.contains("failed to load usage")
      || lower.contains("unable to load usage") || lower.contains("error loading usage")
      || lower.contains("last known") || lower.contains("rate limited")
      || lower.contains("as of ")
  }

  static func stripTerminalSequences(_ text: String) -> String {
    var clean = text.replacingOccurrences(
      of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)", with: "",
      options: .regularExpression)
    clean = clean.replacingOccurrences(
      of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    return clean
  }
}
