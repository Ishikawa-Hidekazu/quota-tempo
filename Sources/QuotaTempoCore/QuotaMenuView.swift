import SwiftUI

public enum QuotaMenuLayout {
  public static let width: CGFloat = 580
  static let contentWidth: CGFloat = 544
  static let detailLabelWidth: CGFloat = 160
  static let summaryWeeklyWidth: CGFloat = 82
  static let summaryTargetWidth: CGFloat = 82
  static let summaryDifferenceWidth: CGFloat = 92
  static let onboardingMinimumHeight: CGFloat = 650
  static let onboardingMaximumHeight: CGFloat = 760
  static let contentMinimumHeight: CGFloat = 810
  static let contentMaximumHeight: CGFloat = 900
  static let verticalPadding: CGFloat = 36
  static let screenClearance: CGFloat = 44
  static let absoluteMinimumViewportHeight: CGFloat = 320

  public static func viewportHeightRange(
    onboarding: Bool,
    availableHeight: CGFloat?
  ) -> ClosedRange<CGFloat> {
    let baseMinimum = onboarding ? self.onboardingMinimumHeight : self.contentMinimumHeight
    let baseMaximum = onboarding ? self.onboardingMaximumHeight : self.contentMaximumHeight
    guard let availableHeight else { return baseMinimum...baseMaximum }

    let availableViewport = max(
      self.absoluteMinimumViewportHeight,
      availableHeight - self.verticalPadding - self.screenClearance
    )
    let maximum = min(baseMaximum, availableViewport)
    return min(baseMinimum, maximum)...maximum
  }

  public static func applicationContentHeight(
    onboarding: Bool,
    availableHeight: CGFloat?
  ) -> CGFloat {
    self.viewportHeightRange(onboarding: onboarding, availableHeight: availableHeight)
      .upperBound + self.verticalPadding
  }

  public static func applicationMinimumContentHeight(
    onboarding: Bool,
    availableHeight: CGFloat?
  ) -> CGFloat {
    self.viewportHeightRange(onboarding: onboarding, availableHeight: availableHeight)
      .lowerBound + self.verticalPadding
  }
}

enum QuotaDateFormatting {
  static func string(_ value: Date?, locale: Locale, timeZone: TimeZone) -> String {
    guard let value else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("yMMMEdjm")
    return formatter.string(from: value)
  }
}

public struct QuotaMenuView: View {
  private let plans: [PlannedProvider]
  private let copy: MenuCopy
  private let locale: Locale
  private let timeZone: TimeZone
  private let availableHeight: CGFloat?
  private let onRefresh: (() -> Void)?
  private let onOpenWindow: (() -> Void)?
  private let onMenuOpen: (() -> Void)?
  private let onMenuClose: (() -> Void)?
  private let onQuit: (() -> Void)?
  private let refreshInFlight: Bool
  private let productVersion: String?
  private let privacyURL: URL?
  private let licenseURL: URL?
  private let updatesURL: URL?
  private let downloadURL: URL?
  private let thirdPartyNoticesURL: URL?
  private let supportURL: URL?
  private let enabledProviders: Set<ProviderID>
  private let loginItemState: LoginItemState
  private let loginItemChangeFailed: Bool
  private let onSetProviderEnabled: ((ProviderID, Bool) -> Void)?
  private let onCopyDiagnostics: (() -> Bool)?
  @Binding private var menuBarDisplayMode: MenuBarDisplayMode
  @Binding private var onboardingPresented: Bool
  @Binding private var launchAtLogin: Bool
  @State private var diagnosticsCopied = false

