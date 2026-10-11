import AppKit
import Foundation

struct FeedbackDraft {
  static let recipient = "h@ishikawa.co"
  static let subject = "QuotaTempo first-run feedback"

  let languageCode: String
  let publicAppVersion: String?

  var body: String {
    let copy = MenuCopy(languageCode: self.languageCode)
    return copy.text("feedback.draft").replacingOccurrences(
      of: "{public_app_version}", with: self.version ?? copy.text("feedback.unknown.version"))
  }

  var url: URL? {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    // RFC 6068 requires CRLF body lines and escaping mailto delimiters once.
    guard let subject = Self.subject.addingPercentEncoding(withAllowedCharacters: unreserved),
      let body = self.body.replacingOccurrences(of: "\n", with: "\r\n")
        .addingPercentEncoding(withAllowedCharacters: unreserved)
    else { return nil }
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = Self.recipient
    components.percentEncodedQueryItems = [
      URLQueryItem(name: "subject", value: subject),
      URLQueryItem(name: "body", value: body),
    ]
    return components.url
  }

  var productURL: URL {
    URL(
      string: self.languageCode.lowercased().hasPrefix("ja")
        ? "https://ishikawa.co/products/quotatempo/"
        : "https://ishikawa.co/en/products/quotatempo/"
    )!
  }

  // Accept public stable/RC identifiers, never arbitrary bundle text.
  private var version: String? {
    guard let value = self.publicAppVersion else { return nil }
    let release = value.split(separator: "-", omittingEmptySubsequences: false)
    guard (1...2).contains(release.count) else { return nil }
    let parts = release[0].split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts.allSatisfy(Self.isVersionNumber)
    else { return nil }
    if release.count == 2 {
      let candidate = release[1].split(separator: ".", omittingEmptySubsequences: false)
      guard candidate.count == 2, candidate[0] == "rc", Self.isVersionNumber(candidate[1])
      else { return nil }
    }
    return value
  }

  private static func isVersionNumber(_ part: Substring) -> Bool {
    (1...4).contains(part.utf8.count) && part.utf8.allSatisfy { (48...57).contains($0) }
  }
}

@MainActor
final class FeedbackDraftController: ObservableObject {
  @Published private(set) var openingFailed = false
  let draft: FeedbackDraft
  private let open: @MainActor (URL) -> Bool

  init(
    draft: FeedbackDraft,
    open: @escaping @MainActor (URL) -> Bool = FeedbackDraftController.openMailApp
  ) {
    self.draft = draft
    self.open = open
  }

  func openDraft() {
    guard let url = self.draft.url else {
      self.openingFailed = true
      return
    }
    self.openingFailed = !self.open(url)
  }

  private static func openMailApp(_ url: URL) -> Bool {
    guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
    return NSWorkspace.shared.open(url)
  }
}
