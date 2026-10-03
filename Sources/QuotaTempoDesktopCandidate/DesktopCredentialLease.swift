import CryptoKit
import Foundation

enum DesktopCredentialError: Error, Equatable {
  case consentRequired
  case providerApprovalRequired
  case permissionRequired
  case keychainLocked
  case unavailable
  case unsafePath
  case inputTooLarge
  case invalidStore
  case identityUnavailable
  case ambiguousIdentity
  case expired
  case missingScope
  case changedDuringRead
}

struct DesktopAccessApproval: Sendable {
  var userConsented = false
  var providerApproved = false
  // Explicit permission for an isolated local experiment is not provider approval.
  // No shipped product may depend on this candidate or inherit this opt-in.
  var localExperimentAuthorized = false

  var allowsAccess: Bool {
    userConsented && (providerApproved || localExperimentAuthorized)
  }

  func requireAccess() throws {
    guard userConsented else { throw DesktopCredentialError.consentRequired }
    guard providerApproved || localExperimentAuthorized else {
      throw DesktopCredentialError.providerApprovalRequired
    }
  }
}

enum DesktopIdentity {
  static func canonicalUUID(_ value: String) throws -> String {
    guard value.utf8.count == 36, let uuid = UUID(uuidString: value),
      uuid.uuidString.lowercased() == value.lowercased()
    else { throw DesktopCredentialError.identityUnavailable }
    return uuid.uuidString.lowercased()
  }

  static func owner(account: String, organization: String) throws -> DesktopUsageOwner {
    let account = try canonicalUUID(account)
    let organization = try canonicalUUID(organization)
    func fingerprint(_ value: String) -> String {
      SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    return DesktopUsageOwner(
      accountFingerprint: fingerprint("quotatempo.desktop.account.v1:" + account),
      organizationFingerprint: fingerprint("quotatempo.desktop.organization.v1:" + organization))
  }
}

// No Codable or raw-value accessor. Reflection/log descriptions never contain secrets.
final class DesktopCredentialLease: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let context: DesktopUsageContext
  private let token: Data

  init(context: DesktopUsageContext, token: Data) throws {
    guard context.owner.isValid, !token.isEmpty, token.count <= 8192,
      token.allSatisfy({ (33...126).contains($0) })
    else { throw DesktopCredentialError.invalidStore }
    self.context = context
    self.token = token
  }

  func authorize(_ request: inout URLRequest) {
    // Defense in depth: even a future caller cannot attach the lease elsewhere.
    guard request.httpMethod == "GET", request.url?.scheme == "https",
      request.url?.host == "api.anthropic.com", request.url?.port == nil,
      request.url?.user == nil, request.url?.password == nil,
      request.url?.query == nil, request.url?.fragment == nil,
      ["/api/oauth/profile", "/api/oauth/usage"].contains(request.url?.path)
    else { return }
    request.setValue(
      "Bearer " + String(decoding: token, as: UTF8.self), forHTTPHeaderField: "Authorization")
  }

  func matches(token other: Data) -> Bool { token == other }

  var description: String { "DesktopCredentialLease(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
}
