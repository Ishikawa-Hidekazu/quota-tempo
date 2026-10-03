import Foundation
import LocalAuthentication
import Security
import Testing

@testable import QuotaTempoDesktopCandidate

private struct AuthorizationSyntheticError: Error, CustomStringConvertible {
  var description: String {
    Issue.record("Authorization must not format a raw dependency error")
    return "synthetic-error-must-not-be-rendered"
  }
}

private final class AuthorizationFixture {
  enum Material { case valid, empty, oversized, wrongType }

  let item: CFTypeRef = NSObject()
  let keychain: CFTypeRef = NSObject()
  let originalInteraction: Bool
  var interaction: Bool
  var settings: [Bool] = []
  var queries: [[String: Any]] = []
  var queryInteraction: [Bool] = []
  var getCalls = 0
  var ownerCalls = 0
  var statuses: [Int: OSStatus] = [:]
  var materials: [Int: Material] = [:]
  var throwOnGet: Int?
  var throwOnSet: Int?
  var throwOnQuery: Int?
  var missingItem = false
  var ownerUnavailable = false
  var cancelled = false
  var cancelAfterQuery: Int?
  var cancelDuringSet: Int?
  var onQuery: ((Int) -> Void)?

  init(interaction: Bool = true) {
    self.originalInteraction = interaction
    self.interaction = interaction
  }

  // Never invokes request(): every protected dependency is a synthetic closure.
  func request() -> Bool {
    DesktopKeychainAuthorization.perform(
      getInteraction: {
        self.getCalls += 1
        if self.throwOnGet == self.getCalls { throw AuthorizationSyntheticError() }
        return self.interaction
      },
      setInteraction: { value in
        self.settings.append(value)
        self.interaction = value
        if self.cancelDuringSet == self.settings.count { self.cancelled = true }
        // Simulate a setter that changes state before it reports an error.
        if self.throwOnSet == self.settings.count { throw AuthorizationSyntheticError() }
      },
      query: { query in
        self.queries.append(query)
        self.queryInteraction.append(self.interaction)
        let index = self.queries.count
        self.onQuery?(index)
        if self.cancelAfterQuery == index { self.cancelled = true }
        if self.throwOnQuery == index { throw AuthorizationSyntheticError() }
        let status = self.statuses[index] ?? errSecSuccess
        if query[kSecReturnRef as String] as? Bool == true {
          return (status, self.missingItem ? nil : self.item)
        }
        switch self.materials[index] ?? .valid {
        case .valid: return (status, Data("synthetic-authorization-password".utf8) as NSData)
        case .empty: return (status, Data() as NSData)
        case .oversized: return (status, Data(repeating: 1, count: 4097) as NSData)
        case .wrongType: return (status, NSString(string: "synthetic-wrong-type"))
        }
      },
      keychainForItem: { selected in
        self.ownerCalls += 1
        // Avoid Swift 6.3 SILGen's CFTypeRef identity reabstraction in #expect.
        let selectedIsExpectedItem = selected === self.item
        #expect(selectedIsExpectedItem)
        if self.ownerUnavailable { throw AuthorizationSyntheticError() }
        return self.keychain
      },
      isCancelled: { self.cancelled })
  }
}

