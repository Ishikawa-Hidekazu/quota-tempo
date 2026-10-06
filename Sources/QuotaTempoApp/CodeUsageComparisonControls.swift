import AppKit
import SwiftUI

@MainActor
struct CodeUsageComparisonControls: View {
  @ObservedObject var connection: CodeUsageComparisonController
  let enabled: Bool
  @Environment(\.locale) private var locale
  @Environment(\.openURL) private var openURL
  @State private var expanded = false
  @State private var showingConsent = false
  @State private var pending = false
  @State private var actionRevision = 0
  @State private var copiedCommand: String?
  @State private var preparedPackage: CodeComparisonPluginCommands?
  @State private var packageFailed = false
  @State private var showingPluginManagement = false

  init(
    connection: CodeUsageComparisonController, enabled: Bool, initiallyExpanded: Bool = false,
    initiallyPreparedPackage: CodeComparisonPluginCommands? = nil,
    initiallyExpandedManagement: Bool = false
  ) {
    self.connection = connection
    self.enabled = enabled
    _expanded = State(initialValue: initiallyExpanded)
    _preparedPackage = State(initialValue: initiallyPreparedPackage)
    _showingPluginManagement = State(initialValue: initiallyExpandedManagement)
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

        if Self.showsConnectionArguments(connection.view.status),
          let command = connection.command
        {
          Text(
            text(
              "Codeの入力欄で /quotatempo-probe を選び、下の接続用引数を実行してください。設定画面では接続できません。",
              "In Code's input, select /quotatempo-probe and run the connection arguments below. The settings screen does not connect."
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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
        if let package = connection.pluginPackage ?? preparedPackage {
          packageBody(package)
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

  static func showsConnectionArguments(_ status: CodeUsageComparisonStatus) -> Bool {
    status == .waitingForConnection
  }

  private var statusText: String {
    switch connection.view.status {
    case .disconnected:
      return text("比較用接続は解除されています。", "The comparison connection is disconnected.")
    case .preparing:
      return text("比較用接続を準備しています。", "Preparing the comparison connection.")
    case .waitingForConnection:
      return text(
        "Code側からの接続を待っています。準備だけでは接続しません。接続準備は15分で期限切れになります。",
        "Waiting for Code to connect. Preparation alone does not connect and expires after 15 minutes."
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

  private func commandBody(_ command: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: command)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        guard !busy, enabled, Self.showsConnectionArguments(connection.view.status),
          connection.command == command
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copiedCommand = pasteboard.setString(command, forType: .string) ? command : nil
      } label: {
        Label(
          copiedCommand == command
            ? text("コピーしました", "Copied") : text("接続用引数をコピー", "Copy connection arguments"),
          systemImage: copiedCommand == command ? "checkmark" : "doc.on.doc")
      }
      .disabled(busy || !enabled)
    }
  }

  private func packageBody(_ package: CodeComparisonPluginCommands) -> some View {
    DisclosureGroup(
      text("プラグインの導入・管理", "Plugin setup and management"),
      isExpanded: $showingPluginManagement
    ) {
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
            "Code接続のローカル検証版です。この追加機能は一般公開されていません。",
            "Local Code connection preview. This additional feature is not publicly released.")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          text(
            "導入・管理は、選んだprojectのセッションを閉じてから、手順書のlocal scope管理ツールで行います。Desktopのプラグイン設定画面ではこのローカル資材を追加できません。このアプリは導入結果を確認しません。",
            "Install or manage with the guide's local-scope management tool after closing the chosen project's sessions. Desktop's plugin settings cannot add this local package. This app does not verify installation."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Button {
          openURL(CodeComparisonPluginCommands.setupGuideURL)
        } label: {
          Label(
            text("導入・管理の手順書", "Setup and management guide"), systemImage: "book")
        }
        Text(verbatim: package.pluginID)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Text(verbatim: package.directory.path)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Text(
          text(
            "既に /quotatempo-probe status が固定応答を返す場合、再導入は不要です。接続解除だけではプラグインは無効化・削除されません。資材とmarketplaceは自動削除しません。",
            "If /quotatempo-probe status already returns its fixed response, do not reinstall. Disconnecting does not disable or uninstall the plugin. Packages and marketplaces are not removed automatically."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
          "Code専用previewの同梱プラグインを検証し、アプリ専用のprivate領域へ変更せず配置します。使用量はファイルへ保存しません。導入は別途、選んだprojectにlocal scopeで行います。接続はCodeの入力欄で登録されたコマンドから明示的に行います。このアプリはCLI起動、インストール、モデルへのリクエスト、画面の切り替えを行いません。",
          "Validates the Code preview's bundled plugin and stages unchanged bytes in private app-owned storage. Usage is not saved to files. Install separately at local scope in the chosen project, then explicitly connect using the registered command in Code's input. This app does not start a CLI, install plugins, request model responses or switch apps."
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
