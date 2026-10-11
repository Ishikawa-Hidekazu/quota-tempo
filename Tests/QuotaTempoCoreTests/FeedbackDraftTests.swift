import Foundation
import Testing

@testable import QuotaTempoCore

@Suite("Privacy-safe feedback draft")
struct FeedbackDraftTests {
  @Test(
    "Draft URL has only the fixed recipient, subject and localized body", arguments: ["en", "ja"])
  func draftURL(_ language: String) throws {
    let draft = FeedbackDraft(languageCode: language, publicAppVersion: "0.1.12")
    let url = try #require(draft.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "mailto")
    #expect(components.path == "h@ishikawa.co")
    #expect(components.host == nil && components.fragment == nil && components.user == nil)
    let items = try #require(components.queryItems)
    #expect(items.map(\.name) == ["subject", "body"])
    #expect(items[0].value == "QuotaTempo first-run feedback")
    #expect(items[1].value == draft.body.replacingOccurrences(of: "\n", with: "\r\n"))
    #expect(draft.body.contains("0.1.12"))
    #expect(!draft.body.contains("{public_app_version}"))
    #expect(url.absoluteString.contains("%0D%0A"))
    #expect(!url.absoluteString.contains("\n"))
    #expect(url.absoluteString.filter { $0 == "?" }.count == 1)
    #expect(url.absoluteString.filter { $0 == "&" }.count == 1)
    #expect(!url.absoluteString.contains("%250D"))
    if language == "ja" {
      #expect(url.absoluteString.contains("%E3"))
      #expect(draft.body.contains("表示できた／待機中／設定で停止／不明"))
      #expect(draft.body.contains("記入・添付しないでください。"))
    } else {
      #expect(draft.body.contains("Displayed / Still waiting / Stopped during setup / Unknown"))
      #expect(draft.body.contains("Do not include personal information"))
    }
  }

  @Test("Draft bodies match the approved templates exactly", arguments: ["en", "ja"])
  func approvedTemplate(_ language: String) {
    let expected =
      language == "ja"
      ? """
      QuotaTempo 初回の感想（任意）

      アプリのバージョン：0.1.12
      初回の結果（1つ選び、不要な項目を削除してください）：
      表示できた／待機中／設定で停止／不明
      分かりにくかった点（任意）：

      送信する前に、ご自身で内容を確認・編集してください。送信は任意です。
      名前などの個人情報、残量、リセット日時、スクリーンショット、会話、認証情報、診断、履歴、ローカルパスは記入・添付しないでください。
      """
      : """
      QuotaTempo first-run feedback (optional)

      App version: 0.1.12
      First-run result (choose one and remove the others):
      Displayed / Still waiting / Stopped during setup / Unknown
      What was unclear? (optional):

      Review and edit this draft before sending. Sending is optional.
      Do not include personal information such as your name, quota values, reset times, screenshots, conversations, credentials, diagnostics, history, or local paths.
      """
    #expect(FeedbackDraft(languageCode: language, publicAppVersion: "0.1.12").body == expected)
  }

  @Test(
    "Missing or untrusted version text cannot enter the draft", arguments: ["en", "ja"],
    [
      "", "unknown", "/Users/synthetic/private", "0.1.12\r\nBcc: unwanted@example.invalid",
      "0.1.12&bcc=unwanted@example.invalid", "0.1.12?subject=other#fragment",
      "0.1.12-preview", "1.2.3\n", "１.２.３", "1..2", "10000.1.2",
      "0.1.12-rc", "0.1.12-rc.", "0.1.12-rc.10000", "0.1.12-rc.1&bcc=other",
      "0.1.12-rc.1\r\nBcc: other@example.invalid", "0.1.12-rc.１", "0.1.12-rc.1-extra",
    ])
  func invalidVersion(_ language: String, _ version: String) throws {
    let missing = FeedbackDraft(languageCode: language, publicAppVersion: nil)
    let untrusted = FeedbackDraft(languageCode: language, publicAppVersion: version)
    #expect(untrusted.body == missing.body)
    #expect(untrusted.url == missing.url)
    #expect(missing.body.contains(language == "ja" ? "不明" : "Unknown"))
    let url = try #require(untrusted.url)
    let components = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.queryItems?.map(\.name) == ["subject", "body"])
  }

  @Test("Copy and fallback URL follow UI language, with English fallback")
  func localization() {
    for language in ["ja", "ja-JP", "JA"] {
      #expect(
        FeedbackDraft(languageCode: language, publicAppVersion: nil).productURL.absoluteString
          == "https://ishikawa.co/products/quotatempo/")
      #expect(MenuCopy(languageCode: language).text("feedback.send") == "感想を送る")
    }
    for language in ["en", "en-GB", "fr"] {
      #expect(
        FeedbackDraft(languageCode: language, publicAppVersion: nil).productURL.absoluteString
          == "https://ishikawa.co/en/products/quotatempo/")
      #expect(MenuCopy(languageCode: language).text("feedback.send") == "Send feedback")
    }
  }

  @Test("Public RC versions retain their release identifier", arguments: ["en", "ja"])
  func releaseCandidateVersion(_ language: String) throws {
    let version = "0.1.12-rc.19"
    let draft = FeedbackDraft(languageCode: language, publicAppVersion: version)
    #expect(draft.body.contains(version))
    let url = try #require(draft.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.queryItems?.map(\.name) == ["subject", "body"])
    #expect(components.queryItems?.last?.value?.contains(version) == true)
  }

  @Test("Opening is explicit; failure does not retry or claim delivery")
  @MainActor
  func explicitOpening() {
    var calls: [URL] = []
    let controller = FeedbackDraftController(
      draft: FeedbackDraft(languageCode: "en", publicAppVersion: "0.1.12"),
      open: { url in
        calls.append(url)
        return calls.count > 1
      })
    #expect(calls.isEmpty)
    #expect(!controller.openingFailed)
    controller.openDraft()
    #expect(calls.count == 1)
    #expect(controller.openingFailed)
    #expect(calls.count == 1)
    controller.openDraft()
    #expect(calls.count == 2)
    #expect(!controller.openingFailed)
    // The mail app's cancel/send outcome is deliberately not observed.
    #expect(calls.count == 2)
    controller.openDraft()
    #expect(calls.count == 3)
    #expect(Set(calls).count == 1)
  }
}
