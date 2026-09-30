import CryptoKit
import Foundation

private struct DesktopConfig: Decodable {
  let account: String
  let cache: String

  enum CodingKeys: String, CodingKey {
    case account = "lastKnownAccountUuid"
    case cacheV2 = "oauth:tokenCacheV2"
    case cacheV1 = "oauth:tokenCache"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    account = try container.decode(String.self, forKey: .account)
    // V2 presence, including a deletion marker, must never resurrect V1.
    cache = try container.decode(
      String.self, forKey: container.contains(.cacheV2) ? .cacheV2 : .cacheV1)
  }
}

struct DesktopSelectedCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let owner: DesktopUsageOwner
  let expiresAt: Date
  fileprivate let token: Data

  var description: String { "DesktopSelectedCredential(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }

  func lease(generation: UUID) throws -> DesktopCredentialLease {
    try DesktopCredentialLease(
      context: DesktopUsageContext(
        owner: owner, generation: generation, expiresAt: expiresAt, hasProfileScope: true),
      token: token)
  }
}

enum DesktopCredentialSelector {
  private struct Rank: Comparable {
    let productionFullScope: Int
    let fullScope: Int
    let scopeCount: Int
    let expiresAt: Date

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.productionFullScope, lhs.fullScope, lhs.scopeCount, lhs.expiresAt)
        < (rhs.productionFullScope, rhs.fullScope, rhs.scopeCount, rhs.expiresAt)
    }
  }

  private struct Entry: Decodable {
    let token: String
    let expiresAt: Double
  }

  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  private struct Cache: Decodable {
    let container: KeyedDecodingContainer<Key>
    init(from decoder: any Decoder) throws { container = try decoder.container(keyedBy: Key.self) }
  }

  static func select(_ plaintext: Data, account: String, organization: String, now: Date) throws
    -> DesktopSelectedCredential
  {
    guard plaintext.count <= DesktopSafeStorage.maximumCacheBytes,
      now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0
    else { throw DesktopCredentialError.invalidStore }
    let account = try DesktopIdentity.canonicalUUID(account)
    let organization = try DesktopIdentity.canonicalUUID(organization)
    let owner = try DesktopIdentity.owner(account: account, organization: organization)
    guard let cache = try? JSONDecoder().decode(Cache.self, from: plaintext),
      cache.container.allKeys.count <= 128
    else {
      throw DesktopCredentialError.invalidStore
    }
    var candidates: [(credential: DesktopSelectedCredential, rank: Rank)] = []
    var sawExpired = false
    for key in cache.container.allKeys {
      guard let identity = parseKey(key.stringValue), identity.account == account,
        identity.organization == organization, identity.scopes.contains("user:profile")
      else { continue }
      if (try? cache.container.decodeNil(forKey: key)) == true { continue }
      guard let entry = try? cache.container.decode(Entry.self, forKey: key),
        entry.expiresAt.isFinite, entry.expiresAt > 0
      else { throw DesktopCredentialError.invalidStore }
      // Both published cache versions have appeared with epoch seconds or milliseconds.
      let seconds = entry.expiresAt > 10_000_000_000 ? entry.expiresAt / 1000 : entry.expiresAt
      let expiry = Date(timeIntervalSince1970: seconds)
      guard expiry.timeIntervalSince(now) > 120 else {
        sawExpired = true
        continue
      }
      let token = Data(entry.token.utf8)
      guard !token.isEmpty, token.count <= 8192, token.allSatisfy({ (33...126).contains($0) })
      else {
        throw DesktopCredentialError.invalidStore
      }
      let fullScope = identity.scopes.contains("user:inference")
      candidates.append(
        (
          DesktopSelectedCredential(owner: owner, expiresAt: expiry, token: token),
          Rank(
            productionFullScope: identity.client == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
              && fullScope ? 1 : 0,
            fullScope: fullScope ? 1 : 0, scopeCount: identity.scopes.count, expiresAt: expiry)
        ))
    }
    guard let best = candidates.map(\.rank).max() else {
      throw sawExpired ? DesktopCredentialError.expired : .identityUnavailable
    }
    // Rank only after exact account/org/audience/scope admission. Prefer Desktop's
    // production full-scope login, then full scopes, scope richness, and finally
    // expiry. Never resolve an equal-ranked conflict by dictionary iteration.
    let eligible = candidates.filter { $0.rank == best }
    let first = eligible[0].credential
    guard
      eligible.allSatisfy({
        $0.credential.token == first.token && $0.credential.expiresAt == first.expiresAt
      })
    else {
      throw DesktopCredentialError.ambiguousIdentity
    }
    return first
  }

  private static func parseKey(_ value: String) -> (
    account: String, organization: String, client: String, scopes: Set<String>
  )? {
    guard value.utf8.count <= 2048, value.hasPrefix("acct:"),
      let bar = value.firstIndex(of: "|")
    else { return nil }
    let account = String(value[value.index(value.startIndex, offsetBy: 5)..<bar])
    let rest = value[value.index(after: bar)...]
    let marker = ":https://api.anthropic.com:"
    guard let boundary = rest.range(of: marker) else { return nil }
    let fields = rest[..<boundary.lowerBound].split(
      separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 2,
      let account = try? DesktopIdentity.canonicalUUID(account),
      let client = try? DesktopIdentity.canonicalUUID(String(fields[0])),
      let organization = try? DesktopIdentity.canonicalUUID(String(fields[1]))
    else { return nil }
    var scopeText = String(rest[boundary.upperBound...])
    if scopeText.hasSuffix(":") { scopeText.removeLast() }
    let scopes = Set(scopeText.split(whereSeparator: \.isWhitespace).map(String.init))
    return (account, organization, client, scopes)
  }
}

