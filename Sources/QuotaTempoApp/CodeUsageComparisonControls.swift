import AppKit
import SwiftUI

@MainActor
struct CodeUsageComparisonControls: View {
  @ObservedObject var connection: CodeUsageComparisonController
  let enabled: Bool
  @Environment(\.locale) private var locale
  @State private var expanded = false
  @State private var showingConsent = false
  @State private var pending = false
  @State private var actionRevision = 0
  @State private var copiedCommand: String?
  @State private var preparedPackage: CodeComparisonPluginCommands?
  @State private var packageFailed = false

  init(
    connection: CodeUsageComparisonController, enabled: Bool, initiallyExpanded: Bool = false,
    initiallyPreparedPackage: CodeComparisonPluginCommands? = nil
  ) {
    self.connection = connection
    self.enabled = enabled
    _expanded = State(initialValue: initiallyExpanded)
    _preparedPackage = State(initialValue: initiallyPreparedPackage)
  }

  private var japanese: Bool { locale.language.languageCode?.identifier == "ja" }
  private func text(_ ja: String, _ en: String) -> String { japanese ? ja : en }
  private var busy: Bool {
    pending || connection.isBusy || connection.view.status == .preparing
  }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          text(
            "比較用です。取得元・アカウントは未確認で、W/Pや計画には反映しません。",
            "Comparison only. Source and account are unverified; values do not affect W/P or planning."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if !enabled {
          Text(
            text(
              "ClaudeがOFFのため接続操作はできません。", "Connection controls are unavailable while Claude is off."
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        if packageFailed {
          Text(
            text(
              "同梱プラグインを安全に配置できません。Code専用previewと資材を確認してください。インストールは実行していません。",
              "The bundled plugin could not be staged safely. Check the Code preview and its resources. No installation was performed."
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        if let package = connection.pluginPackage ?? preparedPackage {
          packageBody(package)
        }

        HStack(alignment: .top, spacing: 8) {
          if busy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel(
                text("Claude Codeの比較用接続を処理中", "Processing Claude Code comparison connection"))
          }
          Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if enabled && connection.view.status == .comparisonOnly {
          if let weekly = connection.view.weekly {
            window(text("週間", "Weekly"), value: weekly)
          }
          if let fiveHour = connection.view.fiveHour {
            window(text("5時間", "5-hour"), value: fiveHour)
          }
        }
        if let receivedAt = connection.view.receivedAt,
          connection.view.status != .disconnected
        {
          timestamp(text("Code観測日時", "Code observed"), date: receivedAt)
        }

        if connection.view.status != .disconnected && connection.view.status != .preparing,
          let command = connection.command
        {
          commandBody(command)
        }

        if showingConsent {
          consentBody
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    } label: {
      Label(text("Claude Codeの使用量", "Claude Code usage"), systemImage: "terminal")
    }
    .fixedSize(horizontal: false, vertical: true)
    .onChange(of: expanded) { _, isExpanded in
      if !isExpanded { dismissConsent() }
    }
    .onChange(of: enabled) { _, isEnabled in
      if !isEnabled { dismissConsent() }
    }
    .onChange(of: connection.command) { _, _ in copiedCommand = nil }
    .onChange(of: connection.view.status) { _, _ in showingConsent = false }
    .onDisappear { dismissConsent() }
  }

  private var statusText: String {
    switch connection.view.status {
    case .disconnected:
      return text("比較用接続は解除されています。", "The comparison connection is disconnected.")
    case .preparing:
      return text("比較用接続を準備しています。", "Preparing the comparison connection.")
    case .waitingForConnection:
      return text(
        "初回はClaude Code側のメニューから接続コマンドを実行してください。準備だけでは接続しません。",
        "First run the connection command from Claude Code's menu. Preparation alone does not connect."
      )
    case .waitingForMeasurement:
      return text(
        "接続できました。Codeで通常の作業中に使用量が計測されると、値が表示されます。計測のためだけの追加リクエストは不要です。",
        "Connected. Values appear when Code measures usage during normal work. No request solely for measurement is needed."
      )
    case .comparisonOnly:
      return text(
        "比較用の使用量を受信しました。提供元の更新時刻は未確認です。",
        "Received comparison usage. The provider's observation time is unverified.")
    case .stale:
      return text(
        "値または接続準備の有効期限が切れました。再準備する場合は、Code側の接続もやり直してください。",
        "Values or connection preparation have expired. Preparing again also requires reconnecting in Code."
      )
    case .resetPassed:
      return text(
        "リセット時刻を過ぎたため残量を表示しません。次の計測を待ってください。",
        "The reset time has passed; values are withheld until another measurement.")
    case .multipleSessions:
      return text(
        "複数セッションを検出しました。値は統合せず、比較を停止しています。",
        "Multiple sessions detected. Comparison is paused without merging values.")
    case .unavailable:
      return text(
        "比較用の使用量を確認できません。Codeの接続状態を確認してください。",
        "Comparison usage is unavailable. Check the connection in Code.")
    case .invalidClock:
      return text(
        "このMacの時刻を確認できないため、残量を表示しません。",
        "Values are withheld because this Mac's clock could not be verified.")
    case .storageUnavailable:
      return text(
        "ローカルの比較用接続を準備または検証できません。",
        "The local comparison connection could not be prepared or verified.")
    }
  }

  private func commandBody(_ command: String, requiresConnection: Bool = true) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: command)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        guard !busy else { return }
        if requiresConnection {
          guard enabled, connection.command == command else { return }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copiedCommand = pasteboard.setString(command, forType: .string) ? command : nil
      } label: {
        Label(
          copiedCommand == command ? text("コピーしました", "Copied") : text("コマンドをコピー", "Copy command"),
          systemImage: copiedCommand == command ? "checkmark" : "doc.on.doc")
      }
      .disabled(busy || (requiresConnection && !enabled))
    }
  }

  private func packageBody(_ package: CodeComparisonPluginCommands) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        text(
          "プラグイン \(package.version) 配置済み・導入状況は未確認",
          "Plugin \(package.version) staged; installation unverified")
      )
      .font(.caption.weight(.semibold))
      .fixedSize(horizontal: false, vertical: true)
      Text(
        text(
          "ローカルpreviewです。ad-hoc署名は配布元の信頼性を保証しません。",
          "Local preview. Ad-hoc signing does not establish publisher trust.")
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Text(
        text(
          "選んだローカルprojectのCodeで順に確認してください。導入画面ではlocal-onlyを選びます。起動中のセッションで読み込めたことを確認してから接続してください。",
          "Review these in Code in the chosen local project, in order. Choose local-only in the installation panel and confirm loading in the active session before connecting."
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      commandBody(package.marketplaceAdd, requiresConnection: false)
      commandBody(package.install, requiresConnection: false)
      DisclosureGroup(text("プラグインの管理", "Plugin management")) {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            text(
              "各コマンドはCodeの管理画面を開きます。表示されたIDとlocal scopeを確認してください。実行結果はこのアプリでは確認しません。接続解除だけではプラグインは無効化・削除されません。資材とmarketplaceは自動削除しません。",
              "These commands open Code's management panel. Check the displayed ID and local scope. This app does not verify their results. Disconnecting does not disable or uninstall the plugin. Packages and marketplaces are not removed automatically."
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Text(verbatim: package.pluginID)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          commandBody(package.disable, requiresConnection: false)
          commandBody(package.enable, requiresConnection: false)
          commandBody(package.uninstall, requiresConnection: false)
        }
      }
    }
  }

  private var actionButtons: some View {
    Group {
      if connection.view.status == .disconnected || connection.command == nil {
        Button {
          guard enabled, !busy else { return }
          showingConsent = true
        } label: {
          Label(text("接続の準備", "Prepare connection"), systemImage: "link")
        }
        .disabled(!enabled || busy)
      } else {
        Button {
          perform { await connection.refresh() }
        } label: {
          Label(text("更新", "Refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(!enabled || busy)
        Button {
          guard enabled else { return }
          dismissConsent()
          Task { await connection.disconnect() }
        } label: {
          Label(text("接続解除", "Disconnect"), systemImage: "xmark.circle")
        }
        .disabled(!enabled)
        if connection.view.status == .stale || connection.view.status == .multipleSessions {
          Button {
            guard enabled, !busy else { return }
            showingConsent = true
          } label: {
            Label(text("接続を再準備", "Prepare again"), systemImage: "link")
          }
          .disabled(!enabled || busy)
        }
      }
    }
  }

  private var consentBody: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text("比較用接続への同意", "Comparison connection consent"))
        .font(.subheadline.weight(.semibold))
      Text(
        text(
          "Code専用previewの同梱プラグインを検証し、アプリ専用のprivate領域へ変更せず配置します。使用量はファイルへ保存しません。導入は選んだprojectのCode内で行い、local-onlyを選びます。接続もCode側のメニューから明示的に行います。このアプリはCLI起動、インストール、モデルへのリクエスト、画面の切り替えを行いません。",
          "Validates the Code preview's bundled plugin and stages unchanged bytes in private app-owned storage. Usage is not saved to files. Install explicitly inside Code in the chosen project using local-only, then connect from Code's menu. This app does not start a CLI, install plugins, request model responses or switch apps."
        )
      )
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { consentButtons }
        VStack(alignment: .leading, spacing: 8) { consentButtons }
      }
    }
    .padding(.vertical, 8)
  }

  private var consentButtons: some View {
    Group {
      Button {
        guard showingConsent, enabled, !busy else { return }
        perform { await prepareBundledConnection() }
      } label: {
        Label(text("同意して準備", "Agree and prepare"), systemImage: "checkmark.circle")
      }
      .disabled(!enabled || busy)
      Button(role: .cancel) {
        dismissConsent()
      } label: {
        Label(text("キャンセル", "Cancel"), systemImage: "xmark")
      }
    }
  }

  private func dismissConsent() {
    showingConsent = false
    copiedCommand = nil
    actionRevision += 1
  }

  private func perform(_ action: @escaping @MainActor () async -> Void) {
    guard enabled, !busy else { return }
    showingConsent = false
    pending = true
    let revision = actionRevision
    // Fence queued actions when the disclosure closes or the provider is disabled.
    Task { @MainActor in
      defer { pending = false }
      guard enabled, expanded, actionRevision == revision else { return }
      await action()
    }
  }

  private func prepareBundledConnection() async {
    let revision = actionRevision
    packageFailed = false
    do {
      let package = try await Task.detached(priority: .utility) {
        try CodeComparisonPluginPackage.stageBundled()
      }.value
      guard enabled, expanded, actionRevision == revision, !Task.isCancelled else { return }
      connection.rememberPluginPackage(package)
      await connection.prepare()
    } catch {
      guard enabled, expanded, actionRevision == revision else { return }
      preparedPackage = nil
      packageFailed = true
    }
  }

  private func window(_ title: String, value: CodeUsageComparisonWindow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(
        "\(title) · \(text("残り", "Remaining")) \(value.remainingPercent, format: .number.precision(.fractionLength(0...1)))%"
      )
      .font(.subheadline.monospacedDigit())
      .fixedSize(horizontal: false, vertical: true)
      timestamp(text("リセット", "Reset"), date: value.resetAt)
    }
  }

  private func timestamp(_ title: String, date: Date) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).foregroundStyle(.secondary)
      Text(date, format: .dateTime.year().month().day().hour().minute())
    }
    .font(.caption)
    .fixedSize(horizontal: false, vertical: true)
  }
}
