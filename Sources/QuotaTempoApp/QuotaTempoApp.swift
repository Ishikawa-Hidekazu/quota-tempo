import AppKit
import Combine
import Foundation
import QuotaTempoCore
import Sparkle
import SwiftUI

#if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
  import QuotaTempoDesktopCandidate
#endif

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
  private struct ClaudeRefreshRequest {
    let trigger: ProviderAcquisitionTrigger
    let force: Bool
    let localOnly: Bool
    let connectionRevision: Int
  }

  private static let providerQueue = DispatchQueue(
    label: "com.ishikawa.quotatempo.provider-refresh",
    qos: .utility,
    attributes: .concurrent
  )
  @Published private(set) var scenario: FixtureScenario
  @Published private(set) var refreshInFlight = false
  @Published private(set) var enabledProviders: Set<ProviderID>
  @Published private(set) var claudeSource: ClaudeSource
  @Published private(set) var browserDisconnectInFlight = false
  @Published private(set) var browserDisconnectFailed = false
  @Published private(set) var browserDisconnectCleanupFailed = false

  private let store: NormalizedSnapshotStore
  private let acquisitionGate: ProviderAcquisitionGate
  private let preferences: ProviderSelectionPreferences?
  private let claudeAdapter: ClaudeAutomaticAdapter
  private let workerQueue: DispatchQueue
  private let now: @Sendable () -> Date
  private let localClaudeAcquisitionEnabled: Bool
  private let sourcePreferences: ClaudeSourcePreferences?
  private var selection: ProviderSelection
  private var initialDetectionPending: Bool
  private var initialDetectionTracker = InitialProviderDetectionTracker()
  private var initialDetectionSnapshots: [ProviderID: ProviderSnapshot] = [:]
  private var codexRefreshInFlight = false
  private var activeClaudeRefresh: ClaudeRefreshRequest?
  private var pendingClaudeRefresh: ClaudeRefreshRequest?
  private var transientSnapshots: [ProviderID: ProviderSnapshot] = [:]
  private var scenarioRevision = 0
  private var claudeConnectionRevision = 0
  private var claudeRefreshCancellation = ClaudeRefreshCancellation()

  init(
    store: NormalizedSnapshotStore,
    acquisitionEnabled: Bool,
    preferences: ProviderSelectionPreferences? = nil,
    claudeAdapter: ClaudeAutomaticAdapter = ClaudeAutomaticAdapter(
      cliExecutable: nil,
      resolveCLIOnRefresh: true,
      ptyProbeEnabled: true
    ),
    now: @escaping @Sendable () -> Date = { Date() },
    providerQueue: DispatchQueue? = nil,
    localClaudeAcquisitionEnabled: Bool = true,
    claudeSource: ClaudeSource = .automatic,
    sourcePreferences: ClaudeSourcePreferences? = nil
  ) {
    self.store = store
    self.acquisitionGate = ProviderAcquisitionGate(enabled: acquisitionEnabled)
    self.preferences = preferences
    self.claudeAdapter = claudeAdapter
    self.workerQueue = providerQueue ?? Self.providerQueue
    self.now = now
    self.localClaudeAcquisitionEnabled = localClaudeAcquisitionEnabled
    self.sourcePreferences = sourcePreferences
    let source = sourcePreferences?.load() ?? claudeSource
    self.claudeSource = source
    let allowsLocalClaude = localClaudeAcquisitionEnabled && source == .automatic
    let storedScenario = Self.localPresentation(
      self.store.scenario(now: now()), store: store, allowsClaude: allowsLocalClaude)
    if let configured = preferences?.load() {
      self.selection = configured
      self.initialDetectionPending = false
    } else if allowsLocalClaude,
      let detected = ProviderSelection.detected(in: storedScenario.snapshots)
    {
      self.selection = detected
      self.initialDetectionPending = false
      preferences?.save(detected)
    } else {
      self.selection = .all
      self.initialDetectionPending = preferences != nil && allowsLocalClaude
    }
    self.enabledProviders = self.selection.enabled
    self.scenario = self.selection.filtering(storedScenario)
    self.refreshCodex(trigger: .launch, force: false)
    self.refreshClaude(trigger: .launch, force: false)
  }

  var allowsLocalClaude: Bool {
    localClaudeAcquisitionEnabled && claudeSource == .automatic
  }

  var claudeActionRevision: Int { claudeConnectionRevision }

  // Desktop revocation is performed by the lifecycle before switching back.
  // Local generations are fenced synchronously before a Desktop connect can run.
  func setClaudeSource(_ source: ClaudeSource) {
    guard source != claudeSource else { return }
    invalidateClaudeRefresh()
    scenarioRevision += 1
    initialDetectionPending = false
    initialDetectionSnapshots = [:]
    transientSnapshots.removeValue(forKey: .claude)
    claudeSource = source
    sourcePreferences?.save(source)
    scenario = FixtureScenario(
      id: scenario.id, now: now(), snapshots: scenario.snapshots.filter { $0.provider != .claude })
    if allowsLocalClaude {
      reload()
      refreshClaude(trigger: .explicitRefresh, force: true)
    }
  }

  func menuOpened() {
    self.reload()
    self.refreshCodex(trigger: .menuOpen, force: false)
    self.refreshClaude(trigger: .menuOpen, force: false)
  }

  func clockAdvanced() {
    self.refreshClaude(trigger: .scheduledRefresh, force: false, localOnly: true)
    let now = self.now()
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
    let allowsClaude = self.allowsLocalClaude
    let cancellation = self.claudeRefreshCancellation

    Task {
      let loaded = await Task.detached(priority: .utility) {
        let stored = store.scenario(now: now)
        let complete = SnapshotScenarioOverlay.apply(
          transientSnapshots,
          to: stored,
          now: now
        )
        return selection.filtering(
          Self.localPresentation(
            complete, store: store, allowsClaude: allowsClaude && !cancellation.isCancelled))
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

  func disconnectClaudeBrowser() async {
    guard allowsLocalClaude else { return }
    guard !browserDisconnectInFlight else { return }
    browserDisconnectInFlight = true
    browserDisconnectFailed = false
    browserDisconnectCleanupFailed = false
    invalidateClaudeRefresh()
    let revision = claudeConnectionRevision
    defer { browserDisconnectInFlight = false }
    let browser = ClaudeBrowserStore(
      directory: store.directory.appendingPathComponent("BrowserBridge", isDirectory: true))
    let instant = now()
    let succeeded = await Task.detached(priority: .utility) {
      do {
        try browser.disconnect(now: instant)
        return true
      } catch { return false }
    }.value
    guard claudeConnectionRevision == revision, allowsLocalClaude else { return }
    guard succeeded else {
      browserDisconnectFailed = true
      return
    }
    // Never carry browser ownership or resets into the local route. Disconnect
    // is not permission for a new live CLI request or an immediate retry.
    let cleared = ProviderSnapshot(
      provider: .claude, source: .claudeDesktopHistory, capturedAt: nil, weekly: nil,
      sourceState: .neverObserved)
    scenario = selection.filtering(
      SnapshotScenarioOverlay.apply([.claude: cleared], to: scenario, now: now()))
    browserDisconnectCleanupFailed = !persist(cleared)
    browserDisconnectInFlight = false
    if activeClaudeRefresh != nil {
      pendingClaudeRefresh = ClaudeRefreshRequest(
        trigger: .explicitRefresh, force: false, localOnly: true,
        connectionRevision: claudeConnectionRevision)
    } else {
      refreshClaude(trigger: .explicitRefresh, force: false, localOnly: true)
    }
  }

  func setProviderEnabled(_ provider: ProviderID, enabled: Bool) {
    let next = self.selection.setting(provider, enabled: enabled)
    guard next != self.selection else { return }
    if provider == .claude && !enabled { invalidateClaudeRefresh() }
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
    let now = self.now()
    let store = self.store
    let transientSnapshots = self.transientSnapshots
    let selection = self.selection
    let allowsClaude = self.allowsLocalClaude
    let cancellation = self.claudeRefreshCancellation

    Task {
      let loaded = await Task.detached(priority: .utility) {
        let stored = store.scenario(now: now)
        let complete = SnapshotScenarioOverlay.apply(
          transientSnapshots,
          to: stored,
          now: now
        )
        return selection.filtering(
          Self.localPresentation(
            complete, store: store, allowsClaude: allowsClaude && !cancellation.isCancelled))
      }.value
      guard self.scenarioRevision == revision else { return }
      self.scenario = loaded
    }
  }

  nonisolated private static func validatedBrowserPresentation(
    _ scenario: FixtureScenario, store: NormalizedSnapshotStore
  ) -> FixtureScenario {
    guard scenario.snapshots.contains(where: { $0.source == .claudeBrowser }) else {
      return scenario
    }
    let browser = ClaudeBrowserStore(
      directory: store.directory.appendingPathComponent("BrowserBridge"))
    var current =
      browser.selectedSnapshot(now: scenario.now)
      ?? ProviderSnapshot(
        provider: .claude, source: .claudeDesktopHistory, capturedAt: nil, weekly: nil,
        sourceState: .neverObserved)
    if scenario.snapshots.first(where: { $0.provider == .claude })?.errorCode == .atomicWriteFailed
    {
      current = AcquisitionRecords.preservingFailure(
        previous: current, provider: .claude, source: current.source,
        attemptedAt: current.lastAttemptAt, state: .attemptFailed, error: .atomicWriteFailed)
    }
    return SnapshotScenarioOverlay.apply([.claude: current], to: scenario, now: scenario.now)
  }

  nonisolated private static func localPresentation(
    _ scenario: FixtureScenario, store: NormalizedSnapshotStore, allowsClaude: Bool
  ) -> FixtureScenario {
    guard allowsClaude else {
      return FixtureScenario(
        id: scenario.id, now: scenario.now,
        snapshots: scenario.snapshots.filter { $0.provider != .claude })
    }
    return validatedBrowserPresentation(scenario, store: store)
  }

  @discardableResult
  private func persist(_ snapshot: ProviderSnapshot) -> Bool {
    var saved = false
    do {
      try self.store.save(snapshot)
      self.transientSnapshots.removeValue(forKey: snapshot.provider)
      saved = true
      if snapshot.provider == .claude, snapshot.source != .claudeBrowser {
        browserDisconnectCleanupFailed = false
      }
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
    return saved
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

  private func refreshClaude(
    trigger: ProviderAcquisitionTrigger, force: Bool, localOnly: Bool = false
  ) {
    guard allowsLocalClaude else { return }
    guard !browserDisconnectInFlight else { return }
    guard self.acquisitionGate.performIfAllowed(trigger, operation: {}) else { return }
    guard self.selection.contains(.claude) || self.initialDetectionPending else { return }
    let request = ClaudeRefreshRequest(
      trigger: trigger, force: force, localOnly: localOnly,
      connectionRevision: claudeConnectionRevision)
    if let active = self.activeClaudeRefresh {
      // Local reads cannot satisfy a live request. An active live request only
      // needs a follow-up when force is upgraded or an off/on invalidated it.
      guard
        active.connectionRevision != request.connectionRevision
          || (!localOnly && (active.localOnly || (force && !active.force)))
      else { return }
      if self.pendingClaudeRefresh?.force != true {
        self.pendingClaudeRefresh = request
      }
      return
    }

    self.activeClaudeRefresh = request
    self.updateRefreshInFlight()
    let store = self.store
    let adapter = self.claudeAdapter
    let clock = self.now
    let transientSnapshots = self.transientSnapshots
    let connectionRevision = self.claudeConnectionRevision
    let cancellation = self.claudeRefreshCancellation
    let queue = self.workerQueue
    Task {
      let snapshot: ProviderSnapshot? = await withCheckedContinuation { continuation in
        queue.async {
          guard !cancellation.isCancelled else {
            continuation.resume(returning: nil)
            return
          }
          let previous = SnapshotScenarioOverlay.currentSnapshot(
            for: .claude,
            stored: (try? store.load(.claude)) ?? nil,
            overrides: transientSnapshots
          )
          let now = clock()
          let browser = ClaudeBrowserStore(
            directory: store.directory.appendingPathComponent("BrowserBridge", isDirectory: true))
          guard !cancellation.isCancelled else {
            continuation.resume(returning: nil)
            return
          }
          if let observed = browser.selectedSnapshot(now: now) {
            continuation.resume(returning: observed == previous ? nil : observed)
            return
          }
          let localPrevious = previous?.source == .claudeBrowser ? nil : previous
          if localOnly {
            continuation.resume(
              returning: adapter.observeLocalChanges(previous: localPrevious, now: now))
            return
          }
          guard
            !cancellation.isCancelled,
            force
              || ClaudeAutomaticAdapter.shouldRefresh(
                lastAttemptAt: localPrevious?.lastAttemptAt,
                now: now
              )
          else {
            continuation.resume(returning: nil)
            return
          }
          continuation.resume(
            returning: adapter.refresh(
              previous: localPrevious, now: now, forceLiveProbe: force,
              isCancelled: { cancellation.isCancelled }))
        }
      }
      if self.claudeConnectionRevision == connectionRevision {
        if let snapshot {
          self.persist(snapshot)
        } else {
          self.finishInitialDetectionAttempt(.claude)
        }
      }
      self.activeClaudeRefresh = nil
      let pending = self.pendingClaudeRefresh
      self.pendingClaudeRefresh = nil
      if let pending {
        // Re-enter the gate and current selection, consuming the request once.
        self.refreshClaude(
          trigger: pending.trigger, force: pending.force, localOnly: pending.localOnly)
      }
      self.updateRefreshInFlight()
    }
  }

  private func updateRefreshInFlight() {
    self.refreshInFlight = self.codexRefreshInFlight || self.activeClaudeRefresh != nil
  }

  private func invalidateClaudeRefresh() {
    claudeConnectionRevision += 1
    claudeRefreshCancellation.cancel()
    claudeRefreshCancellation = ClaudeRefreshCancellation()
    pendingClaudeRefresh = nil
  }
}

private final class ClaudeRefreshCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
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
  #if DESKTOP_INTEGRATION_PREVIEW
    static var isBundledCodePreview: Bool {
      Bundle.main.bundleIdentifier == CodeComparisonPluginPackage.bundleID
        && Bundle.main.object(forInfoDictionaryKey: "QTReleaseChannel") as? String
          == CodeComparisonPluginPackage.channel
        && Bundle.main.object(forInfoDictionaryKey: "QTCodeComparisonPluginBundled") as? Bool
          == true
    }
  #endif
  static var defaults: UserDefaults {
    #if DESKTOP_INTEGRATION_PREVIEW
      if isBundledCodePreview {
        // The preview's unique bundle ID already isolates its standard domain.
        // Passing that same ID as a suite name returns nil on macOS.
        return .standard
      }
      // Retain the original preview preference suite so existing versioned
      // consent is not silently discarded by a cosmetic bundle-ID alignment.
      return UserDefaults(suiteName: "com.ishikawa.QuotaTempo.IntegrationPreview")!
    #else
      return .standard
    #endif
  }
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
  #if CODE_USAGE_COMPARISON
    private var onTerminate: (() -> Void)?
  #endif
  private var onboardingProvider: (() -> Bool)?
  private var windowController: NSWindowController?
  private var presentationPending = false
  private let providerDisabled = QuotaTempoRuntimePolicy.providersDisabled(
    arguments: CommandLine.arguments)
  private let presentationRequestedForQA = CommandLine.arguments.contains(
    "--present-application-window"
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard
      self.presentationRequestedForQA
        || LaunchPresentationPolicy.presentsInitialWindow(
          hasCompletedOnboarding: QuotaTempoAppDefaults.defaults.bool(
            forKey: "hasCompletedOnboarding"),
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
    #if CODE_USAGE_COMPARISON
      self.onTerminate?()
    #endif
    FoundationBoundedProcessRunner.terminateAllRunningProcesses()
  }

  #if CODE_USAGE_COMPARISON
    func configureApplicationTermination(_ onTerminate: @escaping () -> Void) {
      self.onTerminate = onTerminate
    }
  #endif

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
struct QuotaTempoApplicationContent: View {
  @ObservedObject var model: LiveQuotaModel
  @ObservedObject var settings: QuotaTempoSettingsModel
  @ObservedObject var presentation: QuotaTempoPresentationModel
  #if CODE_USAGE_COMPARISON
    @ObservedObject var codeComparison = CodeUsageComparisonController()
  #endif
  #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
    @ObservedObject var desktopConnection: DesktopConnectionController
  #endif
  let appDelegate: QuotaTempoApplicationDelegate
  let productVersion: String
  let updater: QuotaTempoUpdater
  let maximumViewportHeight: CGFloat?
  let providerDisabled: Bool
  let onRefresh: () -> Void
  let onQuit: () -> Void
  var renderNow: () -> Date = Date.init

  var scenario: FixtureScenario {
    #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
      return DesktopIntegrationPresentation.scenario(
        base: model.scenario, desktop: desktopConnection.snapshot,
        enabled: model.enabledProviders.contains(.claude), now: renderNow(),
        source: model.claudeSource)
    #else
      return model.scenario
    #endif
  }

  var desktopActionsAllowed: Bool {
    #if DESKTOP_INTEGRATION_PREVIEW
      if QuotaTempoAppDefaults.isBundledCodePreview { return false }
    #endif
    return !providerDisabled && model.claudeSource == .desktop
      && model.enabledProviders.contains(.claude)
  }

  func setProviderEnabled(_ provider: ProviderID, enabled: Bool) {
    #if CODE_USAGE_COMPARISON
      if provider == .claude && !enabled && model.enabledProviders.count > 1 {
        codeComparison.setEnabled(false)
      }
    #endif
    #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
      desktopLifecycle.setProviderEnabled(provider, enabled: enabled, model: model)
    #else
      model.setProviderEnabled(provider, enabled: enabled)
    #endif
    #if CODE_USAGE_COMPARISON
      codeComparison.setEnabled(!providerDisabled && model.enabledProviders.contains(.claude))
    #endif
  }

  private var connectionControls: AnyView? {
    AnyView(
      VStack(alignment: .leading, spacing: 12) {
        #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
          #if DESKTOP_INTEGRATION_PREVIEW
            if !QuotaTempoAppDefaults.isBundledCodePreview { desktopConnectionControls }
          #else
            desktopConnectionControls
          #endif
        #endif
        #if CODE_USAGE_COMPARISON
          if !providerDisabled {
            CodeUsageComparisonControls(
              connection: codeComparison, enabled: model.enabledProviders.contains(.claude))
          }
        #endif
      })
  }

  #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
    private var desktopLifecycle: DesktopIntegrationLifecycle {
      DesktopIntegrationLifecycle(
        connection: desktopConnection, acquisitionAllowed: { self.desktopActionsAllowed })
    }

    func setClaudeSource(_ source: ClaudeSource) {
      desktopLifecycle.selectSource(source, model: model)
    }

    var desktopConnectionControls: DesktopIntegrationControls {
      DesktopIntegrationControls(
        connection: desktopConnection, allowsConnection: { self.desktopActionsAllowed },
        source: Binding(get: { model.claudeSource }, set: { setClaudeSource($0) }),
        actionRevision: { model.claudeActionRevision })
    }
  #endif

  var body: some View {
    QuotaMenuView(
      scenario: self.scenario,
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
      browserDisconnectInFlight: self.model.browserDisconnectInFlight,
      browserDisconnectFailed: self.model.browserDisconnectFailed,
      browserDisconnectCleanupFailed: self.model.browserDisconnectCleanupFailed,
      connectionControls: self.connectionControls,
      onboardingPrivacyText: self.desktopPrivacyText,
      onSetProviderEnabled: self.setProviderEnabled,
      onRefresh: self.onRefresh,
      onDisconnectBrowser: { Task { await self.model.disconnectClaudeBrowser() } },
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
      onQuit: self.onQuit
    )
    .onChange(of: self.presentation.onboardingPresented) { _, onboarding in
      self.appDelegate.updateApplicationWindowSize(onboarding: onboarding)
    }
  }

  private func copyDiagnostics() -> Bool {
    let report = SafeDiagnostics.report(
      scenario: self.scenario,
      productVersion: self.productVersion,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
    )
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(report, forType: .string)
  }

  private var desktopPrivacyText: String? {
    #if DESKTOP_INTEGRATION_PREVIEW
      return Locale.current.language.languageCode?.identifier == "ja"
        ? "Desktop接続は明示的な同意の後でのみ認証を端末内で使用し、Anthropicへ使用量を照会します。提供元の変更により、取得できなくなる場合があります。"
        : "Desktop connection uses authentication locally and requests usage from Anthropic only after explicit consent. Provider changes may prevent QuotaTempo from retrieving usage data."
    #elseif DESKTOP_CONNECTION
      return Locale.current.language.languageCode?.identifier == "ja"
        ? "通常はローカル情報・CLI・ブラウザ連携を使用します。Claude Desktop接続は任意選択です。明示的な同意後に端末内の認証を使用してAnthropicへ使用量を照会します。提供元の変更により、取得できなくなる場合があります。"
        : "Automatic uses local information, CLI or the browser connection. Claude Desktop connection is optional and uses authentication locally to request usage from Anthropic after explicit consent. Provider changes may prevent QuotaTempo from retrieving usage data."
    #else
      return nil
    #endif
  }
}

struct QuotaTempoApp: App {
  @NSApplicationDelegateAdaptor(QuotaTempoApplicationDelegate.self) private var appDelegate
  @StateObject private var model: LiveQuotaModel
  @StateObject private var settings: QuotaTempoSettingsModel
  @StateObject private var presentation: QuotaTempoPresentationModel
  #if CODE_USAGE_COMPARISON
    @StateObject private var codeComparison: CodeUsageComparisonController
  #endif
  #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
    @StateObject private var desktopConnection: DesktopConnectionController
    private let desktopClock = Timer.publish(
      every: DesktopIntegrationLifecycle.schedulingInterval, on: .main, in: .common
    ).autoconnect()
  #endif
  private let providerDisabled: Bool
  private let updater: QuotaTempoUpdater
  private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
  #if CODE_USAGE_COMPARISON
    private let codeComparisonClock = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
  #endif
  private let scheduledRefreshClock = Timer.publish(
    every: ProviderRefreshSchedule.interval,
    on: .main,
    in: .common
  ).autoconnect()
  private let wakeNotifications = NSWorkspace.shared.notificationCenter.publisher(
    for: NSWorkspace.didWakeNotification
  )

  init() {
    self.init(
      arguments: CommandLine.arguments,
      supportDirectory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0],
      defaults: QuotaTempoAppDefaults.defaults)
  }

  init(arguments: [String], supportDirectory: URL, defaults: UserDefaults) {
    #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
      let desktopConfiguration = DesktopIntegrationConfiguration(
        arguments: arguments,
        supportDirectory: supportDirectory)
      let providerDisabled = desktopConfiguration.providerDisabled
    #else
      let providerDisabled = QuotaTempoRuntimePolicy.providersDisabled(arguments: arguments)
    #endif
    self.providerDisabled = providerDisabled
    #if DESKTOP_INTEGRATION_PREVIEW
      let source = ClaudeSource.desktop
      let sourcePreferences: ClaudeSourcePreferences? = nil
    #else
      let source = ClaudeSource.automatic
      let sourcePreferences =
        providerDisabled
        ? nil
        : ClaudeSourcePreferences(
          defaults: defaults)
    #endif
    let directory: URL
    #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
      #if DESKTOP_INTEGRATION_PREVIEW
        directory =
          QuotaTempoAppDefaults.isBundledCodePreview
          ? supportDirectory
            .appendingPathComponent(
              "QuotaTempoCodeComparisonPreview/Observations", isDirectory: true)
          : desktopConfiguration.appDirectory
      #else
        directory = desktopConfiguration.appDirectory
      #endif
    #else
      if let index = arguments.firstIndex(of: "--storage-directory"), index + 1 < arguments.count {
        directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
      } else {
        directory = supportDirectory.appendingPathComponent("QuotaTempo", isDirectory: true)
      }
    #endif
    #if DESKTOP_INTEGRATION_PREVIEW
      let acquisitionEnabled = !providerDisabled && !QuotaTempoAppDefaults.isBundledCodePreview
    #else
      let acquisitionEnabled = !providerDisabled
    #endif
    let model = LiveQuotaModel(
      store: NormalizedSnapshotStore(directory: directory),
      acquisitionEnabled: acquisitionEnabled,
      preferences: providerDisabled ? nil : ProviderSelectionPreferences(defaults: defaults),
      claudeSource: source, sourcePreferences: sourcePreferences
    )
    #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
      // Share the existing helper's exclusive scheduling store. A new UI must
      // not create a fresh identity-independent provider backoff namespace.
      #if DESKTOP_INTEGRATION_PREVIEW
        let schedulingDirectory =
          QuotaTempoAppDefaults.isBundledCodePreview
          ? directory.deletingLastPathComponent().appendingPathComponent(
            "DesktopConnection", isDirectory: true)
          : desktopConfiguration.schedulingDirectory
      #else
        let schedulingDirectory = desktopConfiguration.schedulingDirectory
      #endif
      self._desktopConnection = StateObject(
        wrappedValue: DesktopConnectionController(
          directory: schedulingDirectory,
          consentDefaults: providerDisabled ? nil : defaults))
    #endif
    self._presentation = StateObject(wrappedValue: QuotaTempoPresentationModel(defaults: defaults))
    let systemIntegrationsEnabled = QuotaTempoRuntimePolicy.systemIntegrationsEnabled(
      providerDisabled: providerDisabled)
    let loginItemService: any LoginItemServicing =
      systemIntegrationsEnabled ? SystemLoginItemService() : UnavailableLoginItemService()
    self._settings = StateObject(
      wrappedValue: QuotaTempoSettingsModel(loginItemService: loginItemService)
    )
    self.updater = QuotaTempoUpdater(enabled: systemIntegrationsEnabled)
    if providerDisabled && arguments.contains("--exercise-provider-triggers") {
      model.menuOpened()
      model.scheduledRefresh()
      model.systemDidWake()
      model.explicitRefresh()
    }
    self._model = StateObject(wrappedValue: model)
    #if CODE_USAGE_COMPARISON
      let codeComparison = CodeUsageComparisonController()
      codeComparison.setEnabled(!providerDisabled && model.enabledProviders.contains(.claude))
      self._codeComparison = StateObject(wrappedValue: codeComparison)
    #endif
  }

  var body: some Scene {
    MenuBarExtra {
      self.menuBarContent
    } label: {
      Group {
        if self.presentation.menuBarDisplayMode != .iconOnly {
          ProviderMenuBarLabel(
            scenario: self.displayScenario,
            mode: self.presentation.menuBarDisplayMode
          )
          .id(
            MenuBarTitleFormatter.renderIdentity(
              scenario: self.displayScenario,
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
      #if CODE_USAGE_COMPARISON
        .onReceive(self.codeComparisonClock) { _ in
          Task { await self.codeComparison.refresh() }
        }
        .onChange(of: self.model.enabledProviders) { _, providers in
          self.codeComparison.setEnabled(!self.providerDisabled && providers.contains(.claude))
        }
      #endif
      #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
        .task {
          self.desktopLifecycle.providersChanged(self.model.enabledProviders)
          await self.desktopLifecycle.start()
        }
        .onReceive(self.desktopClock) { _ in self.refreshDesktop() }
        .onReceive(self.wakeNotifications) { _ in self.refreshDesktop() }
        .onChange(of: self.model.enabledProviders) { _, providers in
          self.desktopLifecycle.providersChanged(providers)
        }
      #endif
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
        #if CODE_USAGE_COMPARISON
          self.appDelegate.configureApplicationTermination {
            self.codeComparison.applicationWillTerminate()
          }
        #endif
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
    #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
      let content = QuotaTempoApplicationContent(
        model: self.model, settings: self.settings, presentation: self.presentation,
        desktopConnection: self.desktopConnection,
        appDelegate: self.appDelegate, productVersion: self.productVersion, updater: self.updater,
        maximumViewportHeight: maximumViewportHeight, providerDisabled: self.providerDisabled,
        onRefresh: {
          self.model.explicitRefresh()
          self.refreshDesktop()
        },
        onQuit: { NSApplication.shared.terminate(nil) })
    #else
      let content = QuotaTempoApplicationContent(
        model: self.model,
        settings: self.settings,
        presentation: self.presentation,
        appDelegate: self.appDelegate,
        productVersion: self.productVersion,
        updater: self.updater,
        maximumViewportHeight: maximumViewportHeight,
        providerDisabled: self.providerDisabled,
        onRefresh: {
          self.model.explicitRefresh()
        },
        onQuit: {
          // Never wait for provider I/O to quit. Attempts are checkpointed before HTTP.
          NSApplication.shared.terminate(nil)
        }
      )
    #endif
    #if CODE_USAGE_COMPARISON
      var sharedContent = content
      sharedContent.codeComparison = self.codeComparison
      return sharedContent
    #else
      return content
    #endif
  }

  private var displayScenario: FixtureScenario {
    #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
      return DesktopIntegrationPresentation.scenario(
        base: self.model.scenario, desktop: self.desktopConnection.snapshot,
        enabled: self.model.enabledProviders.contains(.claude), now: Date(),
        source: self.model.claudeSource)
    #else
      return self.model.scenario
    #endif
  }

  #if DESKTOP_CONNECTION || DESKTOP_INTEGRATION_PREVIEW
    private var desktopLifecycle: DesktopIntegrationLifecycle {
      DesktopIntegrationLifecycle(
        connection: desktopConnection,
        acquisitionAllowed: {
          #if DESKTOP_INTEGRATION_PREVIEW
            if QuotaTempoAppDefaults.isBundledCodePreview { return false }
          #endif
          return !self.providerDisabled && self.model.claudeSource == .desktop
            && self.model.enabledProviders.contains(.claude)
        })
    }

    private func refreshDesktop() {
      Task { await self.desktopLifecycle.refresh() }
    }
  #endif

  private var productVersion: String {
    #if DESKTOP_INTEGRATION_PREVIEW
      if QuotaTempoAppDefaults.isBundledCodePreview { return "Code comparison preview (local)" }
      return "Desktop integration preview (local)"
    #else
      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"
      let channel = Bundle.main.object(forInfoDictionaryKey: "QTReleaseChannel") as? String
      guard let channel, channel != "stable", channel != "development" else { return version }
      return "\(version)-\(channel)"
    #endif
  }

}
