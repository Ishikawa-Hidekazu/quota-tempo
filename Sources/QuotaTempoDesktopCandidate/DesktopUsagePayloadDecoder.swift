import Foundation
import QuotaTempoCore

struct DesktopUsageValues: Equatable, Sendable {
  let weekly: QuotaWindow
  let fiveHour: QuotaWindow?
}

enum DesktopUsagePayloadError: Error, Equatable {
  case inputTooLarge
  case invalidPayload
  case unavailableWeekly
  case invalidWindow
}

enum DesktopUsagePayloadDecoder {
  static let maximumBytes = 16 * 1_024

  static func decode(_ data: Data, observedAt: Date) throws -> DesktopUsageValues {
    guard data.count <= self.maximumBytes else { throw DesktopUsagePayloadError.inputTooLarge }
    guard String(data: data, encoding: .utf8) != nil else {
      throw DesktopUsagePayloadError.invalidPayload
    }
    guard observedAt.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970 > 0 else {
      throw DesktopUsagePayloadError.invalidWindow
    }

    let payload: Payload
    do {
      payload = try JSONDecoder().decode(Payload.self, from: data)
    } catch let error as DesktopUsagePayloadError {
      throw error
    } catch {
      throw DesktopUsagePayloadError.invalidPayload
    }

    guard
      let weekly = try self.window(
        payload.weekly, observedAt: observedAt, duration: 604_800, maximumFuture: 691_200)
    else { throw DesktopUsagePayloadError.invalidWindow }
    let fiveHour = try payload.fiveHour.flatMap {
      try self.window(
        $0, observedAt: observedAt, duration: 18_000, maximumFuture: 21_600, optional: true)
    }
    return DesktopUsageValues(weekly: weekly, fiveHour: fiveHour)
  }

  private static func window(
    _ input: Window, observedAt: Date, duration: TimeInterval, maximumFuture: TimeInterval,
    optional: Bool = false
  ) throws -> QuotaWindow? {
    guard input.utilization.isFinite, (0...100).contains(input.utilization) else {
      throw DesktopUsagePayloadError.invalidWindow
    }
    guard let reset = input.resetsAt else {
      if optional { return nil }
      throw DesktopUsagePayloadError.invalidWindow
    }
    guard let resetAt = self.parseReset(reset),
      resetAt.timeIntervalSince1970.isFinite, resetAt.timeIntervalSince1970 > 0
    else { throw DesktopUsagePayloadError.invalidWindow }
    let remainingTime = resetAt.timeIntervalSince(observedAt)
    guard remainingTime.isFinite, remainingTime <= maximumFuture else {
      throw DesktopUsagePayloadError.invalidWindow
    }
    // Omit only validated inactive optional windows; never infer a replacement reset.
    guard remainingTime > 0 else {
      if optional { return nil }
      throw DesktopUsagePayloadError.invalidWindow
    }
    return QuotaWindow(
      remainingPercent: 100 - input.utilization, durationSeconds: duration, resetAt: resetAt)
  }

  private static func parseReset(_ value: String) -> Date? {
    // Require an explicit offset and a real calendar date; never normalize an invalid reset.
    let pattern =
      /([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])/
    guard let match = value.wholeMatch(of: pattern) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
      year: Int(match.1), month: Int(match.2), day: Int(match.3),
      hour: Int(match.4), minute: Int(match.5), second: Int(match.6))
    guard let year = components.year, year > 0, components.isValidDate(in: calendar) else {
      return nil
    }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: match.7 != nil).parse(value)
  }

  private struct Payload: Decodable {
    let weekly: Window
    let fiveHour: Window?

    enum CodingKeys: String, CodingKey {
      case weekly = "seven_day"
      case fiveHour = "five_hour"
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      do {
        guard let weekly = try container.decodeIfPresent(Window.self, forKey: .weekly) else {
          throw DesktopUsagePayloadError.unavailableWeekly
        }
        self.weekly = weekly
        self.fiveHour = try container.decodeIfPresent(Window.self, forKey: .fiveHour)
      } catch let error as DesktopUsagePayloadError {
        throw error
      } catch {
        throw DesktopUsagePayloadError.invalidWindow
      }
    }
  }

  private struct Window: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
      case utilization
      case resetsAt = "resets_at"
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.utilization = try container.decode(Double.self, forKey: .utilization)
      // An explicit null is distinguishable from a malformed missing reset key.
      self.resetsAt = try container.decode(String?.self, forKey: .resetsAt)
    }
  }
}
