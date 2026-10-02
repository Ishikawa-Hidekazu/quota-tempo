import Foundation
import LocalAuthentication
import Security

// Explicit user action only. Normal readers and refresh/retry paths must never
// call this helper. Success confirms a prompt-free read now, not permanent access.
enum DesktopKeychainAuthorization {
  private static let requestLock = NSLock()

  static func request() async -> Bool {
    guard !Task.isCancelled else { return false }
    let task = Task.detached(priority: .userInitiated) {
      perform(
        getInteraction: {
          var allowed: DarwinBoolean = false
          guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else {
            throw DesktopCredentialError.permissionRequired
          }
          return allowed.boolValue
        },
        setInteraction: { allowed in
          guard SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else {
            throw DesktopCredentialError.permissionRequired
          }
        },
        query: { query in
          var result: CFTypeRef?
          let status = SecItemCopyMatching(query as CFDictionary, &result)
          return (status, result)
        },
        keychainForItem: { item in
          guard CFGetTypeID(item) == SecKeychainItemGetTypeID() else {
            throw DesktopCredentialError.unavailable
          }
          var keychain: SecKeychain?
          try DesktopKeychainReadGate.requireSuccess(
            SecKeychainItemCopyKeychain(item as! SecKeychainItem, &keychain))
          guard let keychain else { throw DesktopCredentialError.unavailable }
          return keychain
        })
    }
    return await withTaskCancellationHandler {
      let success = await task.value
      return success && !Task.isCancelled
    } onCancel: {
      task.cancel()
    }
  }

  // All dependencies are required so synthetic tests cannot accidentally fall
  // through to Security APIs. No key material crosses this Bool-only boundary.
  static func perform(
    getInteraction: () throws -> Bool,
    setInteraction: (Bool) throws -> Void,
    query: ([String: Any]) throws -> (OSStatus, CFTypeRef?),
    keychainForItem: (CFTypeRef) throws -> CFTypeRef,
    isCancelled: () -> Bool = { Task.isCancelled }
  ) -> Bool {
    // Reject overlapping authorization operations rather than queuing another UI.
    guard requestLock.try() else { return false }
    defer { requestLock.unlock() }
    do {
      guard !isCancelled() else { return false }
      let target = try DesktopLegacyInteractionGuard.perform(
        get: getInteraction, set: setInteraction,
        operation: { () throws -> (item: CFTypeRef, keychain: CFTypeRef) in
          guard !isCancelled() else { throw CancellationError() }
          var selection = makeQuery(allowInteraction: false)
          selection[kSecReturnRef as String] = true
          let (status, item) = try query(selection)
          guard !isCancelled() else { throw CancellationError() }
          try DesktopKeychainReadGate.requireSuccess(status)
          guard let item else { throw DesktopCredentialError.unavailable }
          return (item, try keychainForItem(item))
        })
      guard !isCancelled() else { return false }
      try DesktopLegacyInteractionGuard.perform(
        allowInteraction: true, get: getInteraction, set: setInteraction,
        operation: {
          guard !isCancelled() else { throw CancellationError() }
          try checkMaterial(
            item: target.item, keychain: target.keychain, allowInteraction: true, query: query)
        })
      guard !isCancelled() else { return false }
      // Confirm separately with a fresh LAContext and UI suppression. Interactive
      // success alone is not evidence of background access. Never reselect.
      try DesktopLegacyInteractionGuard.perform(
        get: getInteraction, set: setInteraction,
        operation: {
          guard !isCancelled() else { throw CancellationError() }
          try checkMaterial(
            item: target.item, keychain: target.keychain, allowInteraction: false, query: query)
        })
      return !isCancelled()
    } catch {
      return false
    }
  }

  private static func makeQuery(allowInteraction: Bool) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = !allowInteraction
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Safe Storage",
      kSecAttrAccount as String: "Claude Key",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
  }

  private static func checkMaterial(
    item: CFTypeRef, keychain: CFTypeRef, allowInteraction: Bool,
    query: ([String: Any]) throws -> (OSStatus, CFTypeRef?)
  ) throws {
    var dataQuery = makeQuery(allowInteraction: allowInteraction)
    dataQuery[kSecReturnData as String] = true
    dataQuery[kSecMatchItemList as String] = [item]
    dataQuery[kSecMatchSearchList as String] = [keychain]
    var status: OSStatus = errSecSuccess
    var result: CFTypeRef?
    (status, result) = try query(dataQuery)
    var password = result as? Data ?? Data()
    result = nil
    defer { password.resetBytes(in: password.startIndex..<password.endIndex) }
    try DesktopKeychainReadGate.requireSuccess(status)
    guard !password.isEmpty, password.count <= 4096 else {
      throw DesktopCredentialError.invalidStore
    }
    // Authorization needs no derived key. Discard the returned material here.
  }
}