@Suite("Desktop Keychain authorization", .serialized)
struct DesktopKeychainAuthorizationTests {
  @Test func approvalRequiresInteractiveAndFreshNoninteractiveReadsOfTheSameItem() throws {
    for original in [false, true] {
      let fixture = AuthorizationFixture(interaction: original)
      #expect(fixture.request())
      #expect(fixture.ownerCalls == 1)
      #expect(fixture.queries.count == 3)
      #expect(fixture.queryInteraction == [false, true, false])
      #expect(fixture.settings == [false, original, true, original, false, original])
      #expect(fixture.interaction == original)
      var contexts: [LAContext] = []
      for (index, query) in fixture.queries.enumerated() {
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "Claude Safe Storage")
        #expect(query[kSecAttrAccount as String] as? String == "Claude Key")
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed == (index != 1))
        contexts.append(context)
        if index == 0 {
          #expect(query[kSecReturnRef as String] as? Bool == true)
          #expect(query[kSecReturnData as String] == nil)
          #expect(query[kSecMatchItemList as String] == nil)
          #expect(query[kSecMatchSearchList as String] == nil)
        } else {
          #expect(query[kSecReturnData as String] as? Bool == true)
          #expect(query[kSecReturnRef as String] == nil)
          let items = try #require(query[kSecMatchItemList as String] as? [CFTypeRef])
          let keychains = try #require(query[kSecMatchSearchList as String] as? [CFTypeRef])
          #expect(items.count == 1)
          #expect(keychains.count == 1)
          let itemMatches = items.first === fixture.item
          let keychainMatches = keychains.first === fixture.keychain
          #expect(itemMatches)
          #expect(keychainMatches)
        }
      }
      let selectionContextIsSeparate = contexts[0] !== contexts[1]
      let confirmationContextIsFresh = contexts[1] !== contexts[2]
      #expect(selectionContextIsSeparate)
      #expect(confirmationContextIsFresh)
    }
  }

  @Test func allowOnceIsInsufficientAndDoesNotTriggerAnotherPrompt() {
    let fixture = AuthorizationFixture()
    fixture.statuses[3] = errSecInteractionNotAllowed
    #expect(!fixture.request())
    #expect(fixture.queries.count == 3)
    #expect(fixture.queryInteraction == [false, true, false])
    #expect(fixture.ownerCalls == 1)
    #expect(fixture.interaction == fixture.originalInteraction)
  }

  @Test func denialsAndUnavailableResultsStopWithoutRetryOrRawError() {
    for phase in 1...3 {
      for status in [
        errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed,
        errSecItemNotFound, errSecNotAvailable,
      ] {
        let fixture = AuthorizationFixture()
        fixture.statuses[phase] = status
        #expect(!fixture.request())
        #expect(fixture.queries.count == phase)
        #expect(fixture.queryInteraction.filter { $0 }.count == (phase > 1 ? 1 : 0))
        #expect(fixture.interaction == fixture.originalInteraction)
      }
    }
  }

  @Test func thrownQueryErrorsRestoreInteractionAndExposeOnlyFalse() {
    for original in [false, true] {
      for phase in 1...3 {
        let fixture = AuthorizationFixture(interaction: original)
        fixture.throwOnQuery = phase
        #expect(!fixture.request())
        #expect(fixture.queries.count == phase)
        #expect(fixture.interaction == original)
        #expect(fixture.settings.count == phase * 2)
      }
    }
  }

  @Test func missingItemOrUnknownOwnerNeverPrompts() {
    for missingItem in [true, false] {
      let fixture = AuthorizationFixture()
      fixture.missingItem = missingItem
      fixture.ownerUnavailable = !missingItem
      #expect(!fixture.request())
      #expect(fixture.queryInteraction == [false])
      #expect(fixture.ownerCalls == (missingItem ? 0 : 1))
      #expect(fixture.interaction == fixture.originalInteraction)
    }
  }

  @Test func invalidMaterialIsRejectedWithoutFallback() {
    for phase in 2...3 {
      for material: AuthorizationFixture.Material in [.empty, .oversized, .wrongType] {
        let fixture = AuthorizationFixture()
        fixture.materials[phase] = material
        #expect(!fixture.request())
        #expect(fixture.queries.count == phase)
        #expect(fixture.interaction == fixture.originalInteraction)
      }
    }
  }

  @Test func settingReadFailureNeverUsesAnUnknownInteractionState() {
    for phase in 1...3 {
      let fixture = AuthorizationFixture()
      fixture.throwOnGet = phase
      #expect(!fixture.request())
      #expect(fixture.getCalls == phase)
      #expect(fixture.queries.count == phase - 1)
      #expect(fixture.settings.count == (phase - 1) * 2)
      #expect(fixture.interaction == fixture.originalInteraction)
    }
  }

  @Test func settingOrRestorationFailureNeverReturnsSuccess() {
    let expectedQueries = [0, 1, 1, 2, 2, 3]
    let expectedSettings = [2, 2, 4, 4, 6, 6]
    for original in [false, true] {
      for call in 1...6 {
        let fixture = AuthorizationFixture(interaction: original)
        fixture.throwOnSet = call
        #expect(!fixture.request())
        #expect(fixture.queries.count == expectedQueries[call - 1])
        #expect(fixture.settings.count == expectedSettings[call - 1])
        #expect(fixture.interaction == original)
      }
    }
  }

  @Test func cancelledRequestDoesNotAccessProtectedStorage() {
    let fixture = AuthorizationFixture()
    fixture.cancelled = true
    #expect(!fixture.request())
    #expect(fixture.queries.isEmpty)
    #expect(fixture.settings.isEmpty)
    #expect(fixture.getCalls == 0)
  }

  @Test func cancellationAfterAQueryStopsRemainingStepsAndDropsSuccess() {
    for phase in 1...3 {
      let fixture = AuthorizationFixture()
      fixture.cancelAfterQuery = phase
      #expect(!fixture.request())
      #expect(fixture.queries.count == phase)
      #expect(fixture.interaction == fixture.originalInteraction)
    }
  }

  @Test func cancellationBeforeInteractiveQueryRestoresWithoutPrompting() {
    let fixture = AuthorizationFixture(interaction: false)
    fixture.cancelDuringSet = 3
    #expect(!fixture.request())
    #expect(fixture.queryInteraction == [false])
    #expect(fixture.settings == [false, false, true, false])
    #expect(!fixture.interaction)
  }

  @Test func overlappingAuthorizationDoesNotQueueAnotherQuery() {
    let outer = AuthorizationFixture()
    let overlap = AuthorizationFixture()
    outer.onQuery = { phase in
      if phase == 2 { #expect(!overlap.request()) }
    }
    #expect(outer.request())
    #expect(overlap.queries.isEmpty)
    #expect(overlap.settings.isEmpty)
    #expect(overlap.getCalls == 0)
  }

  @Test func laterExplicitRequestMustRevalidateAndCannotUseCachedSuccess() {
    let fixture = AuthorizationFixture()
    #expect(fixture.request())
    fixture.statuses[4] = errSecItemNotFound
    #expect(!fixture.request())
    #expect(fixture.queries.count == 4)
    #expect(fixture.queryInteraction == [false, true, false, false])
    #expect(fixture.interaction == fixture.originalInteraction)
  }

  @Test func existingGuardRemainsNoninteractiveByDefault() throws {
    for original in [false, true] {
      var setting = original
      var changes: [Bool] = []
      let result = try DesktopLegacyInteractionGuard.perform(
        get: { setting },
        set: {
          setting = $0
          changes.append($0)
        },
        operation: {
          #expect(!setting)
          return true
        })
      #expect(result)
      #expect(changes == [false, original])
      #expect(setting == original)
    }
  }
}
