import AppKit
import Combine
import Foundation
import QuotaTempoCore
import Sparkle
import SwiftUI

@MainActor
final class QuotaTempoUpdater {
  private let controller: SPUStandardUpdaterController?

  init(enabled: Bool = true, bundle: Bundle = .main) {
    guard enabled, bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
      self.controller = nil
      return
    }
    self.controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  var isEnabled: Bool { self.controller != nil }

  func checkForUpdates() {
    self.controller?.checkForUpdates(nil)
  }
}

@MainActor
final class LiveQuotaModel: ObservableObject {
  private static let providerQueue = DispatchQueue(
    label: "com.ishikawa.quotatempo.provider-refresh",
    qos: .utility,
    attributes: .concurrent
  )
  @Published private(set) var scenario: FixtureScenario
  @Published private(set) var refreshInFlight = false
  @Published private(set) var enabledProviders: Set<ProviderID>

  private let store: NormalizedSnapshotStore
  private let acquisitionGate: ProviderAcquisitionGate
  private let preferences: ProviderSelectionPreferences?
  private var selection: ProviderSelection
  private var initialDetectionPending: Bool
  private var initialDetectionTracker = InitialProviderDetectionTracker()
  private var initialDetectionSnapshots: [ProviderID: ProviderSnapshot] = [:]
  private var codexRefreshInFlight = false
  private var claudeRefreshInFlight = false
  private var transientSnapshots: [ProviderID: ProviderSnapshot] = [:]
  private var scenarioRevision = 0

  init(
    store: NormalizedSnapshotStore,
    acquisitionEnabled: Bool,
    preferences: ProviderSelectionPreferences? = nil
  ) {
    self.store = store
    self.acquisitionGate = ProviderAcquisitionGate(enabled: acquisitionEnabled)
    self.preferences = preferences
    let storedScenario = self.store.scenario(now: Date())
    if let configured = preferences?.load() {
      self.selection = configured
      self.initialDetectionPending = false
    } else if let detected = ProviderSelection.detected(in: storedScenario.snapshots) {
      self.selection = detected
      self.initialDetectionPending = false
      preferences?.save(detected)
    } else {
      self.selection = .all
      self.initialDetectionPending = preferences != nil
    }
    self.enabledProviders = self.selection.enabled
    self.scenario = self.selection.filtering(storedScenario)
    self.refreshCodex(trigger: .launch, force: false)
    self.refreshClaude(trigger: .launch, force: false)
  }

  func menuOpened() {
    self.reload()
    self.refreshCodex(trigger: .menuOpen, force: false)
    self.refreshClaude(trigger: .menuOpen, force: false)
  }

  func clockAdvanced() {
    let now = Date()
    self.scenario = FixtureScenario(
      id: self.scenario.id,
      now: now,
      snapshots: self.scenario.snapshots
    )
    self.scenarioRevision += 1
    let revision = self.scenarioRevision
    let store = self.store
    let transientSnapshots = self.transientSnapshots
    let selection = self.selection

    Task {
      let loaded = await Task.detached(priority: .utility) {
        let stored = store.scenario(now: now)
        let complete = SnapshotScenarioOverlay.apply(
          transientSnapshots,
          to: stored,
          now: now
        )
        return selection.filtering(complete)
      }.value
      guard self.scenarioRevision == revision else { return }
      self.scenario = loaded
    }
  }

  func scheduledRefresh() {
    self.reload()
    self.refreshCodex(trigger: .scheduledRefresh, force: false)
    self.refreshClaude(trigger: .scheduledRefresh, force: false)
  }

  func systemDidWake() {
    self.reload()
    self.refreshCodex(trigger: .systemWake, force: false)
    self.refreshClaude(trigger: .systemWake, force: false)
  }

  func explicitRefresh() {
    self.refreshCodex(trigger: .explicitRefresh, force: true)
    self.refreshClaude(trigger: .explicitRefresh, force: true)
  }

  func setProviderEnabled(_ provider: ProviderID, enabled: Bool) {
    let next = self.selection.setting(provider, enabled: enabled)
    guard next != self.selection else { return }
    self.selection = next
    self.enabledProviders = next.enabled
    self.initialDetectionPending = false
    self.preferences?.save(next)
    self.scenario = next.filtering(self.scenario)
    self.reload()
    guard enabled else { return }
    switch provider {
    case .codex:
      self.refreshCodex(trigger: .explicitRefresh, force: true)
    case .claude:
      self.refreshClaude(trigger: .explicitRefresh, force: true)
    }
  }