  public init(
    scenario: FixtureScenario,
    languageCode: String = "en",
    locale: Locale? = nil,
    timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
    availableHeight: CGFloat? = nil,
    menuBarDisplayMode: Binding<MenuBarDisplayMode> = .constant(.full),
    onboardingPresented: Binding<Bool> = .constant(false),
    refreshInFlight: Bool = false,
    productVersion: String? = nil,
    privacyURL: URL? = nil,
    licenseURL: URL? = nil,
    updatesURL: URL? = nil,
    downloadURL: URL? = nil,
    thirdPartyNoticesURL: URL? = nil,
    supportURL: URL? = nil,
    enabledProviders: Set<ProviderID> = Set(ProviderID.allCases),
    launchAtLogin: Binding<Bool> = .constant(false),
    loginItemState: LoginItemState = .disabled,
    loginItemChangeFailed: Bool = false,
    onSetProviderEnabled: ((ProviderID, Bool) -> Void)? = nil,
    onRefresh: (() -> Void)? = nil,
    onCopyDiagnostics: (() -> Bool)? = nil,
    onOpenWindow: (() -> Void)? = nil,
    onMenuOpen: (() -> Void)? = nil,
    onMenuClose: (() -> Void)? = nil,
    onQuit: (() -> Void)? = nil
  ) {
    self.plans = QuotaPlanner.evaluateUnique(scenario.snapshots, now: scenario.now)
    self.copy = MenuCopy(languageCode: languageCode)
    self.locale = locale ?? Locale(identifier: languageCode)
    self.timeZone = timeZone
    self.availableHeight = availableHeight
    self._menuBarDisplayMode = menuBarDisplayMode
    self._onboardingPresented = onboardingPresented
    self._launchAtLogin = launchAtLogin
    self.refreshInFlight = refreshInFlight
    self.productVersion = productVersion
    self.privacyURL = privacyURL
    self.licenseURL = licenseURL
    self.updatesURL = updatesURL
    self.downloadURL = downloadURL
    self.thirdPartyNoticesURL = thirdPartyNoticesURL
    self.supportURL = supportURL
    self.enabledProviders = enabledProviders
    self.loginItemState = loginItemState
    self.loginItemChangeFailed = loginItemChangeFailed
    self.onSetProviderEnabled = onSetProviderEnabled
    self.onRefresh = onRefresh
    self.onCopyDiagnostics = onCopyDiagnostics
    self.onOpenWindow = onOpenWindow
    self.onMenuOpen = onMenuOpen
    self.onMenuClose = onMenuClose
    self.onQuit = onQuit
  }

