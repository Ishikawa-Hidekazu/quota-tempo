import CommonCrypto
import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

private let testAccount = "11111111-1111-4111-8111-111111111111"
private let testOrganization = "22222222-2222-4222-8222-222222222222"
private let testClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let testNow = Date(timeIntervalSince1970: 1_900_000_000)

private func cacheKey(
  account: String = testAccount, organization: String = testOrganization,
  client: String = testClient, audience: String = "https://api.anthropic.com",
  scopes: String = "user:profile user:inference"
) -> String { "acct:\(account)|\(client):\(organization):\(audience):\(scopes)" }

private func entry(token: String = "synthetic-only-token", expiry: Double = 1_900_001_000)
  -> [String: Any]
{
  ["token": token, "expiresAt": expiry, "refreshToken": ["deliberately": "not decoded"]]
}

private func selection(_ entries: [String: Any]) throws -> DesktopSelectedCredential {
  try DesktopCredentialSelector.select(
    JSONSerialization.data(withJSONObject: entries), account: testAccount,
    organization: testOrganization, now: testNow)
}

@Suite("Desktop credential boundary")
struct DesktopCredentialTests {
  @Test func keychainGateNeverQueriesKnownLockedOrUnknownStorage() {
    for (state, error): (DesktopKeychainReadGate.State, DesktopCredentialError) in [
      (.locked, .keychainLocked), (.unknown, .unavailable),
    ] {
      var queried = false
      #expect(throws: error) {
        try DesktopKeychainReadGate.perform(state: state) { queried = true }
      }
      #expect(!queried)
    }
  }

  @Test func keychainGateAllowsOneReadOnlyAfterUnlock() throws {
    var queried = 0
    let value = try DesktopKeychainReadGate.perform(state: .unlocked) {
      queried += 1
      return "synthetic-only"
    }
    #expect(value == "synthetic-only")
    #expect(queried == 1)
  }

  @Test func keychainGateDoesNotDowngradeActualAccessDenial() {
    #expect(throws: DesktopCredentialError.permissionRequired) {
      try DesktopKeychainReadGate.perform(state: .unlocked) {
        throw DesktopCredentialError.permissionRequired
      }
    }
  }

  @Test func accessRequiresBothApprovals() throws {
    #expect(throws: DesktopCredentialError.consentRequired) {
      try DesktopAccessApproval().requireAccess()
    }
    #expect(throws: DesktopCredentialError.providerApprovalRequired) {
      try DesktopAccessApproval(userConsented: true).requireAccess()
    }
    try DesktopAccessApproval(userConsented: true, providerApproved: true).requireAccess()
  }

  @Test func legacyKeychainUIIsDisabledAndOriginalSettingRestored() throws {
    for original in [false, true] {
      var events: [Bool] = []
      let result = try DesktopLegacyInteractionGuard.perform(
        get: { original }, set: { events.append($0) },
        operation: {
          #expect(events == [false])
          return 42
        })
      #expect(result == 42)
      #expect(events == [false, original])
    }
  }

  @Test func legacyKeychainUIRestoresAfterFailureAndStopsOnSuppressionFailure() throws {
    var events: [Bool] = []
    #expect(throws: DesktopCredentialError.unavailable) {
      try DesktopLegacyInteractionGuard.perform(
        get: { true }, set: { events.append($0) },
        operation: { throw DesktopCredentialError.unavailable })
    }
    #expect(events == [false, true])
    #expect(throws: DesktopCredentialError.permissionRequired) {
      try DesktopLegacyInteractionGuard.perform(
        get: { true }, set: { _ in throw DesktopCredentialError.unavailable },
        operation: { Issue.record("Read occurred without UI suppression") })
    }
  }

  @Test func legacyKeychainSettingFailuresDoNotExposeValues() throws {
    #expect(throws: DesktopCredentialError.permissionRequired) {
      try DesktopLegacyInteractionGuard.perform(
        get: { throw DesktopCredentialError.unavailable },
        set: { _ in Issue.record("Unexpected setting change") },
        operation: { Issue.record("Unexpected protected read") })
    }
    var calls = 0
    #expect(throws: DesktopCredentialError.permissionRequired) {
      try DesktopLegacyInteractionGuard.perform(
        get: { true },
        set: { _ in
          calls += 1
          if calls == 2 { throw DesktopCredentialError.unavailable }
        },
        operation: { "synthetic-value-must-not-return-on-restore-failure" })
    }
    #expect(calls == 2)
  }

  @Test func readerDoesNotTouchProtectedStoreBeforeApproval() async {
    let reader = DesktopCredentialReader(
      directory: URL(fileURLWithPath: "/not-a-real-path"),
      keyReader: {
        Issue.record("Keychain reader must not be called")
        return Data()
      })
    do {
      _ = try await reader.load(now: testNow)
      Issue.record("Unexpected admission")
    } catch { #expect(error as? DesktopCredentialError == .consentRequired) }
    await reader.setApproval(DesktopAccessApproval(userConsented: true))
    do {
      _ = try await reader.load(now: testNow)
      Issue.record("Unexpected admission")
    } catch { #expect(error as? DesktopCredentialError == .providerApprovalRequired) }
  }

  @Test func scopedTokenSelectionIgnoresRefreshField() throws {
    let selected = try selection([cacheKey(): entry()])
    #expect(
      selected.owner
        == (try DesktopIdentity.owner(account: testAccount, organization: testOrganization)))
    #expect(selected.expiresAt == testNow.addingTimeInterval(1000))
    #expect(String(describing: selected) == "DesktopSelectedCredential(redacted)")
    #expect(Mirror(reflecting: selected).children.isEmpty)
  }

  @Test func millisecondsAreSupported() throws {
    #expect(
      try selection([cacheKey(): entry(expiry: 1_900_001_000_000)]).expiresAt
        == testNow.addingTimeInterval(1000))
  }

  @Test func cannotSelectOtherAccountOrOrganization() throws {
    for key in [cacheKey(account: testOrganization), cacheKey(organization: testAccount)] {
      #expect(throws: DesktopCredentialError.identityUnavailable) { try selection([key: entry()]) }
    }
  }

  @Test func legacyUnscopedKeyIsNotAnOwnershipProof() throws {
    let key = "\(testClient):\(testOrganization):https://api.anthropic.com:user:profile"
    #expect(throws: DesktopCredentialError.identityUnavailable) { try selection([key: entry()]) }
  }

  @Test func audienceAndScopeMustMatchExactly() throws {
    for key in [
      cacheKey(audience: "https://api.anthropic.com.evil.test"),
      cacheKey(audience: "http://api.anthropic.com"),
      cacheKey(scopes: "not-user:profile"), cacheKey(scopes: "user:profile-extra"),
    ] {
      #expect(throws: DesktopCredentialError.identityUnavailable) { try selection([key: entry()]) }
    }
  }

  @Test func malformedExpiryAndHeaderInjectionAreRejected() throws {
    for bad: Any in [true, "1900001000", NSNull()] {
      #expect(throws: DesktopCredentialError.invalidStore) {
        try selection([cacheKey(): ["token": "synthetic", "expiresAt": bad]])
      }
    }
    for token in [
      "", "synthetic\r\nInjected: yes", "has space", "日本語", String(repeating: "a", count: 8193),
    ] {
      #expect(throws: DesktopCredentialError.invalidStore) {
        try selection([cacheKey(): entry(token: token)])
      }
    }
  }

  @Test func expiresBeforeRequestCompletesIsRejected() throws {
    for expiry in [1_899_999_999.0, 1_900_000_120] {
      #expect(throws: DesktopCredentialError.expired) {
        try selection([cacheKey(): entry(expiry: expiry)])
      }
    }
  }

  @Test func equallyRankedConflictingTokensAreRejected() throws {
    #expect(throws: DesktopCredentialError.ambiguousIdentity) {
      try selection([
        cacheKey(): entry(),
        cacheKey(scopes: "user:inference user:profile"): entry(
          token: "different"),
      ])
    }
  }

  @Test func matchingOwnerCredentialsRankScopesBeforeExpiry() throws {
    let selected = try selection([
      cacheKey(): entry(token: "older-tier", expiry: 1_900_099_999),
      cacheKey(scopes: "user:profile user:inference user:sessions:claude_code"):
        entry(token: "full-login"),
      cacheKey(client: testAccount, scopes: "user:profile user:inference user:a user:b"):
        entry(token: "other-client", expiry: 1_900_099_999),
      cacheKey(account: testOrganization, scopes: "user:profile user:inference user:a user:b"):
        entry(token: "other-account", expiry: 1_900_099_999),
      cacheKey(organization: testAccount, scopes: "user:profile user:inference user:a user:b"):
        entry(token: "other-organization", expiry: 1_900_099_999),
    ])
    #expect(try selected.lease(generation: UUID()).matches(token: Data("full-login".utf8)))
  }

  @Test func expiryBreaksTiesOnlyWithinSameScopeTier() throws {
    let selected = try selection([
      cacheKey(): entry(),
      cacheKey(scopes: "user:inference user:profile"):
        entry(token: "renewed-login", expiry: 1_900_002_000),
      cacheKey(scopes: "user:profile"): entry(token: "leftover", expiry: 1_900_099_999),
    ])
    #expect(try selected.lease(generation: UUID()).matches(token: Data("renewed-login".utf8)))
  }

  @Test func scopeOrderAndDuplicatesDoNotChangeRank() throws {
    #expect(throws: DesktopCredentialError.ambiguousIdentity) {
      try selection([
        cacheKey(): entry(),
        cacheKey(scopes: "user:inference user:profile user:profile"): entry(token: "different"),
      ])
    }
  }

  @Test func fullScopeWinsWhenProductionFullScopeIsAbsent() throws {
    let selected = try selection([
      cacheKey(scopes: "user:profile user:a user:b"): entry(
        token: "leftover", expiry: 1_900_099_999),
      cacheKey(client: testAccount): entry(token: "full-login"),
    ])
    #expect(try selected.lease(generation: UUID()).matches(token: Data("full-login".utf8)))
  }

  @Test func productionFullScopeWinsOverLeftoverProfileOnlyToken() throws {
    let selected = try selection([
      cacheKey(): entry(),
      cacheKey(scopes: "user:profile"): entry(token: "leftover", expiry: 1_900_099_999),
    ])
    let lease = try selected.lease(generation: UUID())
    #expect(lease.matches(token: Data("synthetic-only-token".utf8)))
  }

  @Test func deletionMarkersAndMalformedOtherAccountsAreNotDecoded() throws {
    let selected = try selection([
      cacheKey(): entry(), cacheKey(account: testOrganization): ["not": "a credential"],
      cacheKey(scopes: "user:profile"): NSNull(),
    ])
    #expect(selected.expiresAt == testNow.addingTimeInterval(1000))
  }

  @Test func inputSizeAndEntryCountAreBounded() throws {
    #expect(throws: DesktopCredentialError.invalidStore) {
      try DesktopCredentialSelector.select(
        Data(repeating: 32, count: 1_048_577), account: testAccount, organization: testOrganization,
        now: testNow)
    }
    let many = Dictionary(uniqueKeysWithValues: (0..<129).map { ("key\($0)", NSNull()) })
    #expect(throws: DesktopCredentialError.invalidStore) { try selection(many) }
  }

  @Test func leaseIsRedactedAndOnlyAuthorizesFixedURLs() throws {
    let lease = try selection([cacheKey(): entry()]).lease(generation: UUID())
    #expect(String(describing: lease) == "DesktopCredentialLease(redacted)")
    #expect(String(reflecting: lease) == "DesktopCredentialLease(redacted)")
    #expect(Mirror(reflecting: lease).children.isEmpty)
    for url in [
      "https://evil.test/api/oauth/usage", "http://api.anthropic.com/api/oauth/usage",
      "https://api.anthropic.com:443/api/oauth/usage",
      "https://api.anthropic.com/api/oauth/usage?q=1",
      "https://api.anthropic.com/api/oauth/token", "https://user@api.anthropic.com/api/oauth/usage",
    ] {
      var request = URLRequest(url: try #require(URL(string: url)))
      lease.authorize(&request)
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.httpMethod = "POST"
    lease.authorize(&request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    request.httpMethod = "GET"
    lease.authorize(&request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only-token")
  }

  @Test func identityFingerprintIsCanonicalAndDomainSeparated() throws {
    let owner = try DesktopIdentity.owner(
      account: testClient.uppercased(), organization: testClient)
    #expect(owner.isValid)
    #expect(owner.accountFingerprint != owner.organizationFingerprint)
    #expect(owner == (try DesktopIdentity.owner(account: testClient, organization: testClient)))
    #expect(throws: DesktopCredentialError.identityUnavailable) {
      try DesktopIdentity.owner(account: "not-a-uuid", organization: testOrganization)
    }
  }

  @Test func safeStorageIndependentCryptoVector() throws {
    let key = try DesktopSafeStorage.deriveKey(password: Data("synthetic-only-password".utf8))
    // Vector independently generated with Node crypto PBKDF2/AES, not this implementation.
    #expect(key.map { String(format: "%02x", $0) }.joined() == "d957bf802d2a18c9e77fc7b03dba75ef")
    let cipher = try #require(
      Data(base64Encoded: "djEwukNatNQwh3HHeeqT6ctjtxn8bEV40BK7aITGk5phbmI="))
    #expect(
      try DesktopSafeStorage.decrypt(cipher, key: key) == Data("synthetic-only-plaintext".utf8))
    // CBC padding is not authentication: a wrong key can still produce valid padding.
    // The cache/schema and server identity checks remain mandatory after decryption.
    let wrongKeyOutput = try? DesktopSafeStorage.decrypt(cipher, key: Data(repeating: 0, count: 16))
    #expect(wrongKeyOutput != Data("synthetic-only-plaintext".utf8))
    if let wrongKeyOutput {
      #expect(throws: DesktopCredentialError.invalidStore) {
        try DesktopCredentialSelector.select(
          wrongKeyOutput, account: testAccount, organization: testOrganization, now: testNow)
      }
    }
    for invalid in [
      Data(), Data("v11".utf8) + cipher.dropFirst(3), cipher.dropLast(),
      Data(repeating: 0, count: 1_048_577),
    ] {
      #expect(throws: DesktopCredentialError.invalidStore) {
        try DesktopSafeStorage.decrypt(Data(invalid), key: key)
      }
    }
  }

  @Test func protectedFileRejectsSymlinksAndBoundsSize() throws {
    let directory = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("fixture.json")
    try Data("{}".utf8).write(to: file)
    #expect(try DesktopProtectedFile.read(file, maximumBytes: 2).data == Data("{}".utf8))
    #expect(throws: DesktopCredentialError.inputTooLarge) {
      try DesktopProtectedFile.read(file, maximumBytes: 1)
    }
    let alias = directory.appendingPathComponent("alias.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    #expect(throws: DesktopCredentialError.unsafePath) {
      try DesktopProtectedFile.read(alias, maximumBytes: 10)
    }
    let dirAlias = directory.appendingPathComponent("alias-directory")
    try FileManager.default.createSymbolicLink(at: dirAlias, withDestinationURL: directory)
    #expect(throws: DesktopCredentialError.unsafePath) {
      try DesktopProtectedFile.read(
        dirAlias.appendingPathComponent("fixture.json"), maximumBytes: 10)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
    #expect(throws: DesktopCredentialError.unsafePath) {
      try DesktopProtectedFile.read(file, maximumBytes: 10)
    }
  }
}
