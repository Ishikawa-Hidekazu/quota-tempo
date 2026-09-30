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
      kSecReturnData as String: true,
      kSecUseAuthenticationContext as String: context,
    ]
    let (status, item) = try DesktopLegacyInteractionGuard.perform(
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
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
      })
    guard status == errSecSuccess else {
      if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
        throw DesktopCredentialError.permissionRequired
      }
      throw DesktopCredentialError.unavailable
    }
    guard var password = item as? Data, !password.isEmpty, password.count <= 4096 else {
      throw DesktopCredentialError.invalidStore
    }
    defer { password.resetBytes(in: password.startIndex..<password.endIndex) }
    return try deriveKey(password: password)
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

enum DesktopLegacyInteractionGuard {
  private static let lock = NSLock()

  // Legacy ACL dialogs ignore LAContext. This process-local setting must be
  // serialized and restored on both success and failure; no async work occurs.
  static func perform<T>(
    get: () throws -> Bool, set: (Bool) throws -> Void, operation: () throws -> T
  ) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    let original: Bool
    do { original = try get() } catch { throw DesktopCredentialError.permissionRequired }
    do { try set(false) } catch { throw DesktopCredentialError.permissionRequired }
    let result = Result { try operation() }
    do { try set(original) } catch { throw DesktopCredentialError.permissionRequired }
    return try result.get()
  }
}
