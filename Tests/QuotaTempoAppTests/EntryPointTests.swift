import Testing

@testable import QuotaTempoApp

@Suite("Desktop acceptance entry routing")
struct EntryPointTests {
  @Test(arguments: [
    ["--desktop-acceptance"], ["--desktop-acceptance=wrong"],
    ["--consent-desktop-read-only"],
    ["--acknowledge-provider-permission-unconfirmed"],
    ["--provider-disabled", "--desktop-acceptance"],
  ])
  func incompleteRequestsNeverFallThroughToUI(arguments: [String]) {
    #expect(QuotaTempoEntryPoint.requestsDesktopAcceptance(arguments))
  }

  @Test(arguments: [[], ["--provider-disabled"], ["--storage-directory", "/synthetic"]])
  func normalApplicationArguments(arguments: [String]) {
    #expect(!QuotaTempoEntryPoint.requestsDesktopAcceptance(arguments))
  }
}