actor DesktopCredentialReader {
  enum FailureStage: String, Sendable {
    case configuration, keychain, organization, decryption, selection, revalidation
  }

  // In-memory comparison only: consent withdrawal discards the usable lease,
  // not the identity of an unchanged credential already refused by the provider.
  private struct CredentialRevision: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
  {
    let context: DesktopUsageContext
    private let tokenDigest: SHA256.Digest

    init(_ credential: DesktopSelectedCredential, context: DesktopUsageContext) {
      self.context = context
      tokenDigest = SHA256.hash(data: credential.token)
    }

    func matches(_ credential: DesktopSelectedCredential) -> Bool {
      context.owner == credential.owner && context.expiresAt == credential.expiresAt
        && tokenDigest == SHA256.hash(data: credential.token)
    }

    var description: String { "CredentialRevision(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
  }

  private(set) var lastFailureStage: FailureStage?
  private let directory: URL
  private let keyReader: @Sendable () throws -> Data
  private var approval = DesktopAccessApproval()
  private var permissionRefused = false
  private var previous: DesktopCredentialLease?
  private var lastRevision: CredentialRevision?
  private var previousStamp: DesktopFileStamp?
  private var previousOrganization: DesktopOrganizationSelection?

  init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/Claude"),
    keyReader: @escaping @Sendable () throws -> Data = DesktopSafeStorage.readKeyWithoutInteraction
  ) {
    self.directory = directory
    self.keyReader = keyReader
  }

  func setApproval(_ approval: DesktopAccessApproval) {
    self.approval = approval
    permissionRefused = false
    lastFailureStage = nil
    invalidate()
  }

  func load(now: Date) throws -> DesktopCredentialLease {
    try approval.requireAccess()
    guard !permissionRefused else { throw DesktopCredentialError.permissionRequired }
    var stage = FailureStage.configuration
    lastFailureStage = nil
    do {
      let url = directory.appendingPathComponent("config.json")
      let file = try DesktopProtectedFile.read(url, maximumBytes: 4 * 1_048_576)
      guard let config = try? JSONDecoder().decode(DesktopConfig.self, from: file.data),
        config.cache.utf8.count <= 2 * DesktopSafeStorage.maximumCacheBytes,
        let encrypted = Data(base64Encoded: config.cache)
      else { throw DesktopCredentialError.invalidStore }
      _ = try DesktopIdentity.canonicalUUID(config.account)
      stage = .keychain
      var key = try keyReader()
      defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
      stage = .organization
      let organization = try DesktopOrganizationReader.read(directory: directory) {
        try DesktopSafeStorage.decrypt($0, key: key)
      }
      stage = .decryption
      var plaintext = try DesktopSafeStorage.decrypt(encrypted, key: key)
      defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
      stage = .selection
      let selected = try DesktopCredentialSelector.select(
        plaintext, account: config.account, organization: organization.organization, now: now)
      stage = .revalidation
      guard try DesktopProtectedFile.stamp(url, maximumBytes: 4 * 1_048_576) == file.stamp else {
        throw DesktopCredentialError.changedDuringRead
      }
      let generation = lastRevision.flatMap {
        $0.matches(selected) ? $0.context.generation : nil
      }
      if generation != nil, previousStamp == file.stamp, previousOrganization == organization,
        let previous
      {
        return previous
      }
      // Reapproval and metadata-only changes invalidate leases, not a 401/403 block.
      let lease = try selected.lease(generation: generation ?? UUID())
      previous = lease
      lastRevision = CredentialRevision(selected, context: lease.context)
      previousStamp = file.stamp
      previousOrganization = organization
      return lease
    } catch {
      lastFailureStage = stage
      invalidate()
      if let error = error as? DesktopCredentialError {
        if error == .permissionRequired { permissionRefused = true }
        throw error
      }
      throw DesktopCredentialError.invalidStore
    }
  }

  func currentContext(for lease: DesktopCredentialLease, now: Date) -> DesktopUsageContext? {
    guard let current = try? load(now: now), current === lease else { return nil }
    return current.context
  }

  private func invalidate() {
    previous = nil
    previousStamp = nil
    previousOrganization = nil
  }
}
