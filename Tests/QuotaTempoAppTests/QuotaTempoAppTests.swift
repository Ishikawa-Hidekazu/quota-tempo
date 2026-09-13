import Foundation
import ServiceManagement
import Testing

@testable import QuotaTempoApp
@testable import QuotaTempoCore

@Suite("QuotaTempo application composition")
@MainActor
struct QuotaTempoAppTests {
  @Test("New installations default to the smallest menu bar display")
  func defaultMenuBarDisplay() {
    #expect(QuotaTempoAppDefaults.menuBarDisplayMode == .iconOnly)
  }

  @Test("Presentation preferences persist mode and onboarding completion")
  func presentationPreferences() throws {
    let suiteName = "QuotaTempoPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = QuotaTempoPresentationModel(defaults: defaults)
    #expect(initial.menuBarDisplayMode == .iconOnly)
    #expect(initial.onboardingPresented)

    initial.menuBarDisplayMode = .compact
    initial.onboardingPresented = false

    let restored = QuotaTempoPresentationModel(defaults: defaults)
    #expect(restored.menuBarDisplayMode == .compact)
    #expect(!restored.onboardingPresented)
    #expect(restored.hasCompletedOnboarding)
  }

  @Test("Existing users without an explicit display preference retain Full")
  func implicitLegacyDisplayPreference() throws {
    let suiteName = "QuotaTempoLegacyPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "hasCompletedOnboarding")

    let restored = QuotaTempoPresentationModel(defaults: defaults)

    #expect(restored.menuBarDisplayMode == .full)
    #expect(!restored.onboardingPresented)
  }

  @Test("New users retain Icon only after completing onboarding")
  func completedNewUserDisplayPreference() throws {
    let suiteName = "QuotaTempoNewPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = QuotaTempoPresentationModel(defaults: defaults)
    initial.onboardingPresented = false
    let restored = QuotaTempoPresentationModel(defaults: defaults)

    #expect(restored.menuBarDisplayMode == .iconOnly)
    #expect(!restored.onboardingPresented)
  }

