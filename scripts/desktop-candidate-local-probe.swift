import Dispatch
import Foundation
import QuotaTempoCore
import Security

@testable import QuotaTempoDesktopCandidate

// Manually linked local diagnostic, never part of a SwiftPM product or app bundle.
// No raw result/error interpolation, credential output, or observation persistence.
// Only account-independent request/backoff metadata is persisted in the isolated
// preview's private Application Support directory, never the development checkout.
// One-shot by default; the explicit local preview reuses the guarded service.
@main
struct DesktopCandidateLocalProbe {
  @MainActor static func main() {
    setbuf(stdout, nil)
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
    let preview = arguments == requiredArguments + ["--menu-bar-preview"]
    let previewQA = arguments == requiredArguments + ["--menu-bar-preview-qa"]
    guard arguments == requiredArguments || interactive || preview || previewQA else {
      print("{\"status\":\"explicit_local_consent_required\"}")
      return
    }
    let throttleStore: DesktopThrottleFileStore
    do {
      throttleStore = try DesktopThrottleFileStore.applicationSupport()
    } catch {
      print("{\"status\":\"throttle_store_unavailable\"}")
      return
    }
    if preview || previewQA {
      let instanceLock: DesktopPreviewInstanceLock
      do {
        instanceLock = try DesktopPreviewInstanceLock(
          directory: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
      } catch {
        print("{\"status\":\"preview_instance_lock_unavailable\"}")
        return
      }
      let previewWatchdog =
        previewQA
        ? Task.detached {
          try? await Task.sleep(for: .seconds(400))
          guard !Task.isCancelled else { return }
          print("{\"previewQA\":\"deadline_exceeded\"}")
          exit(2)
        } : nil
      let diagnostics = TransportDiagnostics()
      let service = DesktopUsageCandidateService(
        throttleStore: throttleStore,
        fetch: { request, lease in
          await DesktopUsageHTTPTransport(diagnostic: { diagnostics.append($0) })
            .fetch(request: request, lease: lease)
        })
      DesktopPreviewApplication.run(service: service, qa: previewQA) { result, scenario, trigger in
        // Values stay in the UI; terminal output is bounded, fixed metadata only.
        let plan = scenario.snapshots.first.map { QuotaPlanner.evaluate($0, now: scenario.now) }
        var fields: [String: Any] = [
          "status": result.state.rawValue,
          "trigger": trigger.rawValue,
          "desktopOnly": true,
          "providerPermissionConfirmed": false,
          "observationAvailable": result.observation != nil,
          "planVisible": plan?.targetNow != nil && plan?.vsTarget != nil,
          "transportStages": diagnostics.takeStages(),
          "capturedAt": result.observation.map {
            ISO8601DateFormatter().string(from: $0.capturedAt)
          } ?? "",
        ]
        if let error = result.credentialError { fields["credentialError"] = errorCode(error) }
        if let next = result.nextAllowedAt {
          fields["nextAllowedAt"] = ISO8601DateFormatter().string(from: next)
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
          let output = String(data: data, encoding: .utf8)
        {
          print(output)
        }
      }
      previewWatchdog?.cancel()
      withExtendedLifetime(instanceLock) {}
      return
    }
    // AppKit's preview event loop starts synchronously above, never inside an
    // already-running MainActor task. Only the headless one-shot is async.
    Task {
      await runOneShot(interactive: interactive, throttleStore: throttleStore)
      exit(0)
    }
    dispatchMain()
  }

  @MainActor private static func runOneShot(
    interactive: Bool, throttleStore: DesktopThrottleFileStore
  ) async {
    let watchdog = Task.detached {
      try? await Task.sleep(for: .seconds(interactive ? 180 : 45))
      guard !Task.isCancelled else { return }
      print("{\"status\":\"process_deadline_exceeded\"}")
      exit(2)
    }
    // This branch is for the owner to launch manually, never a timer/retry path.
    // The system dialog authorizes this same signed helper; it is not a login.
    let reader: DesktopCredentialReader
    if interactive {
      do {
        let material = try InteractiveKeyMaterial()
        reader = DesktopCredentialReader(keyReader: { material.key() })
      } catch {
        watchdog.cancel()
        print("{\"status\":\"keychain_access_not_granted\"}")
        return
      }
    } else {
      reader = DesktopCredentialReader()
    }
    let diagnostics = TransportDiagnostics()
    let service = DesktopUsageCandidateService(
      reader: reader,
      throttleStore: throttleStore,
      fetch: { request, lease in
        await DesktopUsageHTTPTransport(diagnostic: { diagnostics.append($0) })
          .fetch(request: request, lease: lease)
      })
    await service.setApproval(
      DesktopAccessApproval(userConsented: true, localExperimentAuthorized: true))
    let result = await service.refresh()
    watchdog.cancel()
    var fields: [String: Any] = [
      "status": result.state.rawValue,
      "desktopOnly": true,
      "providerPermissionConfirmed": false,
      "observationAccepted": result.observation != nil,
      "transportStages": diagnostics.stages(),
    ]
    if let error = result.credentialError {
      fields["credentialError"] = errorCode(error)
      if let stage = await reader.lastFailureStage { fields["credentialStage"] = stage.rawValue }
    }
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
    case .keychainLocked: "keychainLocked"
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

private final class TransportDiagnostics: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [DesktopUsageHTTPTransport.Diagnostic] = []
  func append(_ value: DesktopUsageHTTPTransport.Diagnostic) {
    lock.lock()
    defer { lock.unlock() }
    if values.count < 16 { values.append(value) }
  }
  func stages() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return values.map(\.rawValue)
  }
  func takeStages() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let result = values.map(\.rawValue)
    values.removeAll(keepingCapacity: true)
    return result
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
