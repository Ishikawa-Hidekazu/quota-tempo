import AppKit
import QuotaTempoCore

// The isolated preview uses only native menu items. AppKit owns positioning,
// tracking, Escape and outside-click dismissal; no hosted view owns dismissal.
@MainActor
final class DesktopPreviewMenu: NSObject {
  enum Row: Int, CaseIterable {
    case heading, status, weekly, target, difference, reset, captured, error
  }

  enum Command: Int, CaseIterable {
    case refresh = 100
    case close
    case quit
    case recheck
  }

  let menu = NSMenu(title: "QuotaTempo Desktop Preview")
  private let onRefresh: () -> Void
  private let onQuit: () -> Void
  private let onRecheck: (() -> Void)?
  private let cancelTracking: (NSMenu) -> Void
  private let dateFormatter: DateFormatter

  init(
    timeZone: TimeZone = .current,
    onRefresh: @escaping () -> Void,
    onQuit: @escaping () -> Void,
    onRecheck: (() -> Void)? = nil,
    cancelTracking: @escaping (NSMenu) -> Void = { $0.cancelTracking() }
  ) {
    self.onRefresh = onRefresh
    self.onQuit = onQuit
    self.onRecheck = onRecheck
    self.cancelTracking = cancelTracking
    dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = timeZone
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm z"
    super.init()
    menu.autoenablesItems = false
    for row in Row.allCases {
      let item = NSMenuItem(title: "--", action: nil, keyEquivalent: "")
      item.tag = row.rawValue
      item.isEnabled = false
      menu.addItem(item)
    }
    set(.heading, "QuotaTempo Desktop Preview (local)")
    menu.addItem(.separator())
    add(.refresh, title: "Refresh", action: #selector(refresh))
    add(.recheck, title: "Recheck Connection Once", action: #selector(recheck))
    add(.close, title: "Close Menu", action: #selector(close))
    add(.quit, title: "Quit Desktop Preview", action: #selector(quit))
  }

  func update(
    scenario: FixtureScenario, refreshing: Bool, state: DesktopUsageState? = nil,
    nextAllowedAt: Date? = nil
  ) {
    let plan = scenario.snapshots.first(where: { $0.provider == .claude })
      .map { QuotaPlanner.evaluate($0, now: scenario.now) }
    let copy = MenuCopy(languageCode: "en")
    set(.status, "Claude Desktop: \(plan.map { copy.status(for: $0) } ?? "Unavailable")")
    set(.weekly, "Weekly left: \(percent(plan?.weeklyRemaining))")
    set(.target, "Target now: \(percent(plan?.targetNow))")
    set(.difference, "Vs target: \(difference(plan?.vsTarget))")
    set(.reset, "Weekly reset: \(date(plan?.weeklyResetAt))")
    set(.captured, "Captured: \(date(plan?.capturedAt))")
    set(
      .error,
      "Result: \(plan?.errorCode?.rawValue ?? (refreshing ? "refreshing" : plan?.sourceState?.rawValue ?? "--"))"
    )
    if let state, let notice = DesktopPreviewPresentation.schedulingNotice(state) {
      set(.error, notice)
    }
    if state == .waitingForNextRefresh {
      set(.status, "Claude Desktop: Waiting for next update")
      set(.error, "Next update: \(date(nextAllowedAt))")
    }
    if state == .waitingForProvider {
      set(.status, "Claude Desktop: Provider wait")
      set(.error, "Requests paused until: \(date(nextAllowedAt))")
    }
    let canRecheck =
      state == .waitingForDesktopRenewal || state == .accessDenied
      || state == .serviceWaitUnavailable
    menu.item(withTag: Command.recheck.rawValue)?.isHidden = !canRecheck
    menu.item(withTag: Command.recheck.rawValue)?.isEnabled =
      canRecheck && onRecheck != nil && !refreshing
      && (nextAllowedAt.map { $0 <= scenario.now } ?? true)
    menu.item(withTag: Command.refresh.rawValue)?.isEnabled = !refreshing
    // Close and Quit must remain available even while acquisition is blocked.
    menu.item(withTag: Command.close.rawValue)?.isEnabled = true
    menu.item(withTag: Command.quit.rawValue)?.isEnabled = true
  }

  func dismiss() { cancelTracking(menu) }

  private func add(_ command: Command, title: String, action: Selector) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.tag = command.rawValue
    item.target = self
    item.isEnabled = true
    menu.addItem(item)
  }

  private func set(_ row: Row, _ value: String) {
    menu.item(withTag: row.rawValue)?.title = String(value.prefix(72))
  }

  private func percent(_ value: Double?) -> String {
    guard let value, value.isFinite, (0...100).contains(value) else { return "--" }
    return "\(Int(value.rounded()))%"
  }

  private func difference(_ value: Double?) -> String {
    guard let value, value.isFinite, (-100...100).contains(value) else { return "--" }
    let rounded = Int(value.rounded())
    return "\(rounded > 0 ? "+" : "")\(rounded) pts"
  }

  private func date(_ value: Date?) -> String {
    value.map { dateFormatter.string(from: $0) } ?? "--"
  }

  @objc private func refresh() {
    dismiss()
    onRefresh()
  }

  @objc private func close() { dismiss() }

  @objc private func recheck() {
    dismiss()
    onRecheck?()
  }

  @objc private func quit() {
    dismiss()
    onQuit()
  }
}