  @Test("First launch presents a window while provider-disabled QA stays silent")
  func firstLaunchPresentationPolicy() {
    #expect(
      LaunchPresentationPolicy.presentsInitialWindow(
        hasCompletedOnboarding: false,
        providerDisabled: false
      )
    )
    #expect(
      !LaunchPresentationPolicy.presentsInitialWindow(
        hasCompletedOnboarding: true,
        providerDisabled: false
      )
    )
    #expect(
      !LaunchPresentationPolicy.presentsInitialWindow(
        hasCompletedOnboarding: false,
        providerDisabled: true
      )
    )
  }

  @Test("Finder reopen presents the window outside provider-disabled QA")
  func reopenPresentationPolicy() {
    #expect(LaunchPresentationPolicy.presentsReopenedWindow(providerDisabled: false))
    #expect(!LaunchPresentationPolicy.presentsReopenedWindow(providerDisabled: true))
  }

  @Test("Provider-disabled QA uses an unavailable login item boundary")
  func providerDisabledLoginItemBoundary() {
    let service = UnavailableLoginItemService()

    #expect(service.state == .unavailable)
  }

  @Test("Provider-disabled QA does not start the updater")
  func providerDisabledUpdaterBoundary() {
    #expect(!QuotaTempoUpdater(enabled: false).isEnabled)
  }

  @Test("Unsupported app locations do not construct the system login item service")
  func unsupportedLocationSkipsServiceConstruction() {
    var serviceConstructionCount = 0
    let service = SystemLoginItemService(
      serviceFactory: {
        serviceConstructionCount += 1
        return .mainApp
      },
      bundleURL: URL(fileURLWithPath: "/private/tmp/QuotaTempo.app"),
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(serviceConstructionCount == 0)
    #expect(service.state == .requiresMoveToApplications)
  }

  @Test("Settings model registers and unregisters the login item through the system boundary")
  func loginItemSettingsFlow() {
    let service = RecordingLoginItemService(state: .disabled)
    let model = QuotaTempoSettingsModel(loginItemService: service)

    #expect(!model.launchAtLogin)
    model.setLaunchAtLogin(true)
    #expect(service.registerCount == 1)
    #expect(model.loginItemState == .enabled)
    #expect(model.launchAtLogin)
    #expect(!model.loginItemChangeFailed)

    model.setLaunchAtLogin(false)
    #expect(service.unregisterCount == 1)
    #expect(model.loginItemState == .disabled)
    #expect(!model.launchAtLogin)
  }

  @Test("Settings model keeps the observed state and exposes registration failure")
  func loginItemSettingsFailure() {
    let service = RecordingLoginItemService(state: .disabled, shouldFail: true)
    let model = QuotaTempoSettingsModel(loginItemService: service)

    model.setLaunchAtLogin(true)

    #expect(service.registerCount == 1)
    #expect(model.loginItemState == .disabled)
    #expect(model.loginItemChangeFailed)
  }

  @Test("Live model persists one-provider selection and never allows zero providers")
  func liveModelProviderSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "QuotaTempoAppTests.\(UUID().uuidString)", isDirectory: true)
    let suiteName = "QuotaTempoAppTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suiteName)
    }
    let preferences = ProviderSelectionPreferences(defaults: defaults)
    preferences.save(.all)
    let model = LiveQuotaModel(
      store: NormalizedSnapshotStore(directory: root),
      acquisitionEnabled: false,
      preferences: preferences
    )

    model.setProviderEnabled(.claude, enabled: false)
    #expect(model.enabledProviders == [.codex])
    #expect(preferences.load()?.enabled == [.codex])
    #expect(model.scenario.snapshots.map(\.provider) == [.codex])

    model.setProviderEnabled(.codex, enabled: false)
    #expect(model.enabledProviders == [.codex])
    #expect(preferences.load()?.enabled == [.codex])
  }

  @Test("Minute clock updates planning time and reloads disk off the main actor")
  func clockAdvanceReloadsSnapshotAsynchronously() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "QuotaTempoAppClockTests.\(UUID().uuidString)", isDirectory: true)
    let suiteName = "QuotaTempoAppClockTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suiteName)
    }
    let now = Date()
    let store = NormalizedSnapshotStore(directory: root)
    let preferences = ProviderSelectionPreferences(defaults: defaults)
    preferences.save(ProviderSelection(enabled: [.codex]))
    try store.save(self.codexSnapshot(remaining: 40, capturedAt: now))
    let model = LiveQuotaModel(
      store: store,
      acquisitionEnabled: false,
      preferences: preferences
    )
    try store.save(self.codexSnapshot(remaining: 90, capturedAt: now))

    model.clockAdvanced()

    #expect(model.scenario.now >= now)
    for _ in 0..<100 where model.scenario.snapshots.first?.weekly?.remainingPercent != 90 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.scenario.snapshots.first?.weekly?.remainingPercent == 90)
  }

  @Test("Menu open presents current state before reloading disk asynchronously")
  func menuOpenReloadsSnapshotAsynchronously() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "QuotaTempoAppMenuOpenTests.\(UUID().uuidString)", isDirectory: true)
    let suiteName = "QuotaTempoAppMenuOpenTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suiteName)
    }
    let now = Date()
    let store = NormalizedSnapshotStore(directory: root)
    let preferences = ProviderSelectionPreferences(defaults: defaults)
    preferences.save(ProviderSelection(enabled: [.codex]))
    try store.save(self.codexSnapshot(remaining: 40, capturedAt: now))
    let model = LiveQuotaModel(
      store: store,
      acquisitionEnabled: false,
      preferences: preferences
    )
    try store.save(self.codexSnapshot(remaining: 90, capturedAt: now))

    model.menuOpened()

    #expect(model.scenario.snapshots.first?.weekly?.remainingPercent == 40)
    for _ in 0..<100 where model.scenario.snapshots.first?.weekly?.remainingPercent != 90 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.scenario.snapshots.first?.weekly?.remainingPercent == 90)
  }

  private func codexSnapshot(remaining: Double, capturedAt: Date) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .codex,
      source: .codexAppServer,
      capturedAt: capturedAt,
      weekly: QuotaWindow(
        remainingPercent: remaining,
        durationSeconds: 604_800,
        resetAt: capturedAt.addingTimeInterval(300_000)
      ),
      sourceState: .observationSucceeded
    )
  }
}

@MainActor
private final class RecordingLoginItemService: LoginItemServicing {
  var state: LoginItemState
  var registerCount = 0
  var unregisterCount = 0
  let shouldFail: Bool

  init(state: LoginItemState, shouldFail: Bool = false) {
    self.state = state
    self.shouldFail = shouldFail
  }

  func register() throws {
    self.registerCount += 1
    if self.shouldFail { throw RecordingLoginItemError.failed }
    self.state = .enabled
  }

  func unregister() throws {
    self.unregisterCount += 1
    if self.shouldFail { throw RecordingLoginItemError.failed }
    self.state = .disabled
  }
}

private enum RecordingLoginItemError: Error {
  case failed
}
