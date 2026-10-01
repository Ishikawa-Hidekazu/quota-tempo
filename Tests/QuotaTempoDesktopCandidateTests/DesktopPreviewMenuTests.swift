import AppKit
import QuotaTempoCore
import Testing

@testable import QuotaTempoDesktopCandidate

@Suite("Desktop preview native menu")
@MainActor
struct DesktopPreviewMenuTests {
  private let now = Date(timeIntervalSince1970: 1_900_000_000)

  @Test("Compact native rows have no hosted views or implicit command validation")
  func structure() throws {
    let preview = makeMenu()
    preview.update(scenario: scenario(), refreshing: false)
    #expect(!preview.menu.autoenablesItems)
    #expect(preview.menu.numberOfItems == 12)
    #expect(preview.menu.items.allSatisfy { $0.view == nil && $0.submenu == nil })
    #expect(preview.menu.items.allSatisfy { $0.title.count <= 72 })
    for row in DesktopPreviewMenu.Row.allCases {
      let item = try #require(preview.menu.item(withTag: row.rawValue))
      #expect(!item.isEnabled)
      #expect(item.action == nil)
    }
    for command in DesktopPreviewMenu.Command.allCases {
      let item = try #require(preview.menu.item(withTag: command.rawValue))
      #expect(item.isEnabled)
      #expect(item.target === preview)
      guard let action = item.action else {
        Issue.record("Missing command selector")
        return
      }
      #expect(preview.responds(to: action))
      #expect(preview.menu.items.filter { $0.tag == command.rawValue }.count == 1)
    }
  }

  @Test("Current values use the planner and do not fabricate reset dates")
  func values() throws {
    let preview = makeMenu()
    preview.update(scenario: scenario(), refreshing: false)
    #expect(title(.weekly, preview) == "Weekly left: 75%")
    #expect(title(.target, preview) == "Target now: 50%")
    #expect(title(.difference, preview) == "Vs target: +25 pts")
    #expect(title(.reset, preview) != "Weekly reset: --")
    preview.update(scenario: scenario(available: false), refreshing: false)
    #expect(title(.weekly, preview) == "Weekly left: --")
    #expect(title(.target, preview) == "Target now: --")
    #expect(title(.difference, preview) == "Vs target: --")
    #expect(title(.reset, preview) == "Weekly reset: --")
    #expect(title(.captured, preview) == "Captured: --")
  }

  @Test("Close and Quit stay enabled through unavailable, busy and failure states")
  func escapeActions() throws {
    let preview = makeMenu()
    for available in [false, true] {
      for busy in [false, true] {
        for error: AcquisitionErrorCode? in [nil, .authenticationRequired, .temporaryFailure] {
          preview.update(scenario: scenario(available: available, error: error), refreshing: busy)
          #expect(preview.menu.item(withTag: 100)?.isEnabled == !busy)
          #expect(preview.menu.item(withTag: 101)?.isEnabled == true)
          #expect(preview.menu.item(withTag: 102)?.isEnabled == true)
          #expect(preview.menu.items.allSatisfy { $0.title.count <= 72 })
          #expect(!preview.menu.items.contains { $0.title.contains("claude auth login") })
        }
      }
    }
  }

  @Test("Actions cancel native tracking before invoking exactly one callback")
  func actionWiring() throws {
    var calls: [String] = []
    let preview = DesktopPreviewMenu(
      onRefresh: { calls.append("refresh") }, onQuit: { calls.append("quit") },
      cancelTracking: { _ in calls.append("dismiss") })
    for (command, expected): (DesktopPreviewMenu.Command, [String]) in [
      (.refresh, ["dismiss", "refresh"]), (.close, ["dismiss"]), (.quit, ["dismiss", "quit"]),
    ] {
      calls.removeAll()
      let item = try #require(preview.menu.item(withTag: command.rawValue))
      // Direct selector dispatch only: no NSApplication, menu tracking or OS events.
      guard let action = item.action else {
        Issue.record("Missing command selector")
        return
      }
      _ = preview.perform(action)
      #expect(calls == expected)
    }
  }

  @Test("Scheduling stops show distinct causes and retain exit actions")
  func schedulingStops() {
    let preview = makeMenu()
    for state: DesktopUsageState in [.serviceWaitUnavailable, .persistenceUnavailable] {
      preview.update(scenario: scenario(available: false), refreshing: false, state: state)
      #expect(title(.error, preview) == DesktopPreviewPresentation.schedulingNotice(state))
      #expect(preview.menu.item(withTag: 101)?.isEnabled == true)
      #expect(preview.menu.item(withTag: 102)?.isEnabled == true)
    }
    preview.update(scenario: scenario(), refreshing: false, state: .current)
    #expect(title(.error, preview) == "Result: observationSucceeded")
  }

  @Test("Updates preserve native item identities and do not invoke actions")
  func stableUpdates() {
    var callbacks = 0
    let preview = DesktopPreviewMenu(
      onRefresh: { callbacks += 1 }, onQuit: { callbacks += 1 },
      cancelTracking: { _ in callbacks += 1 })
    let items = preview.menu.items
    for index in 0..<20 {
      preview.update(scenario: scenario(available: index % 2 == 0), refreshing: index % 3 == 0)
      #expect(zip(items, preview.menu.items).allSatisfy { $0 === $1 })
    }
    #expect(callbacks == 0)
  }

  @Test("Empty snapshots clear all values while retaining enabled exit actions")
  func emptyScenario() {
    let preview = makeMenu()
    preview.update(scenario: scenario(), refreshing: false)
    preview.update(
      scenario: FixtureScenario(id: "empty", now: now, snapshots: []), refreshing: true)
    #expect(title(.weekly, preview) == "Weekly left: --")
    #expect(title(.reset, preview) == "Weekly reset: --")
    #expect(preview.menu.item(withTag: 101)?.isEnabled == true)
    #expect(preview.menu.item(withTag: 102)?.isEnabled == true)
  }

  private func makeMenu() -> DesktopPreviewMenu {
    DesktopPreviewMenu(timeZone: TimeZone(secondsFromGMT: 0)!, onRefresh: {}, onQuit: {})
  }

  private func title(_ row: DesktopPreviewMenu.Row, _ preview: DesktopPreviewMenu) -> String? {
    preview.menu.item(withTag: row.rawValue)?.title
  }

  private func scenario(
    available: Bool = true, error: AcquisitionErrorCode? = nil
  ) -> FixtureScenario {
    FixtureScenario(
      id: "synthetic-menu", now: now,
      snapshots: [
        ProviderSnapshot(
          provider: .claude, source: .claudeDesktopDirect,
          capturedAt: available ? now : nil,
          weekly: available
            ? QuotaWindow(
              remainingPercent: 75, durationSeconds: 604_800,
              resetAt: now.addingTimeInterval(302_400)) : nil,
          sourceState: error == nil ? .observationSucceeded : .attemptFailed, errorCode: error)
      ])
  }
}