  private func reload() {
    self.scenarioRevision += 1
    let revision = self.scenarioRevision
    let now = Date()
    let store = self.store
    let transientSnapshots = self.transientSnapshots
    let selection = self.selection

    Task {
      let loaded = await Task.detached(priority: .utility) {
        let stored = store.scenario(now: now)
        let complete = SnapshotScenarioOverlay.apply(
          transientSnapshots,
          to: stored,
          now: now
        )
        return selection.filtering(complete)
      }.value
      guard self.scenarioRevision == revision else { return }
      self.scenario = loaded
    }
  }

  private func persist(_ snapshot: ProviderSnapshot) {
    do {
      try self.store.save(snapshot)
      self.transientSnapshots.removeValue(forKey: snapshot.provider)
    } catch {
      self.transientSnapshots[snapshot.provider] = AcquisitionRecords.preservingFailure(
        previous: snapshot,
        provider: snapshot.provider,
        source: snapshot.source,
        attemptedAt: snapshot.lastAttemptAt,
        state: .attemptFailed,
        error: .atomicWriteFailed
      )
    }
    self.finishInitialDetectionAttempt(snapshot.provider, snapshot: snapshot)
    self.reload()
  }

  private func finishInitialDetectionAttempt(
    _ provider: ProviderID,
    snapshot: ProviderSnapshot? = nil
  ) {
    guard self.initialDetectionPending else { return }
    if let snapshot { self.initialDetectionSnapshots[provider] = snapshot }
    guard self.initialDetectionTracker.record(provider) else { return }

    if let detected = ProviderSelection.detected(
      in: Array(self.initialDetectionSnapshots.values)
    ) {
      self.selection = detected
      self.enabledProviders = detected.enabled
    }
    self.preferences?.save(self.selection)
    self.initialDetectionPending = false
  }

  private func refreshCodex(trigger: ProviderAcquisitionTrigger, force: Bool) {
    guard self.acquisitionGate.performIfAllowed(trigger, operation: {}) else { return }
    guard self.selection.contains(.codex) || self.initialDetectionPending else { return }
    guard !self.codexRefreshInFlight else { return }

    self.codexRefreshInFlight = true
    self.updateRefreshInFlight()
    let store = self.store
    let transientSnapshots = self.transientSnapshots
    Task {
      let snapshot: ProviderSnapshot? = await withCheckedContinuation { continuation in
        Self.providerQueue.async {
          let previous = SnapshotScenarioOverlay.currentSnapshot(
            for: .codex,
            stored: (try? store.load(.codex)) ?? nil,
            overrides: transientSnapshots
          )
          let now = Date()
          guard
            force
              || CodexRateLimitAdapter.shouldRefresh(
                lastAttemptAt: previous?.lastAttemptAt,
                now: now
              )
          else {
            continuation.resume(returning: nil)
            return
          }
          continuation.resume(
            returning: CodexRateLimitAdapter().refresh(previous: previous, now: now))
        }
      }
      if let snapshot {
        self.persist(snapshot)
      } else {
        self.finishInitialDetectionAttempt(.codex)
      }
      self.codexRefreshInFlight = false
      self.updateRefreshInFlight()
    }
  }

  private func refreshClaude(trigger: ProviderAcquisitionTrigger, force: Bool) {
    guard self.acquisitionGate.performIfAllowed(trigger, operation: {}) else { return }
    guard self.selection.contains(.claude) || self.initialDetectionPending else { return }
    guard !self.claudeRefreshInFlight else { return }

    self.claudeRefreshInFlight = true
    self.updateRefreshInFlight()
    let store = self.store
    let transientSnapshots = self.transientSnapshots
    Task {
      let snapshot: ProviderSnapshot? = await withCheckedContinuation { continuation in
        Self.providerQueue.async {
          let previous = SnapshotScenarioOverlay.currentSnapshot(
            for: .claude,
            stored: (try? store.load(.claude)) ?? nil,
            overrides: transientSnapshots
          )
          let now = Date()
          guard
            force
              || ClaudeAutomaticAdapter.shouldRefresh(
                lastAttemptAt: previous?.lastAttemptAt,
                now: now
              )
          else {
            continuation.resume(returning: nil)
            return
          }
          continuation.resume(
            returning: ClaudeAutomaticAdapter().refresh(previous: previous, now: now))
        }
      }
      if let snapshot {
        self.persist(snapshot)
      } else {
        self.finishInitialDetectionAttempt(.claude)
      }
      self.claudeRefreshInFlight = false
      self.updateRefreshInFlight()
    }
  }

