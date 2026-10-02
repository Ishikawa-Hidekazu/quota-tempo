#if DESKTOP_INTEGRATION_PREVIEW
  import QuotaTempoCore
  import QuotaTempoDesktopCandidate
  import SwiftUI

  struct DesktopIntegrationConfiguration {
    let providerDisabled: Bool
    let appDirectory: URL
    let schedulingDirectory: URL

    init(arguments: [String], supportDirectory: URL) {
      providerDisabled =
        arguments.contains("--provider-disabled")
        || arguments.contains("--storage-directory")
      if let index = arguments.firstIndex(of: "--storage-directory"), index + 1 < arguments.count {
        appDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
      } else {
        appDirectory = supportDirectory.appendingPathComponent(
          "QuotaTempoIntegrationPreview", isDirectory: true)
      }
      schedulingDirectory =
        providerDisabled
        ? appDirectory.appendingPathComponent("DesktopConnection", isDirectory: true)
        : supportDirectory.appendingPathComponent("QuotaTempoDesktopPreview", isDirectory: true)
    }
  }

  enum DesktopIntegrationPresentation {
    static func scenario(base: FixtureScenario, desktop: ProviderSnapshot?, enabled: Bool)
      -> FixtureScenario
    {
      var snapshots = base.snapshots.filter { $0.provider != .claude }
      if enabled {
        snapshots.append(
          desktop
            ?? ProviderSnapshot(
              provider: .claude, source: .claudeDesktopDirect, capturedAt: nil, weekly: nil,
              sourceState: .neverObserved))
      }
      return FixtureScenario(id: base.id, now: base.now, snapshots: snapshots)
    }
  }

  struct DesktopIntegrationControls: View {
    @ObservedObject var connection: DesktopConnectionController
    @Environment(\.locale) private var locale
    let allowsConnection: @MainActor () -> Bool
    @State private var confirmsConnection = false
    @State private var confirmsRepair = false
    private var japanese: Bool { locale.language.languageCode?.identifier == "ja" }
    private func text(_ ja: String, _ en: String) -> String { japanese ? ja : en }
    private var statusText: String {
      guard japanese else { return connection.statusText }
      switch connection.status {
      case .disconnected: return "Desktop接続は解除されています。"
      case .consentRequired: return "ローカル検証への同意が必要です。"
      case .connecting: return "Claude Desktopへ接続しています。"
      case .ready: return "Desktop接続の準備ができました。"
      case .current: return "Desktopの最新の使用量を取得しました。"
      case .stale: return "現在のDesktop使用量を確認できません。"
      case .waitingForNextRefresh: return "次回の自動取得を待っています。"
      case .waitingForProvider: return "提供元が指定した期限まで取得を停止しています。"
      case .renewalRequired: return "Desktopの認証更新、または接続の再確認が必要です。"
      case .accessDenied: return "Desktopの使用量へのアクセスが制限されています。"
      case .sourceUnavailable: return "Desktop接続を利用できません。"
      case .temporaryFailure: return "一時的にDesktopへ接続できません。"
      case .invalidResponse: return "Desktopの使用量を検証できませんでした。"
      case .invalidClock: return "このMacの時刻を確認できません。"
      case .serviceWaitUnavailable: return "待機期限を扱えないため、自動取得を停止しています。"
      case .storageUnavailable: return "ローカルの取得記録を保存または検証できません。"
      case .storeInUse: return "別のDesktopプレビューが取得記録を使用中です。先に終了してください。"
      case .waitingForIdle: return "前の取得処理の終了を待ってから操作してください。"
      case .repairing: return "取得記録を修復しています。"
      case .repaired: return "取得記録を確認しました。再接続には同意が必要です。"
      case .repairUnsupported: return "取得記録がこのバージョンに対応していません。"
      case .restartRequired: return "取得記録が使用中です。アプリの再起動が必要です。"
      case .consentStorageUnavailable: return "接続を停止しました。同意設定を保存または確認できません。"
      case .keychainPermissionRequired: return "Claude Desktopの認証を使用するにはmacOSの許可が必要です。"
      case .requestingKeychainAccess: return "macOSのアクセス許可への応答を待っています。"
      }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        Divider()
        Text(text("Claude Desktop 接続・ローカル検証版", "Claude Desktop connection · Local preview"))
          .font(.headline)
        Text(statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if connection.consentPersistenceFailed {
          Text(
            text(
              "同意設定を保存できていません。再起動後の接続状態は保証できません。",
              "The consent preference was not saved. Connection state after restart is not guaranteed."
            )
          )
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
        }
        if let next = connection.nextAllowedAt {
          HStack {
            Text(text("次回取得可能", "Next allowed update"))
            Text(next, style: .date)
            Text(next, style: .time)
          }.font(.caption)
        }
        if connection.canRequestKeychainAccess {
          Button {
            Task {
              guard allowsConnection() else { return }
              await connection.requestKeychainAccess()
            }
          } label: {
            Label(text("macOSアクセスを許可", "Allow macOS access"), systemImage: "lock.open")
          }.disabled(!allowsConnection())
          Text(
            text(
              "macOSの確認画面で「常に許可」を選ぶと、以後の取得をバックグラウンドで行えます。キャンセルすると接続は再開しません。",
              "Choose Always Allow in the macOS dialog to enable background access. Cancelling does not resume the connection."
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 12) {
          if connection.isConnected {
            Button {
              connection.revokeConsent()
            } label: {
              Label(text("接続解除", "Disconnect"), systemImage: "xmark.circle")
            }
            Button {
              Task {
                guard allowsConnection() else { return }
                await connection.refresh(recheck: true)
              }
            } label: {
              Label(text("接続を再確認", "Recheck connection"), systemImage: "arrow.clockwise")
            }
            .disabled(
              connection.isRefreshing || connection.isRepairing
                || connection.isRequestingKeychainAccess || !allowsConnection())
          } else {
            Button {
              confirmsConnection = true
            } label: {
              Label(text("Desktopへ接続", "Connect Desktop"), systemImage: "link")
            }.disabled(
              connection.isRepairing || connection.isRequestingKeychainAccess || !allowsConnection()
            )
          }
          Button {
            confirmsRepair = true
          } label: {
            Label(text("取得記録を修復", "Repair scheduling state"), systemImage: "wrench")
          }.disabled(
            connection.isRefreshing || connection.isRepairing
              || connection.isRequestingKeychainAccess || !allowsConnection())
        }
        Divider()
      }
      .confirmationDialog(
        text("Desktop接続を許可しますか？", "Allow Desktop connection?"),
        isPresented: $confirmsConnection, titleVisibility: .visible
      ) {
        Button(text("同意して接続", "Agree and connect")) {
          Task {
            guard allowsConnection() else { return }
            await connection.connect(localExperimentAuthorized: true)
          }
        }
        Button(text("キャンセル", "Cancel"), role: .cancel) {}
      } message: {
        Text(
          text(
            "このMacのClaude Desktop認証を端末内で使用し、Anthropicから使用量とリセット日時を取得します。認証情報や会話は保存しません。提供元の許諾は未確認のローカル実験です。同意設定を保存し、次回のアプリ起動後も自動接続します。接続解除またはClaudeをOFFにすると同意を取り消します。",
            "Uses Claude Desktop authentication locally on this Mac to request usage and reset times from Anthropic. Credentials and conversations are not saved. Provider permission is unconfirmed; this is a local experiment. Saves your consent and reconnects after app restarts. Disconnecting or turning Claude off revokes consent."
          ))
      }
      .confirmationDialog(
        text("取得記録を修復しますか？", "Repair scheduling state?"),
        isPresented: $confirmsRepair, titleVisibility: .visible
      ) {
        Button(text("修復", "Repair")) {
          Task {
            guard allowsConnection() else { return }
            await connection.repair()
          }
        }
        Button(text("キャンセル", "Cancel"), role: .cancel) {}
      } message: {
        Text(
          text(
            "接続を解除してローカル記録を検証します。提供元から指定された待機期限は消去しません。通信は行わず、再接続には再度同意が必要です。",
            "Disconnects and verifies local scheduling state without network access. Known provider deadlines are preserved. Reconnecting requires consent again."
          ))
      }
    }
  }
#endif
