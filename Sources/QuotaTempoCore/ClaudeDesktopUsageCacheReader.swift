import CZstd
import CryptoKit
import Darwin
import Foundation

public struct ClaudeDesktopCacheObservation: Sendable {
  let organizationUUID: String
  let capturedAt: Date
  let weeklyUtilization: Double?
  let weeklyResetAt: Date?
  let fiveHourUtilization: Double?
  let fiveHourResetAt: Date?
}

public protocol ClaudeDesktopUsageCacheReading: Sendable {
  func latest(now: Date, organizationFingerprint: String?) throws -> ClaudeDesktopCacheObservation?
}

struct FileClaudeDesktopUsageCacheReader: ClaudeDesktopUsageCacheReading {
  static let maximumEntrySize = 256 * 1_024
  static let maximumDecodedSize = 128 * 1_024
  static let maximumAge: TimeInterval = 8 * 24 * 60 * 60
  private static let keyPrefixSize = 2_048

  let directory: URL
  private let reader: any BoundedLocalDataReading

  init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data"),
    reader: any BoundedLocalDataReading = FileBoundedLocalDataReader()
  ) {
    self.directory = directory
    self.reader = reader
  }

  func latest(now: Date, organizationFingerprint: String?) throws -> ClaudeDesktopCacheObservation?
  {
    let manager = FileManager.default
    guard !LocalPathSafety.containsSymlink(atOrAbove: directory, fileManager: manager) else {
      throw ClaudeAutomaticAdapterError.unsafePath
    }
    guard
      let files = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return nil }
    let candidates = files.compactMap { url -> (URL, Date)? in
      guard url.lastPathComponent.hasSuffix("_0"),
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]),
        values.isRegularFile == true,
        let size = values.fileSize,
        size > 0 && size <= Self.maximumEntrySize,
        let modifiedAt = values.contentModificationDate,
        modifiedAt <= now.addingTimeInterval(60),
        now.timeIntervalSince(modifiedAt) <= Self.maximumAge
      else { return nil }
      return (url, modifiedAt)
    }.sorted { $0.1 > $1.1 }

    var best: ClaudeDesktopCacheObservation?
    for (url, modifiedAt) in candidates {
      if let best, modifiedAt.addingTimeInterval(60) < best.capturedAt { break }
      guard !LocalPathSafety.containsSymlink(atOrAbove: url, fileManager: manager),
        let head = Self.readKeyPrefix(from: url),
        let organizationUUID = Self.organizationUUID(in: head),
        organizationFingerprint == nil
          || Self.fingerprint(organizationUUID) == organizationFingerprint
      else { continue }
      guard let data = try? reader.read(from: url, limit: Self.maximumEntrySize),
        let observation = Self.parseEntry(data),
        observation.capturedAt <= now.addingTimeInterval(60),
        observation.capturedAt <= modifiedAt.addingTimeInterval(60),
        now.timeIntervalSince(observation.capturedAt) <= Self.maximumAge,
        observation.weeklyResetAt.map({ $0 > now }) == true
          || observation.fiveHourResetAt.map({ $0 > now }) == true
      else { continue }
      if best == nil || observation.capturedAt > best!.capturedAt {
        best = observation
      }
    }
    return best
  }

  static func parseEntry(_ data: Data) -> ClaudeDesktopCacheObservation? {
    guard let streams = cacheStreams(in: data),
      let organizationUUID = organizationUUID(inKey: streams.key),
      let date = responseDate(in: streams.headers),
      let body = decompressBody(streams.body),
      let usage = try? JSONDecoder().decode(UsageBody.self, from: body)
    else { return nil }
    let weekly = usage.sevenDay ?? usage.limits?.first(where: { $0.kind == "weekly_all" })?.window
    let fiveHour = usage.fiveHour ?? usage.limits?.first(where: { $0.kind == "session" })?.window
    guard weekly != nil || fiveHour != nil else { return nil }
    return ClaudeDesktopCacheObservation(
      organizationUUID: organizationUUID,
      capturedAt: date,
      weeklyUtilization: weekly?.utilization,
      weeklyResetAt: weekly?.resetsAt.flatMap(parseISO8601),
      fiveHourUtilization: fiveHour?.utilization,
      fiveHourResetAt: fiveHour?.resetsAt.flatMap(parseISO8601)
    )
  }

  private static func organizationUUID(in head: Data) -> String? {
    guard let key = cacheKey(in: head) else { return nil }
    return organizationUUID(inKey: key)
  }

  private static func organizationUUID(inKey key: Data) -> String? {
    let prefix = "https://claude.ai/api/organizations/"
    let marker = Data(prefix.utf8)
    guard let range = key.range(of: marker),
      range.lowerBound == 0 || range.lowerBound == 4,
      let value = String(data: key[range.lowerBound...], encoding: .utf8),
      value.hasPrefix(prefix)
    else {
      return nil
    }
    let path = value.dropFirst(prefix.count)
    guard let slash = path.firstIndex(of: "/"),
      let uuid = UUID(uuidString: String(path[..<slash])),
      path[slash...] == "/usage" || path[slash...].hasPrefix("/usage?")
    else { return nil }
    return uuid.uuidString.lowercased()
  }

  private static func littleEndian32(in data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return (0..<4).reduce(UInt32(0)) { value, index in
      value | UInt32(data[offset + index]) << (index * 8)
    }
  }

  private static func cacheKey(in data: Data) -> Data? {
    let headerMagic = Data([0x30, 0x5C, 0x72, 0xA7, 0x1B, 0x6D, 0xFB, 0xFC])
    guard data.count >= 24, Data(data.prefix(8)) == headerMagic,
      littleEndian32(in: data, at: 8) == 5,
      let keyLength = littleEndian32(in: data, at: 12), keyLength > 0,
      keyLength <= 2_024,
      24 + Int(keyLength) <= data.count
    else { return nil }
    return Data(data[24..<(24 + Int(keyLength))])
  }

  private static func cacheStreams(in data: Data) -> (
    key: Data, body: Data, headers: Data
  )? {
    let finalMagic = Data([0xD8, 0x41, 0x0D, 0x97, 0x45, 0x6F, 0xFA, 0xF4])
    guard let key = cacheKey(in: data), data.count >= 24 + key.count + 48 else { return nil }
    let eof0 = data.count - 24
    guard Data(data[eof0..<(eof0 + 8)]) == finalMagic,
      let flags = littleEndian32(in: data, at: eof0 + 8),
      let headerCRC = littleEndian32(in: data, at: eof0 + 12),
      let headerSize = littleEndian32(in: data, at: eof0 + 16),
      flags & ~UInt32(3) == 0
    else { return nil }
    let hashSize = flags & 2 == 0 ? 0 : 32
    let headerEnd = eof0 - hashSize
    let headerStart = headerEnd - Int(headerSize)
    let eof1 = headerStart - 24
    let bodyStart = 24 + key.count
    guard eof1 >= bodyStart, headerEnd >= headerStart,
      Data(data[eof1..<(eof1 + 8)]) == finalMagic,
      let bodyFlags = littleEndian32(in: data, at: eof1 + 8),
      let bodyCRC = littleEndian32(in: data, at: eof1 + 12),
      bodyFlags & ~UInt32(1) == 0,
      flags & 1 == 0 || crc32(data[headerStart..<headerEnd]) == headerCRC,
      bodyFlags & 1 == 0 || crc32(data[bodyStart..<eof1]) == bodyCRC,
      flags & 2 == 0
        || Data(SHA256.hash(data: key)) == data[headerEnd..<eof0]
    else { return nil }
    return (
      key,
      Data(data[bodyStart..<eof1]),
      Data(data[headerStart..<headerEnd])
    )
  }

  private static func crc32(_ bytes: Data.SubSequence) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320)
      }
    }
    return ~crc
  }

  private static func fingerprint(_ organizationUUID: String) -> String {
    SHA256.hash(data: Data(organizationUUID.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func readKeyPrefix(from url: URL) -> Data? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_size > 0 && status.st_size <= Self.maximumEntrySize
    else { return nil }
    var bytes = [UInt8](repeating: 0, count: Self.keyPrefixSize)
    let count = bytes.withUnsafeMutableBytes { pointer in
      Darwin.read(descriptor, pointer.baseAddress, pointer.count)
    }
    guard count > 0 else { return nil }
    return Data(bytes.prefix(count))
  }

  private static func responseDate(in headers: Data) -> Date? {
    guard
      let status = ["HTTP/1.1 ", "HTTP/2 "].compactMap({ marker in
        headers.range(of: Data(marker.utf8))
      }).min(by: { $0.lowerBound < $1.lowerBound }),
      headers[status.upperBound..<min(headers.endIndex, status.upperBound + 3)] == Data("200".utf8),
      headers.range(of: Data("HTTP/1.1 ".utf8), in: status.upperBound..<headers.endIndex) == nil,
      headers.range(of: Data("HTTP/2 ".utf8), in: status.upperBound..<headers.endIndex) == nil
    else { return nil }
    let response = Data(headers[status.lowerBound...])
    let lower = Data(response.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
    guard
      hasZstdEncoding(in: lower),
      let date = httpDate(in: response, lower: lower)
    else { return nil }
    return date
  }

  private static func decompressBody(_ body: Data) -> Data? {
    guard body.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) else { return nil }
    return body.withUnsafeBytes { input -> Data? in
      guard let inputPointer = input.baseAddress else { return nil }
      let compressedSize = ZSTD_findFrameCompressedSize(inputPointer, input.count)
      guard ZSTD_isError(compressedSize) == 0,
        compressedSize == input.count
      else { return nil }
      var output = Data(count: Self.maximumDecodedSize)
      let written = output.withUnsafeMutableBytes { buffer in
        ZSTD_decompress(buffer.baseAddress, buffer.count, inputPointer, compressedSize)
      }
      guard ZSTD_isError(written) == 0,
        written > 0 && written <= Self.maximumDecodedSize
      else { return nil }
      output.count = written
      return output
    }
  }

  private static func httpDate(in data: Data, lower: Data) -> Date? {
    for marker in [Data("\0date:".utf8), Data("\ndate:".utf8)] {
      guard let range = lower.range(of: marker),
        let end = data[range.upperBound...].firstIndex(where: { $0 == 0 || $0 == 10 || $0 == 13 }),
        end - range.upperBound <= 48,
        let value = String(data: data[range.upperBound..<end], encoding: .ascii)
      else { continue }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      if let date = formatter.date(from: value.trimmingCharacters(in: .whitespaces)) {
        return date
      }
    }
    return nil
  }

  private static func hasZstdEncoding(in lower: Data) -> Bool {
    for marker in [Data("\0content-encoding:".utf8), Data("\ncontent-encoding:".utf8)] {
      guard let range = lower.range(of: marker),
        let end = lower[range.upperBound...].firstIndex(where: {
          $0 == 0 || $0 == 10 || $0 == 13
        }),
        end - range.upperBound <= 32,
        let value = String(data: lower[range.upperBound..<end], encoding: .ascii)
      else { continue }
      if value.trimmingCharacters(in: .whitespaces) == "zstd" { return true }
    }
    return false
  }

  private static func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

private struct UsageBody: Decodable {
  let sevenDay: UsageRow?
  let fiveHour: UsageRow?
  let limits: [UsageLimit]?

  enum CodingKeys: String, CodingKey {
    case sevenDay = "seven_day"
    case fiveHour = "five_hour"
    case limits
  }
}

private struct UsageLimit: Decodable {
  let kind: String
  let utilization: Double?
  let usedPercentage: Double?
  let resetsAt: String?

  var window: UsageRow {
    UsageRow(utilization: utilization ?? usedPercentage, resetsAt: resetsAt)
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case utilization
    case usedPercentage = "used_percentage"
    case resetsAt = "resets_at"
  }
}

private struct UsageRow: Decodable {
  let utilization: Double?
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }
}