  public var body: some View {
    let viewportHeight = QuotaMenuLayout.viewportHeightRange(
      onboarding: self.onboardingPresented,
      availableHeight: self.availableHeight
    )
    VStack(alignment: .leading, spacing: 16) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            Color.clear
              .frame(height: 0)
              .id("quota-menu-top")
            Group {
              if self.onboardingPresented {
                self.onboarding
              } else {
                self.mainContent
              }
            }
          }
          .frame(width: QuotaMenuLayout.contentWidth, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
        .scrollIndicators(.visible)
        .frame(
          minHeight: viewportHeight.lowerBound,
          maxHeight: viewportHeight.upperBound
        )
        .onAppear { proxy.scrollTo("quota-menu-top", anchor: .top) }
      }
    }
    .padding(18)
    .frame(width: QuotaMenuLayout.width)
    .background(.background)
    .onAppear {
      self.diagnosticsCopied = false
      self.onMenuOpen?()
    }
    .onDisappear { self.onMenuClose?() }
  }

  private var mainContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("QuotaTempo")
          .font(.title2.weight(.semibold))
        Text(self.copy.text("tagline"))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 10) {
        HStack(spacing: 12) {
          Spacer(minLength: 0)
          self.summaryCell(
            self.copy.text("weekly.left"),
            width: QuotaMenuLayout.summaryWeeklyWidth,
            isHeader: true
          )
          self.summaryCell(
            self.copy.text("target.now"),
            width: QuotaMenuLayout.summaryTargetWidth,
            isHeader: true
          )
          self.summaryCell(
            self.copy.text("vs.target"),
            width: QuotaMenuLayout.summaryDifferenceWidth,
            isHeader: true
          )
        }

        Divider()

        ForEach(self.plans) { plan in
          HStack(spacing: 12) {
            HStack(spacing: 7) {
              ProviderIconView(provider: plan.provider, size: 18)
              Text(plan.provider.displayName).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            self.summaryCell(
              self.weeklyPercent(plan),
              width: QuotaMenuLayout.summaryWeeklyWidth
            )
            self.summaryCell(
              self.percent(plan.targetNow, estimated: plan.targetIsEstimated),
              width: QuotaMenuLayout.summaryTargetWidth
            )
            self.summaryCell(
              self.points(plan),
              width: QuotaMenuLayout.summaryDifferenceWidth
            )
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(self.accessibilitySummary(plan))
        }
      }

      Divider()

      ForEach(self.plans) { plan in
        self.detail(plan)
        if plan.id != self.plans.last?.id { Divider() }
      }

      Text(self.copy.text("comparison.note"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 8) {
        Text(self.copy.text("providers"))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        HStack(spacing: 22) {
          ForEach(ProviderID.allCases, id: \.self) { provider in
            Toggle(
              isOn: Binding(
                get: { self.enabledProviders.contains(provider) },
                set: { self.onSetProviderEnabled?(provider, $0) }
              )
            ) {
              HStack(spacing: 7) {
                ProviderIconView(provider: provider, size: 15)
                Text(provider.displayName)
              }
            }
            .toggleStyle(.switch)
            .disabled(
              self.enabledProviders.count == 1 && self.enabledProviders.contains(provider)
            )
          }
        }
        Text(self.copy.text("providers.note"))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Toggle(self.copy.text("launch.at.login"), isOn: self.$launchAtLogin)
          .toggleStyle(.switch)
          .disabled(
            self.loginItemState == .unavailable
              || self.loginItemState == .requiresMoveToApplications
          )
        Text(self.loginItemMessage)
          .font(.caption2)
          .foregroundStyle(
            self.loginItemChangeFailed || self.loginItemState == .requiresApproval
              ? .orange : .secondary
          )
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(self.copy.text("menu.bar.mode"))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Picker(self.copy.text("menu.bar.mode"), selection: self.$menuBarDisplayMode) {
          ForEach(MenuBarDisplayMode.allCases) { mode in
            Text(self.copy.text("menu.bar.mode.\(mode.rawValue)"))
              .tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(self.copy.text("menu.bar.legend"))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if self.onRefresh != nil || self.onCopyDiagnostics != nil || self.onQuit != nil {
        HStack {
          if let onRefresh {
            Button(action: onRefresh) {
              Label(
                self.copy.text(self.refreshInFlight ? "refreshing" : "refresh"),
                systemImage: "arrow.clockwise"
              )
            }
            .accessibilityLabel(
              self.copy.text(self.refreshInFlight ? "refreshing" : "refresh")
            )
            .disabled(self.refreshInFlight)
          }
          if let onCopyDiagnostics {
            Button {
              self.diagnosticsCopied = onCopyDiagnostics()
            } label: {
              Label(
                self.copy.text(self.diagnosticsCopied ? "diagnostics.copied" : "copy.diagnostics"),
                systemImage: self.diagnosticsCopied ? "checkmark" : "doc.on.doc"
              )
            }
            .accessibilityLabel(
              self.copy.text(self.diagnosticsCopied ? "diagnostics.copied" : "copy.diagnostics")
            )
          }
          Spacer()
          if let onQuit {
            Button(action: onQuit) {
              Label(self.copy.text("quit"), systemImage: "power")
            }
            .accessibilityLabel(self.copy.text("quit"))
          }
        }

        HStack {
          if let onOpenWindow {
            Button(action: onOpenWindow) {
              Label(self.copy.text("open.window"), systemImage: "macwindow")
            }
            .accessibilityLabel(self.copy.text("open.window"))
          }
          Button(self.copy.text("how.to.read")) {
            self.onboardingPresented = true
          }
          .buttonStyle(.link)
          .accessibilityLabel(self.copy.text("how.to.read"))
          Spacer()
          if let productVersion {
            Text("\(self.copy.text("version")) \(productVersion)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if self.hasPolicyLinks {
            Menu(self.copy.text("legal")) {
              if let privacyURL {
                Link(self.copy.text("privacy"), destination: privacyURL)
              }
              if let licenseURL {
                Link(self.copy.text("license"), destination: licenseURL)
              }
              if let updatesURL {
                Link(self.copy.text("updates"), destination: updatesURL)
              }
              if let downloadURL {
                Link(self.copy.text("download.latest"), destination: downloadURL)
              }
              if let thirdPartyNoticesURL {
                Link(self.copy.text("third.party.notices"), destination: thirdPartyNoticesURL)
              }
              if let supportURL {
                Link(self.copy.text("support"), destination: supportURL)
              }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .accessibilityLabel(self.copy.text("legal"))
          }
        }
      }
    }
  }

  private var hasPolicyLinks: Bool {
    self.privacyURL != nil || self.licenseURL != nil || self.updatesURL != nil
      || self.downloadURL != nil || self.thirdPartyNoticesURL != nil || self.supportURL != nil
  }

  private var onboarding: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(self.copy.text("onboarding.title"))
          .font(.title2.weight(.semibold))
        Text(self.copy.text("onboarding.intro"))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 11) {
        self.onboardingRow("person.2", "onboarding.providers")
        self.onboardingRow("calendar", "onboarding.weekly")
        self.onboardingRow("scope", "onboarding.plan")
        self.onboardingRow("approximately.equal", "onboarding.estimate")
        self.onboardingRow("arrow.up.arrow.down", "onboarding.difference")
        self.onboardingRow("lock.shield", "onboarding.privacy")
      }

      self.menuBarModeGuide

      Text(self.copy.text("onboarding.reopen"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button(self.copy.text("quit")) {
          self.onQuit?()
        }
        .accessibilityLabel(self.copy.text("quit"))

        Spacer()
        Button(self.copy.text("got.it")) {
          self.onboardingPresented = false
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(self.copy.text("got.it"))
      }
    }
  }

  private var menuBarModeGuide: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(self.copy.text("onboarding.menu.title"))
        .font(.headline)
      Text(self.copy.text("onboarding.menu.intro"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 8) {
        self.menuBarModePreview(.full)
        self.menuBarModePreview(.compact)
        self.menuBarModePreview(.iconOnly)
      }

      Picker(self.copy.text("menu.bar.mode"), selection: self.$menuBarDisplayMode) {
        ForEach(MenuBarDisplayMode.allCases) { mode in
          Text(self.copy.text("menu.bar.mode.\(mode.rawValue)"))
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      Text(self.copy.text("onboarding.menu.note"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private func menuBarModePreview(_ mode: MenuBarDisplayMode) -> some View {
    HStack(spacing: 12) {
      Text(self.copy.text("menu.bar.mode.\(mode.rawValue)"))
        .font(.caption.weight(.semibold))
        .frame(width: 76, alignment: .leading)

      HStack(spacing: 7) {
        switch mode {
        case .full:
          ProviderIconView(provider: .codex, size: 14)
          Text("W39/P58 ↓19")
          Text("·").foregroundStyle(.secondary)
          ProviderIconView(provider: .claude, size: 14)
          Text("W30/P55 ↓25")
        case .compact:
          ProviderIconView(provider: .codex, size: 14)
          Text("39↓19")
          Text("·").foregroundStyle(.secondary)
          ProviderIconView(provider: .claude, size: 14)
          Text("30↓25")
        case .iconOnly:
          Image(systemName: "metronome")
        }
      }
      .font(.caption.monospacedDigit())
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  private func onboardingRow(_ systemImage: String, _ key: String) -> some View {
    GridRow {
      Image(systemName: systemImage)
        .frame(width: 20)
        .foregroundStyle(.secondary)
      Text(self.copy.text(key))
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.callout)
  }

  private var loginItemMessage: String {
    if self.loginItemChangeFailed { return self.copy.text("login.item.failed") }
    switch self.loginItemState {
    case .disabled, .enabled:
      return self.copy.text("launch.at.login.note")
    case .requiresApproval:
      return self.copy.text("login.item.requires.approval")
    case .requiresMoveToApplications:
      return self.copy.text("login.item.move.to.applications")
    case .unavailable:
      return self.copy.text("login.item.unavailable")
    }
  }

  private func summaryCell(_ value: String, width: CGFloat, isHeader: Bool = false) -> some View {
    Text(value)
      .font(isHeader ? .caption.weight(.semibold) : .body)
      .foregroundStyle(isHeader ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(width: width, alignment: .trailing)
  }

  private func detail(_ plan: PlannedProvider) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        HStack(spacing: 7) {
          ProviderIconView(provider: plan.provider, size: 17)
          Text(plan.provider.displayName).font(.headline)
        }
        .layoutPriority(1)
        Spacer()
        Text(self.copy.status(plan.status))
          .font(.subheadline.weight(.medium))
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 240, alignment: .trailing)
      }

      VStack(alignment: .leading, spacing: 5) {
        self.detailRow(
          plan.weeklyResetIsEstimated ? "weekly.reset.estimated" : "weekly.reset",
          value: self.date(plan.weeklyResetAt)
        )
        self.detailRow("next.checkpoint", value: self.date(plan.nextCheckpoint))
        self.detailRow("checkpoint.target", value: self.percent(plan.checkpointTarget))
        self.detailRow("available.until", value: self.percent(plan.availableUntilCheckpoint))
        if plan.targetIsEstimated {
          self.detailRow("target.basis", value: self.copy.text("target.basis.estimated"))
        }
        self.detailRow("source", value: self.copy.source(plan.source))
        if plan.provider == .codex, let executableSource = plan.codexExecutableSource {
          self.detailRow(
            "codex.executable.source",
            value: self.copy.codexExecutableSource(executableSource)
          )
        }
        if plan.provider == .codex, let executableVersion = plan.codexExecutableVersion {
          self.detailRow("codex.executable.version", value: executableVersion)
        }
        self.detailRow("freshness", value: self.copy.freshness(plan.freshness))
        self.detailRow("captured.at", value: self.date(plan.capturedAt))
        if let state = plan.sourceState {
          self.detailRow("source.state", value: self.copy.sourceState(state))
        }
        if let lastAttemptAt = plan.lastAttemptAt, plan.errorCode != nil {
          self.detailRow("last.attempt", value: self.date(lastAttemptAt))
        }
        if let errorCode = plan.errorCode {
          self.detailRow("acquisition.error", value: self.copy.error(errorCode))
        }
        if plan.freshness == .stale, plan.targetNow != nil {
          Text(self.staleComparisonHelp(plan))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if plan.provider == .claude {
          Text(self.copy.text("claude.local.boundary"))
            .font(.caption)
            .foregroundStyle(.secondary)
          if plan.status == .resetUnknown {
            Text(self.copy.text("claude.reset.help"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if plan.fiveHourRisk {
        Label(self.copy.text("five.hour.risk"), systemImage: "exclamationmark.triangle")
          .font(.caption.weight(.medium))
          .foregroundStyle(.orange)
          .accessibilityLabel(self.copy.text("five.hour.risk.accessibility"))
      }
    }
  }

  private func detailRow(_ key: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      Text(self.copy.text(key))
        .foregroundStyle(.secondary)
        .frame(width: QuotaMenuLayout.detailLabelWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      Text(value)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func percent(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(QuotaPlanner.roundedPercent(value))%"
  }

  private func percent(_ value: Double?, estimated: Bool) -> String {
    guard let value else { return "—" }
    let marker = estimated ? "≈" : ""
    return "\(marker)\(QuotaPlanner.roundedPercent(value))%"
  }

  private func weeklyPercent(_ plan: PlannedProvider) -> String {
    let value = self.percent(plan.weeklyRemaining)
    guard plan.weeklyRemaining != nil, plan.freshness == .stale else { return value }
    return "\(value)?"
  }

  private func staleComparisonHelp(_ plan: PlannedProvider) -> String {
    self.copy.text(
      plan.targetIsEstimated
        ? "stale.comparison.estimated.help" : "stale.comparison.confirmed.help"
    )
  }

  private func points(_ plan: PlannedProvider) -> String {
    guard
      let displayed = QuotaPlanner.displayedDifference(
        weeklyRemaining: plan.weeklyRemaining,
        targetNow: plan.targetNow
      ), plan.vsTarget != nil
    else { return "—" }
    return "\(displayed > 0 ? "+" : "")\(displayed) pts"
  }

  private func date(_ value: Date?) -> String {
    QuotaDateFormatting.string(value, locale: self.locale, timeZone: self.timeZone)
  }

  private func accessibilitySummary(_ plan: PlannedProvider) -> String {
    var parts = [
      plan.provider.displayName,
      "\(self.copy.text("weekly.left")) \(self.weeklyPercent(plan))",
      "\(self.copy.text("target.now")) \(self.percent(plan.targetNow, estimated: plan.targetIsEstimated))",
      "\(self.copy.text("vs.target")) \(self.points(plan))",
      "\(self.copy.text("captured.at")) \(self.date(plan.capturedAt))",
      plan.provider == .claude ? self.copy.text("claude.local.boundary") : "",
      plan.freshness == .stale && plan.targetNow != nil
        ? self.staleComparisonHelp(plan) : "",
      plan.provider == .claude && plan.status == .resetUnknown
        ? self.copy.text("claude.reset.help") : "",
      plan.errorCode.map { "\(self.copy.text("acquisition.error")) \(self.copy.error($0))" } ?? "",
      plan.targetIsEstimated ? self.copy.text("target.basis.estimated") : "",
      self.copy.status(plan.status),
    ]
    if plan.provider == .codex, let source = plan.codexExecutableSource {
      parts.append(
        "\(self.copy.text("codex.executable.source")) \(self.copy.codexExecutableSource(source))")
    }
    if plan.provider == .codex, let version = plan.codexExecutableVersion {
      parts.append("\(self.copy.text("codex.executable.version")) \(version)")
    }
    return parts.filter { !$0.isEmpty }.joined(separator: ", ")
  }
}
