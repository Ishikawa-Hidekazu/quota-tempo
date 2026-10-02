#if DESKTOP_INTEGRATION_PREVIEW
  import Foundation
  import Testing
  @testable import QuotaTempoApp
  @testable import QuotaTempoCore
  @testable import QuotaTempoDesktopCandidate

  @Suite("Desktop integration lifecycle")
  @MainActor
  struct DesktopIntegrationLifecycleTests {
    @Test("Startup forwards the current acquisition gate", arguments: [false, true])
    func startupGate(allowed: Bool) async {
      let connection = LifecycleConnectionSpy()
      let lifecycle = DesktopIntegrationLifecycle(
        connection: connection, acquisitionAllowed: { allowed })
      await lifecycle.start()
      #expect(connection.events == [.resume(allowed)])
    }

    @Test("Scheduling refresh updates display but never overrides provider admission")
    func normalRefresh() async {
      let connection = LifecycleConnectionSpy()
      let lifecycle = DesktopIntegrationLifecycle(
        connection: connection, acquisitionAllowed: { true })
      #expect(DesktopIntegrationLifecycle.schedulingInterval == 30)
      await lifecycle.refresh()
      await lifecycle.refresh()
      #expect(connection.events == [.display, .refresh(false), .display, .refresh(false)])
    }

    @Test("A queued refresh rechecks the provider gate when it runs")
    func disabledBeforeQueuedRefresh() async {
      let connection = LifecycleConnectionSpy()
      let gate = LifecycleGate()
      let lifecycle = DesktopIntegrationLifecycle(
        connection: connection, acquisitionAllowed: { gate.allowed })
      let queued = Task { await lifecycle.refresh() }
      gate.allowed = false
      await queued.value
      #expect(connection.events == [.display])
    }

    @Test("Cancelled startup and refresh cannot request acquisition")
    func cancelledWork() async {
      let connection = LifecycleConnectionSpy()
      let lifecycle = DesktopIntegrationLifecycle(
        connection: connection, acquisitionAllowed: { true })
      let queued = Task {
        await lifecycle.start()
        await lifecycle.refresh()
      }
      queued.cancel()
      await queued.value
      #expect(connection.events == [.display])
    }

    @Test("Claude off revokes synchronously; enabling a provider does not reconnect")
    func selectionChange() {
      let connection = LifecycleConnectionSpy()
      let lifecycle = DesktopIntegrationLifecycle(
        connection: connection, acquisitionAllowed: { true })
      lifecycle.providersChanged([.codex])
      #expect(connection.events == [.revoke])
      lifecycle.providersChanged([.codex, .claude])
      lifecycle.providersChanged([.claude])
      #expect(connection.events == [.revoke])
    }

    @Test("Production controller resumes once and cannot reconnect after off/on")
    func controllerConsentLifecycle() async {
      let consent = LifecycleConsentStub(accepted: true)
      let service = LifecycleServiceStub()
      let controller = DesktopConnectionController(
        makeService: { service }, repairStore: { _ in .notNeeded }, consentStore: consent,
        authorizeKeychainAccess: {
          Issue.record("Lifecycle events must not request macOS permission")
          return false
        })
      let lifecycle = DesktopIntegrationLifecycle(
        connection: controller, acquisitionAllowed: { true })
      await lifecycle.start()
      await lifecycle.start()
      #expect(consent.reads == 1)
      #expect(controller.isConnected)
      #expect(await service.refreshes == 1)
      await lifecycle.refresh()
      #expect(await service.refreshes == 2)
      #expect(await service.rechecks == 0)

      lifecycle.providersChanged([.codex])
      #expect(!controller.isConnected)
      #expect(!consent.accepted)
      lifecycle.providersChanged([.codex, .claude])
      await lifecycle.start()
      await lifecycle.refresh()
      #expect(!controller.isConnected)
      #expect(consent.reads == 1)
      #expect(await service.refreshes == 2)
      await controller.disconnect()
    }

    @Test("Disabled acquisition does not read consent or create a service")
    func disabledControllerHasNoAccess() async {
      let consent = LifecycleConsentStub(accepted: true)
      let controller = DesktopConnectionController(
        makeService: {
          Issue.record("Disabled lifecycle must not construct a service")
          return LifecycleServiceStub()
        }, repairStore: { _ in .notNeeded }, consentStore: consent)
      let lifecycle = DesktopIntegrationLifecycle(
        connection: controller, acquisitionAllowed: { false })
      await lifecycle.start()
      await lifecycle.refresh()
      #expect(consent.reads == 0)
      #expect(!controller.isConnected)
      #expect(controller.snapshot == nil)
    }

    @Test("Timer and wake refresh cannot grant missing consent")
    func noImplicitConsent() async {
      let consent = LifecycleConsentStub(accepted: false)
      let controller = DesktopConnectionController(
        makeService: {
          Issue.record("Lifecycle must not grant consent")
          return LifecycleServiceStub()
        }, repairStore: { _ in .notNeeded }, consentStore: consent)
      let lifecycle = DesktopIntegrationLifecycle(
        connection: controller, acquisitionAllowed: { true })
      await lifecycle.start()
      await lifecycle.refresh()
      await lifecycle.refresh()
      #expect(consent.reads == 1)
      #expect(!controller.isConnected)
      #expect(!consent.accepted)
    }

    @Test("Overlapping timer and wake updates share one in-flight refresh")
    func overlappingRefreshes() async {
      let service = LifecycleServiceStub()
      let controller = DesktopConnectionController(
        makeService: { service }, repairStore: { _ in .notNeeded },
        consentStore: LifecycleConsentStub(accepted: true))
      let lifecycle = DesktopIntegrationLifecycle(
        connection: controller, acquisitionAllowed: { true })
      await lifecycle.start()
      let gate = LifecycleServiceGate()
      await service.blockNextRefresh(gate)
      let timer = Task { await lifecycle.refresh() }
      await gate.waitForEntry()
      await lifecycle.refresh()
      #expect(await service.refreshes == 2)
      #expect(await service.rechecks == 0)
      await gate.release()
      await timer.value
      #expect(controller.isConnected)
      await controller.disconnect()
    }

    @Test("Off/on during an in-flight update rejects its late quota without reconnecting")
    func offDuringRefresh() async {
      let now = Date(timeIntervalSince1970: 1_900_000_000)
      let service = LifecycleServiceStub(
        result: DesktopUsageCandidateResult(
          disposition: .replaceDisplay, state: .current,
          observation: DesktopUsageObservation(
            owner: DesktopUsageOwner(
              accountFingerprint: String(repeating: "a", count: 64),
              organizationFingerprint: String(repeating: "b", count: 64)), capturedAt: now,
            values: DesktopUsageValues(
              weekly: QuotaWindow(
                remainingPercent: 80, durationSeconds: 604_800,
                resetAt: now.addingTimeInterval(400_000)), fiveHour: nil)),
          credentialError: nil, nextAllowedAt: nil))
      let consent = LifecycleConsentStub(accepted: true)
      let controller = DesktopConnectionController(
        clock: { now }, makeService: { service }, repairStore: { _ in .notNeeded },
        consentStore: consent)
      let lifecycle = DesktopIntegrationLifecycle(
        connection: controller, acquisitionAllowed: { true })
      await lifecycle.start()
      #expect(controller.snapshot?.weekly?.remainingPercent == 80)
      let gate = LifecycleServiceGate()
      await service.blockNextRefresh(gate)
      let pending = Task { await lifecycle.refresh() }
      await gate.waitForEntry()
      lifecycle.providersChanged([.codex])
      #expect(!controller.isConnected && controller.snapshot == nil)
      #expect(!consent.accepted)
      lifecycle.providersChanged([.codex, .claude])
      await lifecycle.start()
      await lifecycle.refresh()
      await gate.release()
      await pending.value
      #expect(controller.status == .disconnected)
      #expect(!controller.isConnected && controller.snapshot == nil)
      #expect(await service.refreshes == 2)
      #expect(await service.rechecks == 0)
      await controller.disconnect()
    }
  }

  @MainActor
  private final class LifecycleGate {
    var allowed = true
  }

  @MainActor
  private final class LifecycleConnectionSpy: DesktopLifecycleConnecting {
    enum Event: Equatable {
      case resume(Bool)
      case display
      case refresh(Bool)
      case revoke
    }
    var events: [Event] = []
    func resumeIfConsented(acquisitionAllowed: Bool) { events.append(.resume(acquisitionAllowed)) }
    func updateDisplay() { events.append(.display) }
    func refresh(recheck: Bool) { events.append(.refresh(recheck)) }
    func revokeConsent() { events.append(.revoke) }
  }

  @MainActor
  private final class LifecycleConsentStub: DesktopConnectionConsentStoring {
    var accepted: Bool
    var reads = 0
    init(accepted: Bool) { self.accepted = accepted }
    func isAccepted() throws -> Bool {
      reads += 1
      return accepted
    }
    func setAccepted(_ accepted: Bool) throws { self.accepted = accepted }
  }

  private actor LifecycleServiceStub: DesktopConnectionServing {
    private(set) var refreshes = 0
    private(set) var rechecks = 0
    private var gate: LifecycleServiceGate?
    private let result: DesktopUsageCandidateResult

    init(result: DesktopUsageCandidateResult? = nil) {
      self.result =
        result
        ?? DesktopUsageCandidateResult(
          disposition: .replaceDisplay, state: .temporaryFailure,
          observation: nil, credentialError: nil, nextAllowedAt: nil)
    }

    func blockNextRefresh(_ gate: LifecycleServiceGate) { self.gate = gate }
    func setApproval(_ approval: DesktopAccessApproval) {}
    func prepareForOfflineRepair() -> Bool { true }
    func refresh() async -> DesktopUsageCandidateResult {
      refreshes += 1
      if let gate {
        self.gate = nil
        await gate.pause()
      }
      return result
    }
    func recheckConnection() async -> DesktopUsageCandidateResult {
      rechecks += 1
      return await refresh()
    }
  }

  private actor LifecycleServiceGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?

    func pause() async {
      entered = true
      waiting?.resume()
      waiting = nil
      await withCheckedContinuation { blocked = $0 }
    }

    func waitForEntry() async {
      if !entered { await withCheckedContinuation { waiting = $0 } }
    }

    func release() {
      blocked?.resume()
      blocked = nil
    }
  }
#endif
