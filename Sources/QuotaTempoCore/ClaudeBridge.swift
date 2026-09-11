import Foundation

public enum ClaudeBridgeError: Error, Equatable {
  case invalidInput
  case noRateLimitWindow
  case inputTooLarge

  public var stableCode: String {
    switch self {
    case .invalidInput: "invalid_input"
    case .noRateLimitWindow: "no_rate_limit_window"
    case .inputTooLarge: "input_too_large"
    }
  }
}

public enum ClaudeStatusLineBridge {
  public static let maximumInputBytes = 262_144

  public static func normalize(_ data: Data, receivedAt: Date) throws -> ProviderSnapshot {
    guard data.count <= self.maximumInputBytes else { throw ClaudeBridgeError.inputTooLarge }
    let input: ClaudeStatusInput
    do { input = try JSONDecoder().decode(ClaudeStatusInput.self, from: data) } catch {
      throw ClaudeBridgeError.invalidInput
    }
    guard let limits = input.rateLimits else { throw ClaudeBridgeError.noRateLimitWindow }
    let weekly = try self.window(limits.sevenDay, duration: 7 * 24 * 60 * 60)
    let fiveHour = try self.window(limits.fiveHour, duration: 5 * 60 * 60)
    guard weekly != nil || fiveHour != nil else { throw ClaudeBridgeError.noRateLimitWindow }
    return ProviderSnapshot(
      provider: .claude,
      source: .claudeStatusLine,
      capturedAt: receivedAt,
      weekly: weekly,
      fiveHour: fiveHour,
      sourceState: .observationSucceeded
    )
  }

  private static func window(_ input: ClaudeWindow?, duration: TimeInterval) throws -> QuotaWindow?
  {
    guard let input else { return nil }
    guard input.usedPercentage.isFinite, (0...100).contains(input.usedPercentage),
      input.resetsAt.isFinite, input.resetsAt > 0
    else { throw ClaudeBridgeError.invalidInput }
    return QuotaWindow(
      remainingPercent: 100 - input.usedPercentage,
      durationSeconds: duration,
      resetAt: Date(timeIntervalSince1970: input.resetsAt)
    )
  }
}

public enum BoundedInputReader {
  public static func read(
    from handle: FileHandle,
    limit: Int,
    chunkSize: Int = 64 * 1_024
  ) throws -> Data {
    guard limit >= 0, chunkSize > 0 else { throw ClaudeBridgeError.invalidInput }
    var result = Data()
    while result.count <= limit {
      let remaining = limit + 1 - result.count
      let next = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
      if next.isEmpty { break }
      result.append(next)
    }
    guard result.count <= limit else { throw ClaudeBridgeError.inputTooLarge }
    return result
  }
}

private struct ClaudeStatusInput: Decodable {
  let rateLimits: ClaudeRateLimits?
  enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
}

private struct ClaudeRateLimits: Decodable {
  let fiveHour: ClaudeWindow?
  let sevenDay: ClaudeWindow?
  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
  }
}

private struct ClaudeWindow: Decodable {
  let usedPercentage: Double
  let resetsAt: Double
  enum CodingKeys: String, CodingKey {
    case usedPercentage = "used_percentage"
    case resetsAt = "resets_at"
  }
}
