import CommonCrypto
import Foundation
import LocalAuthentication
import Security

enum DesktopSafeStorage {
  static let maximumCacheBytes = 1_048_576

  static func readKeyWithoutInteraction() throws -> Data {
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Safe Storage",
      kSecAttrAccount as String: "Claude Key",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnRef as String: true,
      kSecUseAuthenticationContext as String: context,
    ]
    let item = try DesktopLegacyInteractionGuard.perform(
      get: {
        var value: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&value) == errSecSuccess else {
          throw DesktopCredentialError.permissionRequired
        }
        return value.boolValue
      },
      set: { value in
        guard SecKeychainSetUserInteractionAllowed(value) == errSecSuccess else {
          throw DesktopCredentialError.permissionRequired
        }
      },
      operation: {
        try DesktopKeychainReadGate.read(
          findTarget: { try findTarget(query: query) },
          state: { keychainState($0.keychain) },
          query: { target in
            var dataQuery = query
            dataQuery.removeValue(forKey: kSecReturnRef as String)
            dataQuery[kSecReturnData as String] = true
            // Keep both the query and its lock evidence tied to the selected item.
            dataQuery[kSecMatchItemList as String] = [target.item]
            dataQuery[kSecMatchSearchList as String] = [target.keychain]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(dataQuery as CFDictionary, &result)
            return (status, result)
          })
      })
    guard var password = item as? Data, !password.isEmpty, password.count <= 4096 else {
      throw DesktopCredentialError.invalidStore
    }
    defer { password.resetBytes(in: password.startIndex..<password.endIndex) }
    return try deriveKey(password: password)
  }

  private static func findTarget(query: [String: Any]) throws -> (
    item: SecKeychainItem, keychain: SecKeychain
  ) {
    var result: CFTypeRef?
    // Reference discovery requests no password data. Failure here has no known
    // owning keychain, so it must not borrow lock evidence from the default one.
    try DesktopKeychainReadGate.requireSuccess(
      SecItemCopyMatching(query as CFDictionary, &result))
    guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else {
      throw DesktopCredentialError.unavailable
    }
    let item = result as! SecKeychainItem
    var keychain: SecKeychain?
    try DesktopKeychainReadGate.requireSuccess(SecKeychainItemCopyKeychain(item, &keychain))
    guard let keychain else { throw DesktopCredentialError.unavailable }
    return (item, keychain)
  }

  private static func keychainState(_ keychain: SecKeychain) -> DesktopKeychainReadGate.State {
    var status: SecKeychainStatus = 0
    guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return .unknown }
    return status & SecKeychainStatus(kSecUnlockStateStatus) == 0 ? .locked : .unlocked
  }

  static func deriveKey(password: Data) throws -> Data {
    guard !password.isEmpty, password.count <= 4096 else {
      throw DesktopCredentialError.invalidStore
    }
    let salt = Data("saltysalt".utf8)
    var key = Data(count: kCCKeySizeAES128)
    let status = key.withUnsafeMutableBytes { output in
      password.withUnsafeBytes { password in
        salt.withUnsafeBytes { salt in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: Int8.self).baseAddress,
            password.count, salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
            output.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
        }
      }
    }
    guard status == kCCSuccess else { throw DesktopCredentialError.invalidStore }
    return key
  }

  static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
    guard encrypted.count <= maximumCacheBytes, encrypted.count > 3,
      encrypted.prefix(3) == Data("v10".utf8), key.count == kCCKeySizeAES128,
      (encrypted.count - 3).isMultiple(of: kCCBlockSizeAES128)
    else { throw DesktopCredentialError.invalidStore }
    let input = encrypted.dropFirst(3)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: input.count + kCCBlockSizeAES128)
    let capacity = output.count
    var count = 0
    let status = output.withUnsafeMutableBytes { output in
      input.withUnsafeBytes { input in
        key.withUnsafeBytes { key in
          iv.withUnsafeBytes { iv in
            CCCrypt(
              CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding),
              key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
              output.baseAddress, capacity, &count)
          }
        }
      }
    }
    guard status == kCCSuccess else {
      output.resetBytes(in: output.startIndex..<output.endIndex)
      throw DesktopCredentialError.invalidStore
    }
    output.count = count
    return output
  }
}

enum DesktopKeychainReadGate {
  enum State { case locked, unlocked, unknown }

  // Call inside the interaction guard so selection, state checks, and the one
  // protected query all run with UI suppressed. Never reselect or retry an item.
  static func read<Target, Value>(
    findTarget: () throws -> Target, state: (Target) -> State,
    query: (Target) throws -> (OSStatus, Value)
  ) throws -> Value {
    let target = try findTarget()
    return try perform(state: state(target)) {
      let (status, value) = try query(target)
      try requireSuccess(status, targetIsLocked: { state(target) == .locked })
      return value
    }
  }

  // Only an interaction-not-allowed result may use an immediate lock observation
  // of the queried item's own keychain. Authentication failure and cancellation
  // remain refusals even if that keychain also became locked.
  static func requireSuccess(
    _ status: OSStatus, targetIsLocked: () -> Bool = { false }
  ) throws {
    switch status {
    case errSecSuccess: return
    case errSecInteractionNotAllowed:
      throw targetIsLocked()
        ? DesktopCredentialError.keychainLocked : DesktopCredentialError.permissionRequired
    case errSecAuthFailed, errSecUserCanceled:
      throw DesktopCredentialError.permissionRequired
    default: throw DesktopCredentialError.unavailable
    }
  }

  static func perform<T>(state: State, operation: () throws -> T) throws -> T {
    switch state {
    case .locked: throw DesktopCredentialError.keychainLocked
    case .unknown: throw DesktopCredentialError.unavailable
    case .unlocked: return try operation()
    }
  }
}

enum DesktopLegacyInteractionGuard {
  private static let lock = NSLock()

  // Legacy ACL dialogs ignore LAContext. This process-local setting must be
  // serialized and restored on both success and failure; no async work occurs.
  static func perform<T>(
    allowInteraction: Bool = false,
    get: () throws -> Bool, set: (Bool) throws -> Void, operation: () throws -> T
  ) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    let original: Bool
    do { original = try get() } catch { throw DesktopCredentialError.permissionRequired }
    do { try set(allowInteraction) } catch {
      // A failing setter may have changed state before reporting the failure.
      try? set(original)
      throw DesktopCredentialError.permissionRequired
    }
    let result = Result { try operation() }
    do { try set(original) } catch { throw DesktopCredentialError.permissionRequired }
    return try result.get()
  }
}