  private func updateRefreshInFlight() {
    self.refreshInFlight = self.codexRefreshInFlight || self.claudeRefreshInFlight
  }
}

enum LaunchPresentationPolicy {
  static func presentsInitialWindow(
    hasCompletedOnboarding: Bool,
    providerDisabled: Bool
  ) -> Bool {
    !hasCompletedOnboarding && !providerDisabled
  }

  static func presentsReopenedWindow(providerDisabled: Bool) -> Bool {
    !providerDisabled
  }
}

enum QuotaTempoAppDefaults {
  static let menuBarDisplayMode = MenuBarDisplayMode.iconOnly
}

@MainActor
final class QuotaTempoPresentationModel: ObservableObject {
  @Published var menuBarDisplayMode: MenuBarDisplayMode {
    didSet {
      self.defaults.set(self.menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode")
    }
  }
  @Published var onboardingPresented: Bool {
    didSet {
      if !self.onboardingPresented {
        if self.defaults.string(forKey: "menuBarDisplayMode") == nil {
          self.defaults.set(self.menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode")
        }
        self.defaults.set(true, forKey: "hasCompletedOnboarding")
      }
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    self.menuBarDisplayMode =
      defaults.string(forKey: "menuBarDisplayMode")
      .flatMap(MenuBarDisplayMode.init(rawValue:))
      ?? (hasCompletedOnboarding ? .full : QuotaTempoAppDefaults.menuBarDisplayMode)
    self.onboardingPresented = !hasCompletedOnboarding
  }

  var hasCompletedOnboarding: Bool {
    self.defaults.bool(forKey: "hasCompletedOnboarding")
  }
}

@MainActor
final class QuotaTempoApplicationDelegate: NSObject, NSApplicationDelegate {
  private var contentFactory: (() -> AnyView)?
  private var onPresent: (() -> Void)?
  private var onboardingProvider: (() -> Bool)?
  private var windowController: NSWindowController?
  private var presentationPending = false
  private let providerDisabled = CommandLine.arguments.contains("--provider-disabled")
  private let presentationRequestedForQA = CommandLine.arguments.contains(
    "--present-application-window"
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard
      self.presentationRequestedForQA
        || LaunchPresentationPolicy.presentsInitialWindow(
          hasCompletedOnboarding: UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
          providerDisabled: self.providerDisabled
        )
    else { return }
    self.presentApplicationWindow()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard LaunchPresentationPolicy.presentsReopenedWindow(providerDisabled: self.providerDisabled)
    else { return false }
    self.presentApplicationWindow()
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    FoundationBoundedProcessRunner.terminateAllRunningProcesses()
  }

  func configureApplicationWindow(
    content: @escaping () -> AnyView,
    onboarding: @escaping () -> Bool,
    onPresent: @escaping () -> Void
  ) {
    self.contentFactory = content
    self.onboardingProvider = onboarding
    self.onPresent = onPresent
    guard self.presentationPending else { return }
    self.presentationPending = false
    self.presentApplicationWindow()
  }

  func presentApplicationWindow() {
    guard let contentFactory else {
      self.presentationPending = true
      return
    }

    self.onPresent?()
    let onboarding = self.onboardingProvider?() ?? false
    if self.windowController == nil {
      let hostingController = NSHostingController(rootView: contentFactory())
      let window = NSWindow(contentViewController: hostingController)
      window.title = "QuotaTempo"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.isReleasedWhenClosed = false
      self.updateWindowSize(window, onboarding: onboarding)
      window.center()
      self.windowController = NSWindowController(window: window)
    }

    if self.windowController?.window?.isMiniaturized == true {
      self.windowController?.window?.deminiaturize(nil)
    }
    if let window = self.windowController?.window {
      self.updateWindowSize(window, onboarding: onboarding)
    }
    self.windowController?.showWindow(nil)
    self.windowController?.window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func updateApplicationWindowSize(onboarding: Bool) {
    guard let window = self.windowController?.window else { return }
    self.updateWindowSize(window, onboarding: onboarding)
  }

  private func updateWindowSize(_ window: NSWindow, onboarding: Bool) {
    let availableHeight = NSScreen.screens.first?.visibleFrame.height
    let contentHeight = QuotaMenuLayout.applicationContentHeight(
      onboarding: onboarding,
      availableHeight: availableHeight
    )
    let minimumContentHeight = QuotaMenuLayout.applicationMinimumContentHeight(
      onboarding: onboarding,
      availableHeight: availableHeight
    )
    window.contentMinSize = NSSize(width: QuotaMenuLayout.width, height: minimumContentHeight)
    window.setContentSize(NSSize(width: QuotaMenuLayout.width, height: contentHeight))
    if let screen = window.screen ?? NSScreen.screens.first {
      window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
    }
  }
}

@MainActor
final class QuotaTempoSettingsModel: ObservableObject {
  @Published private(set) var loginItemState: LoginItemState
  @Published private(set) var loginItemChangeFailed = false

  private let loginItemService: any LoginItemServicing

  init(loginItemService: any LoginItemServicing = SystemLoginItemService()) {
    self.loginItemService = loginItemService
    self.loginItemState = loginItemService.state
  }

  var launchAtLogin: Bool {
    self.loginItemState.isRequested
  }

  func refreshLoginItemState() {
    self.loginItemState = self.loginItemService.state
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try self.loginItemService.register()
      } else {
        try self.loginItemService.unregister()
      }
      self.loginItemChangeFailed = false
    } catch {
      self.loginItemChangeFailed = true
    }
    self.refreshLoginItemState()
  }
}

@MainActor
private struct QuotaTempoApplicationContent: View {
  @ObservedObject var model: LiveQuotaModel
  @ObservedObject var settings: QuotaTempoSettingsModel
  @ObservedObject var presentation: QuotaTempoPresentationModel
  let appDelegate: QuotaTempoApplicationDelegate
  let productVersion: String
  let updater: QuotaTempoUpdater
  let maximumViewportHeight: CGFloat?

  var body: some View {
    QuotaMenuView(
      scenario: self.model.scenario,
      languageCode: Locale.current.language.languageCode?.identifier ?? "en",
      locale: .current,
      timeZone: .current,
      availableHeight: NSScreen.screens.first?.visibleFrame.height,
      maximumViewportHeight: self.maximumViewportHeight,
      menuBarDisplayMode: self.$presentation.menuBarDisplayMode,
      onboardingPresented: self.$presentation.onboardingPresented,
      refreshInFlight: self.model.refreshInFlight,
      productVersion: self.productVersion,
      privacyURL: Bundle.main.resourceURL?.appendingPathComponent("PRIVACY.md"),
      licenseURL: Bundle.main.resourceURL?.appendingPathComponent("LICENSE"),
      updatesURL: Bundle.main.resourceURL?.appendingPathComponent("UPDATES.md"),
      downloadURL: URL(
        string: "https://github.com/Ishikawa-Hidekazu/quota-tempo/releases/latest"
      ),
      thirdPartyNoticesURL: Bundle.main.resourceURL?.appendingPathComponent(
        "THIRD_PARTY_NOTICES.md"
      ),
      supportURL: URL(string: "mailto:h@ishikawa.co"),
      enabledProviders: self.model.enabledProviders,
      launchAtLogin: Binding(
        get: { self.settings.launchAtLogin },
        set: { self.settings.setLaunchAtLogin($0) }
      ),
      loginItemState: self.settings.loginItemState,
      loginItemChangeFailed: self.settings.loginItemChangeFailed,
      onSetProviderEnabled: { provider, enabled in
        self.model.setProviderEnabled(provider, enabled: enabled)
      },
      onRefresh: { self.model.explicitRefresh() },
      onCheckForUpdates: self.updater.isEnabled ? { self.updater.checkForUpdates() } : nil,
      onCopyDiagnostics: { self.copyDiagnostics() },
      onOpenWindow: { self.appDelegate.presentApplicationWindow() },
      onMenuOpen: {
        self.model.menuOpened()
        Task { @MainActor in
          await Task.yield()
          self.settings.refreshLoginItemState()
        }
      },
      onMenuClose: {
        if self.presentation.hasCompletedOnboarding {
          self.presentation.onboardingPresented = false
        }
      },
      onQuit: { NSApplication.shared.terminate(nil) }
    )
    .onChange(of: self.presentation.onboardingPresented) { _, onboarding in
      self.appDelegate.updateApplicationWindowSize(onboarding: onboarding)
    }
  }

  private func copyDiagnostics() -> Bool {
    let report = SafeDiagnostics.report(
      scenario: self.model.scenario,
      productVersion: self.productVersion,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
    )
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(report, forType: .string)
  }
}

@main
struct QuotaTempoApp: App {
  @NSApplicationDelegateAdaptor(QuotaTempoApplicationDelegate.self) private var appDelegate
  @StateObject private var model: LiveQuotaModel
  @StateObject private var settings: QuotaTempoSettingsModel
  @StateObject private var presentation: QuotaTempoPresentationModel
  private let updater: QuotaTempoUpdater
  private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
  private let scheduledRefreshClock = Timer.publish(
    every: ProviderRefreshSchedule.interval,
    on: .main,
    in: .common
  ).autoconnect()
  private let wakeNotifications = NSWorkspace.shared.notificationCenter.publisher(
    for: NSWorkspace.didWakeNotification
  )

  init() {
    let arguments = CommandLine.arguments
    let providerDisabled = arguments.contains("--provider-disabled")
    let directory: URL
    if let index = arguments.firstIndex(of: "--storage-directory"), index + 1 < arguments.count {
      directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    } else {
      directory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0].appendingPathComponent("QuotaTempo", isDirectory: true)
    }
    let model = LiveQuotaModel(
      store: NormalizedSnapshotStore(directory: directory),
      acquisitionEnabled: !providerDisabled,
      preferences: providerDisabled ? nil : ProviderSelectionPreferences()
    )
    self._presentation = StateObject(wrappedValue: QuotaTempoPresentationModel())
    let loginItemService: any LoginItemServicing =
      providerDisabled ? UnavailableLoginItemService() : SystemLoginItemService()
    self._settings = StateObject(
      wrappedValue: QuotaTempoSettingsModel(loginItemService: loginItemService)
    )
    self.updater = QuotaTempoUpdater(enabled: !providerDisabled)
    if providerDisabled && arguments.contains("--exercise-provider-triggers") {
      model.menuOpened()
      model.scheduledRefresh()
      model.systemDidWake()
      model.explicitRefresh()
    }
    self._model = StateObject(wrappedValue: model)
  }

  var body: some Scene {
    MenuBarExtra {
      self.menuBarContent
    } label: {
      Group {
        if self.presentation.menuBarDisplayMode != .iconOnly {
          ProviderMenuBarLabel(
            scenario: self.model.scenario,
            mode: self.presentation.menuBarDisplayMode
          )
          .id(
            MenuBarTitleFormatter.renderIdentity(
              scenario: self.model.scenario,
              mode: self.presentation.menuBarDisplayMode
            )
          )
        } else {
          Image(systemName: "metronome")
            .accessibilityLabel("QuotaTempo")
        }
      }
      .onReceive(self.clock) { _ in self.model.clockAdvanced() }
      .onReceive(self.scheduledRefreshClock) { _ in self.model.scheduledRefresh() }
      .onReceive(self.wakeNotifications) { _ in self.model.systemDidWake() }
      .onAppear {
        self.appDelegate.configureApplicationWindow {
          AnyView(self.applicationWindowContent)
        } onboarding: {
          self.presentation.onboardingPresented
        } onPresent: {
          self.model.menuOpened()
          Task { @MainActor in
            await Task.yield()
            self.settings.refreshLoginItemState()
          }
        }
      }
    }
    .menuBarExtraStyle(.window)
  }

  private var menuBarContent: some View {
    self.applicationContent(maximumViewportHeight: QuotaMenuLayout.menuPopoverMaximumHeight)
  }

  private var applicationWindowContent: some View {
    self.applicationContent(maximumViewportHeight: nil)
  }

  private func applicationContent(maximumViewportHeight: CGFloat?) -> some View {
    QuotaTempoApplicationContent(
      model: self.model,
      settings: self.settings,
      presentation: self.presentation,
      appDelegate: self.appDelegate,
      productVersion: self.productVersion,
      updater: self.updater,
      maximumViewportHeight: maximumViewportHeight
    )
  }

  private var productVersion: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let channel = Bundle.main.object(forInfoDictionaryKey: "QTReleaseChannel") as? String
    guard let channel, channel != "stable", channel != "development" else { return version }
    return "\(version)-\(channel)"
  }

}
