import Foundation
import Security

@testable import QuotaTempoDesktopCandidate

// Manually linked local diagnostic, never part of a SwiftPM product or app bundle.
// No raw result/error interpolation, credential output, persistence, or retries.
@main
struct DesktopCandidateLocalProbe {
  static func main() async {
    if Array(CommandLine.arguments.dropFirst()) == ["--keychain-status-only"] {
      var keychain: SecKeychain?
      var status: SecKeychainStatus = 0
      guard SecKeychainCopyDefault(&keychain) == errSecSuccess,
        let keychain, SecKeychainGetStatus(keychain, &status) == errSecSuccess
      else {
        print("{\"status\":\"keychain_status_unavailable\"}")
        return
      }
      print("{\"keychainUnlocked\":\(status & SecKeychainStatus(kSecUnlockStateStatus) != 0)}")
      return
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    let requiredArguments = [
      "--consent-desktop-read-only", "--acknowledge-provider-permission-unconfirmed",
    ]
    let interactive = arguments == requiredArguments + ["--request-keychain-access"]
    guard arguments == requiredArguments || interactive else {
      print("{\"status\":\"explicit_local_consent_required\"}")
      return
    }
    let watchdog = Task.detached {
      try? await Task.sleep(for: .seconds(interactive ? 180 : 45))
      guard !Task.isCancelled else { return }
      print("{\"status\":\"process_deadline_exceeded\"}")
      exit(2)
    }
    // This branch is for the owner to launch manually, never a timer/retry path.
    // The system dialog authorizes this same signed helper; it is not a login.
    let service: DesktopUsageCandidateService
    if interactive {
      do {
        let material = try InteractiveKeyMaterial()
        service = DesktopUsageCandidateService(
          reader: DesktopCredentialReader(keyReader: { material.key() }))
      } catch {
        watchdog.cancel()
        print("{\"status\":\"keychain_access_not_granted\"}")
        return
      }
    } else {
      service = DesktopUsageCandidateService()
    }
    await service.setApproval(
      DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true))
    let result = await service.refresh()
    watchdog.cancel()
    var fields: [String: Any] = [
      "status": result.state.rawValue,
      "desktopOnly": true,
      "providerPermissionConfirmed": false,
      "observationAccepted": result.observation != nil,
    ]
    if let error = result.credentialError { fields["credentialError"] = errorCode(error) }
    let formatter = ISO8601DateFormatter()
    if let next = result.nextAllowedAt { fields["nextAllowedAt"] = formatter.string(from: next) }
    if let observation = result.observation {
      fields["capturedAt"] = formatter.string(from: observation.capturedAt)
      fields["weeklyRemainingPercent"] = observation.values.weekly.remainingPercent
      fields["weeklyResetAt"] = observation.values.weekly.resetAt.map(formatter.string)
      fields["weeklyResetEstimated"] = observation.values.weekly.isResetEstimated
      fields["fiveHourRemainingPercent"] = observation.values.fiveHour?.remainingPercent
      fields["fiveHourResetAt"] = observation.values.fiveHour?.resetAt.map(formatter.string)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
      let output = String(data: data, encoding: .utf8)
    else {
      print("{\"status\":\"diagnostic_encoding_failed\"}")
      return
    }
    print(output)
    await service.setApproval(DesktopAccessApproval())
  }

  private static func errorCode(_ error: DesktopCredentialError) -> String {
    switch error {
    case .consentRequired: "consentRequired"
    case .providerApprovalRequired: "providerApprovalRequired"
    case .permissionRequired: "permissionRequired"
    case .unavailable: "unavailable"
    case .unsafePath: "unsafePath"
    case .inputTooLarge: "inputTooLarge"
    case .invalidStore: "invalidStore"
    case .identityUnavailable: "identityUnavailable"
    case .ambiguousIdentity: "ambiguousIdentity"
    case .expired: "expired"
    case .missingScope: "missingScope"
    case .changedDuringRead: "changedDuringRead"
    }
  }
}

private final class InteractiveKeyMaterial: @unchecked Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private var bytes: Data

  init() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Safe Storage",
      kSecAttrAccount as String: "Claude Key",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      var password = item as? Data, !password.isEmpty, password.count <= 4096
    else { throw DesktopCredentialError.permissionRequired }
    defer { password.resetBytes(in: password.startIndex..<password.endIndex) }
    bytes = try DesktopSafeStorage.deriveKey(password: password)
  }

  func key() -> Data { bytes }
  var description: String { "InteractiveKeyMaterial(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
  deinit { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
}
