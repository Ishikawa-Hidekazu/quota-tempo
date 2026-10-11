import SwiftUI

struct FeedbackControls: View {
  private let copy: MenuCopy
  @StateObject private var controller: FeedbackDraftController

  init(languageCode: String, publicAppVersion: String?) {
    self.init(
      languageCode: languageCode,
      controller: FeedbackDraftController(
        draft: FeedbackDraft(languageCode: languageCode, publicAppVersion: publicAppVersion)))
  }

  init(languageCode: String, controller: FeedbackDraftController) {
    self.copy = MenuCopy(languageCode: languageCode)
    self._controller = StateObject(wrappedValue: controller)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        self.controller.openDraft()
      } label: {
        Label(self.copy.text("feedback.send"), systemImage: "envelope")
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("quotatempo-feedback")
      .accessibilityLabel(self.copy.text("feedback.send"))
      .accessibilityHint(self.copy.text("feedback.draft.explanation"))
      .help(self.copy.text("feedback.draft.explanation"))

      Text(self.copy.text("feedback.draft.explanation"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if self.controller.openingFailed {
        Text(self.copy.text("feedback.open.failed"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(FeedbackDraft.recipient)
          .textSelection(.enabled)
          .font(.caption)
        Link(self.copy.text("feedback.product.page"), destination: self.controller.draft.productURL)
          .accessibilityLabel(self.copy.text("feedback.product.page"))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
