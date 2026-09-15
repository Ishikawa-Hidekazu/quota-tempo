import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuotaTempoCore

@Suite("QuotaPlanner deterministic weekly planning")
struct QuotaPlannerTests {
  private let now = Date(timeIntervalSince1970: 1_789_300_800)
  private let week: TimeInterval = 604_800

  @Test("Detail dates include a localized weekday")
  func detailDatesIncludeLocalizedWeekday() {
    let date = Date(timeIntervalSince1970: 1_789_001_280)
    let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let english = QuotaDateFormatting.string(
      date,
      locale: Locale(identifier: "en"),
      timeZone: timeZone
    )
    let japanese = QuotaDateFormatting.string(
      date,
      locale: Locale(identifier: "ja"),
      timeZone: timeZone
    )

    #expect(english.contains("Thu"))
    #expect(english.contains("Sep"))
    #expect(japanese.contains("9月10日(木)"))
    #expect(
      QuotaDateFormatting.string(nil, locale: Locale(identifier: "en"), timeZone: timeZone)
        == "—"
    )
  }

  @Test("Detail dates follow regional locale order independently of UI language")
  func detailDatesRespectRegionalLocale() {
    let date = Date(timeIntervalSince1970: 1_789_001_280)
    let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let unitedStates = QuotaDateFormatting.string(
      date,
      locale: Locale(identifier: "en_US"),
      timeZone: timeZone
    )
    let unitedKingdom = QuotaDateFormatting.string(
      date,
      locale: Locale(identifier: "en_GB"),
      timeZone: timeZone
    )

    #expect(unitedStates.contains("Sep 10"))
    #expect(unitedKingdom.contains("10 Sep"))
    #expect(unitedStates != unitedKingdom)
  }

  @Test("Menu popover retains a usable height in main and onboarding views")
  @MainActor
  func menuPopoverRetainsHeight() throws {
    let scenario = try FixtureLoader.load("baseline")
    let cases = [
      (languageCode: "en", onboardingPresented: false),
      (languageCode: "ja", onboardingPresented: false),
      (languageCode: "en", onboardingPresented: true),
      (languageCode: "ja", onboardingPresented: true),
    ]
    for testCase in cases {
      let view = QuotaMenuView(
        scenario: scenario,
        languageCode: testCase.languageCode,
        timeZone: TimeZone(secondsFromGMT: 0)!,
        onboardingPresented: .constant(testCase.onboardingPresented),
        enabledProviders: Set(scenario.snapshots.map(\.provider)),
        onRefresh: {},
        onQuit: {}
      )
      let renderer = ImageRenderer(content: view)
      renderer.proposedSize = ProposedViewSize(width: QuotaMenuLayout.width, height: 1)
      let compressed = try #require(renderer.nsImage).size

      #expect(compressed.width == QuotaMenuLayout.width)
      #expect(
        compressed.height
          >= (testCase.onboardingPresented
            ? QuotaMenuLayout.onboardingMinimumHeight : QuotaMenuLayout.contentMinimumHeight)
      )
    }
  }

  @Test("Menu viewport clamps to a small visible screen")
  func menuViewportClampsToVisibleScreen() {
    let compactScreenHeight: CGFloat = 775
    let main = QuotaMenuLayout.viewportHeightRange(
      onboarding: false,
      availableHeight: compactScreenHeight
    )
    let onboarding = QuotaMenuLayout.viewportHeightRange(
      onboarding: true,
      availableHeight: compactScreenHeight
    )

    #expect(main.lowerBound == 695)
    #expect(main.upperBound == 695)
    #expect(onboarding.lowerBound == 650)
    #expect(onboarding.upperBound == 695)
    #expect(
      QuotaMenuLayout.applicationContentHeight(
        onboarding: false,
        availableHeight: compactScreenHeight
      ) == 731
    )
  }

  @Test("Menu popover caps its viewport without shrinking the application window")
  func menuPopoverUsesIndependentHeightCap() {
    let availableHeight: CGFloat = 1_200
    let popover = QuotaMenuLayout.viewportHeightRange(
      onboarding: false,
      availableHeight: availableHeight,
      maximumHeight: QuotaMenuLayout.menuPopoverMaximumHeight
    )
    let applicationWindow = QuotaMenuLayout.viewportHeightRange(
      onboarding: false,
      availableHeight: availableHeight
    )

    #expect(popover.lowerBound == QuotaMenuLayout.menuPopoverMaximumHeight)
    #expect(popover.upperBound == QuotaMenuLayout.menuPopoverMaximumHeight)
    #expect(applicationWindow.lowerBound == QuotaMenuLayout.contentMinimumHeight)
    #expect(applicationWindow.upperBound == QuotaMenuLayout.contentMaximumHeight)
  }

  @Test("Operational popover renders within its anchoring height budget")
  @MainActor
  func operationalPopoverFitsAnchoringBudget() throws {
    let scenario = try FixtureLoader.load("baseline")
    let view = QuotaMenuView(
      scenario: scenario,
      languageCode: "en",
      timeZone: TimeZone(secondsFromGMT: 0)!,
      availableHeight: 1_200,
      maximumViewportHeight: QuotaMenuLayout.menuPopoverMaximumHeight,
      enabledProviders: Set(scenario.snapshots.map(\.provider)),
      onRefresh: {},
      onQuit: {}
    )
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: QuotaMenuLayout.width, height: 1)
    let rendered = try #require(renderer.nsImage).size

    #expect(rendered.width == QuotaMenuLayout.width)
    #expect(
      rendered.height
        <= QuotaMenuLayout.menuPopoverMaximumHeight + QuotaMenuLayout.verticalPadding
    )
  }

  @Test("Small-screen menu renders within its visible-height budget")
  @MainActor
  func smallScreenMenuFitsVisibleHeight() throws {
    let scenario = try FixtureLoader.load("baseline")
    let view = QuotaMenuView(
      scenario: scenario,
      languageCode: "en",
      timeZone: TimeZone(secondsFromGMT: 0)!,
      availableHeight: 775,
      enabledProviders: Set(scenario.snapshots.map(\.provider)),
      onRefresh: {},
      onQuit: {}
    )
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: QuotaMenuLayout.width, height: 1)
    let rendered = try #require(renderer.nsImage).size

    #expect(rendered.width == QuotaMenuLayout.width)
    #expect(rendered.height <= 731)
  }

  @Test("Localized onboarding explains all menu bar display modes")
  func localizedOnboardingExplainsDisplayModes() {
    for language in ["en", "ja"] {
      let copy = MenuCopy(languageCode: language)
      #expect(copy.text("onboarding.menu.title") != "onboarding.menu.title")
      #expect(copy.text("onboarding.menu.intro") != "onboarding.menu.intro")
      #expect(copy.text("onboarding.menu.note") != "onboarding.menu.note")
      #expect(copy.text("onboarding.reopen") != "onboarding.reopen")
      for mode in MenuBarDisplayMode.allCases {
        #expect(copy.text("menu.bar.mode.\(mode.rawValue)") != "menu.bar.mode.\(mode.rawValue)")
      }
    }
  }

  @Test("Localized menu fixtures retain clear outer padding")
  @MainActor
  func localizedMenuFixturesRetainOuterPadding() throws {
    let cases = [
      (fixture: "baseline", languageCode: "en"),
      (fixture: "baseline", languageCode: "ja"),
      (fixture: "degraded", languageCode: "ja"),
    ]

    for testCase in cases {
      let scenario = try FixtureLoader.load(testCase.fixture)
      let view = QuotaMenuView(
        scenario: scenario,
        languageCode: testCase.languageCode,
        timeZone: TimeZone(secondsFromGMT: 0)!,
        enabledProviders: Set(scenario.snapshots.map(\.provider)),
        onRefresh: {},
        onQuit: {}
      )
      .environment(\.colorScheme, .light)
      let renderer = ImageRenderer(content: view)
      renderer.proposedSize = ProposedViewSize(width: QuotaMenuLayout.width, height: 1)
      let image = try #require(renderer.nsImage)
      let representation = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init))

      #expect(
        self.hasClearOuterPadding(representation),
        "\(testCase.fixture)-\(testCase.languageCode) rendered into the outer padding"
      )
    }
  }

  private func hasClearOuterPadding(_ image: NSBitmapImageRep) -> Bool {
    let inset = 8
    let lastX = image.pixelsWide - 1
    let lastY = image.pixelsHigh - 1

    for x in 0...lastX {
      for y in 0..<inset where self.hasVisibleInk(image.colorAt(x: x, y: y)) { return false }
      for y in (lastY - inset + 1)...lastY where self.hasVisibleInk(image.colorAt(x: x, y: y)) {
        return false
      }
    }
    for y in 0...lastY {
      for x in 0..<inset where self.hasVisibleInk(image.colorAt(x: x, y: y)) { return false }
      for x in (lastX - inset + 1)...lastX where self.hasVisibleInk(image.colorAt(x: x, y: y)) {
        return false
      }
    }
    return true
  }

  private func hasVisibleInk(_ color: NSColor?) -> Bool {
    guard let color = color?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.05 else {
      return false
    }
    return color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95
  }

  @Test("Baseline fixture produces exact target differences and checkpoint")
  func baseline() throws {
    let scenario = try FixtureLoader.load("baseline")
    let plans = scenario.snapshots.map { QuotaPlanner.evaluate($0, now: scenario.now) }

    #expect(plans.count == 2)
    #expect(QuotaPlanner.roundedPercent(plans[0].targetNow!) == 48)
    #expect(QuotaPlanner.roundedPercent(plans[0].vsTarget!) == -14)
    #expect(plans[0].status == .belowTarget)
    #expect(!plans[0].targetIsEstimated)
    #expect(QuotaPlanner.roundedPercent(plans[1].vsTarget!) == 12)
    #expect(plans[1].status == .aboveTarget)
    #expect(plans[1].fiveHourRisk)
    #expect(plans[0].weeklyResetAt == plans[1].weeklyResetAt)
    #expect(!plans[0].weeklyResetIsEstimated)
    #expect(plans[0].nextCheckpoint == plans[1].nextCheckpoint)
  }

  @Test("Tolerance boundaries are on target")
  func toleranceBoundaries() {
    let target = 50.0
    let reset = self.now.addingTimeInterval(self.week / 2)
    for remaining in [target - 2, target + 2] {
      let plan = self.plan(remaining: remaining, resetAt: reset)
      #expect(plan.status == .onTarget)
    }
    #expect(self.plan(remaining: target + 2.49, resetAt: reset).status == .onTarget)
    #expect(self.plan(remaining: target - 2.49, resetAt: reset).status == .onTarget)
    #expect(self.plan(remaining: target + 2.5, resetAt: reset).status == .aboveTarget)
    #expect(self.plan(remaining: target - 2.51, resetAt: reset).status == .belowTarget)
  }

  @Test("Bundled on-target fixture covers exact and tolerance-edge states")
  func bundledOnTarget() throws {
    let scenario = try FixtureLoader.load("on-target")
    let plans = scenario.snapshots.map { QuotaPlanner.evaluate($0, now: scenario.now) }
    #expect(plans.map(\.status) == [.onTarget, .onTarget])
    #expect(plans.map { QuotaPlanner.roundedPercent($0.vsTarget!) } == [0, 2])
  }

  @Test("Freshness covers live recent stale and future-unavailable")
  func freshness() {
    #expect(
      QuotaPlanner.freshness(capturedAt: self.now.addingTimeInterval(-300), now: self.now) == .live)
    #expect(
      QuotaPlanner.freshness(capturedAt: self.now.addingTimeInterval(-301), now: self.now)
        == .recent)
    #expect(
      QuotaPlanner.freshness(capturedAt: self.now.addingTimeInterval(-1_801), now: self.now)
        == .stale)
    #expect(
      QuotaPlanner.freshness(capturedAt: self.now.addingTimeInterval(1), now: self.now)
        == .unavailable)

    let futureSnapshot = self.snapshot(
      remaining: 50,
      resetAt: self.now.addingTimeInterval(self.week / 2),
      capturedAt: self.now.addingTimeInterval(1)
    )
    let futurePlan = QuotaPlanner.evaluate(futureSnapshot, now: self.now)
    #expect(futurePlan.status == .unavailable)
    #expect(futurePlan.targetNow == nil)
    #expect(futurePlan.vsTarget == nil)
  }

  @Test("Stale balance keeps reset-derived planning but withholds balance-derived comparisons")
  func stale() {
    let reset = self.now.addingTimeInterval(self.week / 2)
    let plan = self.plan(
      remaining: 80,
      resetAt: reset,
      capturedAt: self.now.addingTimeInterval(-3_600)
    )
    #expect(plan.status == .stale)
    #expect(plan.weeklyRemaining == 80)
    #expect(plan.freshness == .stale)
    #expect(plan.targetNow == 50)
    #expect(!plan.targetIsEstimated)
    #expect(plan.vsTarget == nil)
    #expect(plan.weeklyResetAt == reset)
    #expect(plan.nextCheckpoint != nil)
    #expect(plan.checkpointTarget != nil)
    #expect(plan.availableUntilCheckpoint == nil)
  }

  @Test("Stale planning target advances with time without refreshing the balance")
  func staleTargetAdvancesWithTime() {
    let snapshot = self.snapshot(
      remaining: 80,
      resetAt: self.now.addingTimeInterval(self.week / 2),
      capturedAt: self.now.addingTimeInterval(-3_600)
    )
    let first = QuotaPlanner.evaluate(snapshot, now: self.now)
    let second = QuotaPlanner.evaluate(snapshot, now: self.now.addingTimeInterval(60))

    #expect(first.status == .stale)
    #expect(second.status == .stale)
    #expect(second.targetNow! < first.targetNow!)
    #expect(second.vsTarget == nil)
    #expect(second.availableUntilCheckpoint == nil)
  }

  @Test("Missing and invalid weekly quota inputs are unavailable")
  func unavailableInputs() {
    let missing = ProviderSnapshot(
      provider: .codex,
      source: .fixture,
      capturedAt: self.now,
      weekly: nil
    )
    #expect(QuotaPlanner.evaluate(missing, now: self.now).status == .unavailable)

    for remaining in [-0.1, 100.1, .infinity] {
      #expect(
        self.plan(remaining: remaining, resetAt: self.now.addingTimeInterval(self.week / 2)).status
          == .unavailable)
    }

    #expect(
      self.plan(remaining: 50, resetAt: self.now.addingTimeInterval(86_400), duration: 86_400)
        .status == .unavailable)
  }

  @Test("Bundled all-unavailable fixture never produces comparison values")
  func bundledAllUnavailable() throws {
    let scenario = try FixtureLoader.load("all-unavailable")
    let plans = scenario.snapshots.map { QuotaPlanner.evaluate($0, now: scenario.now) }
    #expect(plans.map(\.status) == [.unavailable, .unavailable])
    #expect(plans.allSatisfy { $0.targetNow == nil && $0.vsTarget == nil })
  }

  @Test("Bundled one-provider fixture evaluates one fresh provider")
  func bundledOneProvider() throws {
    let scenario = try FixtureLoader.load("one-provider")
    let plans = scenario.snapshots.map { QuotaPlanner.evaluate($0, now: scenario.now) }
    #expect(plans.count == 1)
    #expect(plans[0].provider == .codex)
    #expect(plans[0].status == .aboveTarget)
    #expect(plans[0].targetNow != nil)
    #expect(plans[0].vsTarget != nil)
  }

  @Test("Missing reset keeps the observed balance but withholds target math")
  func missingResetKeepsBalanceOnly() throws {
    let url = try #require(
      Bundle.module.url(forResource: "malformed-missing-reset", withExtension: "json")
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let scenario = try decoder.decode(FixtureScenario.self, from: Data(contentsOf: url))
    let snapshot = try #require(scenario.snapshots.first)
    let plan = QuotaPlanner.evaluate(snapshot, now: scenario.now)
    #expect(plan.weeklyRemaining == 62)
    #expect(plan.targetNow == nil)
    #expect(plan.vsTarget == nil)
    #expect(plan.status == .resetUnknown)
  }

  @Test("Checkpoint is strictly after an exact boundary")
  func exactCheckpointBoundary() {
    let reset = self.now.addingTimeInterval(3 * 86_400)
    let checkpoint = QuotaPlanner.nextCheckpoint(now: self.now, resetAt: reset, duration: self.week)
    #expect(checkpoint == self.now.addingTimeInterval(86_400))
  }

  @Test("Final checkpoint is reset")
  func finalCheckpoint() {
    let reset = self.now.addingTimeInterval(12 * 60 * 60)
    #expect(
      QuotaPlanner.nextCheckpoint(now: self.now, resetAt: reset, duration: self.week) == reset)
    let plan = self.plan(remaining: 7, resetAt: reset)
    #expect(plan.checkpointTarget == 0)
    #expect(plan.availableUntilCheckpoint == 7)
  }

  @Test("Absolute-date math is timezone independent")
  func timezoneIndependence() throws {
    let formatter = ISO8601DateFormatter()
    let utcNow = try #require(formatter.date(from: "2026-09-07T12:00:00Z"))
    let offsetNow = try #require(formatter.date(from: "2026-09-07T05:00:00-07:00"))
    #expect(utcNow == offsetNow)

    let reset = utcNow.addingTimeInterval(3.4 * 86_400)
    let snapshot = ProviderSnapshot(
      provider: .codex,
      source: .fixture,
      capturedAt: utcNow,
      weekly: QuotaWindow(
        remainingPercent: 50,
        durationSeconds: self.week,
        resetAt: reset
      )
    )
    let first = QuotaPlanner.evaluate(snapshot, now: utcNow)
    let second = QuotaPlanner.evaluate(snapshot, now: offsetNow)
    #expect(first.targetNow == second.targetNow)
    #expect(first.nextCheckpoint == second.nextCheckpoint)
  }

  @Test("Display rounding uses nearest away from zero")
  func rounding() {
    #expect(QuotaPlanner.roundedPercent(48.49) == 48)
    #expect(QuotaPlanner.roundedPercent(48.5) == 49)
    #expect(QuotaPlanner.roundedPercent(-14.5) == -15)
  }

  @Test("Five-hour warning requires a fresh immediate constraint")
  func fiveHourRisk() {
    let reset = self.now.addingTimeInterval(self.week / 2)
    let shortReset = self.now.addingTimeInterval(2 * 60 * 60)
    let short = QuotaWindow(remainingPercent: 15, durationSeconds: 18_000, resetAt: shortReset)
    let snapshot = ProviderSnapshot(
      provider: .claude,
      source: .fixture,
      capturedAt: self.now,
      weekly: QuotaWindow(remainingPercent: 50, durationSeconds: self.week, resetAt: reset),
      fiveHour: short
    )
    #expect(QuotaPlanner.evaluate(snapshot, now: self.now).fiveHourRisk)

    let resetUnknown = ProviderSnapshot(
      provider: .claude,
      source: .fixture,
      capturedAt: self.now,
      weekly: QuotaWindow(remainingPercent: 50, durationSeconds: self.week, resetAt: nil),
      fiveHour: short
    )
    let resetUnknownPlan = QuotaPlanner.evaluate(resetUnknown, now: self.now)
    #expect(resetUnknownPlan.status == .resetUnknown)
    #expect(resetUnknownPlan.fiveHourRisk)

    let stale = ProviderSnapshot(
      provider: .claude,
      source: .fixture,
      capturedAt: self.now.addingTimeInterval(-3_600),
      weekly: snapshot.weekly,
      fiveHour: short
    )
    #expect(!QuotaPlanner.evaluate(stale, now: self.now).fiveHourRisk)
  }

  @Test("Five-hour risk remains visible when the weekly window is absent")
  func fiveHourRiskWithoutWeeklyWindow() {
    let snapshot = ProviderSnapshot(
      provider: .claude,
      source: .fixture,
      capturedAt: self.now,
      weekly: nil,
      fiveHour: QuotaWindow(
        remainingPercent: 10,
        durationSeconds: 18_000,
        resetAt: self.now.addingTimeInterval(2 * 60 * 60)
      )
    )
    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)
    #expect(plan.status == .unavailable)
    #expect(plan.weeklyRemaining == nil)
    #expect(plan.fiveHourRisk)
  }

  @Test("An elapsed reset hides the old weekly balance")
  func elapsedResetHidesWeeklyBalance() {
    let snapshot = ProviderSnapshot(
      provider: .claude,
      source: .fixture,
      capturedAt: self.now,
      weekly: QuotaWindow(
        remainingPercent: 73,
        durationSeconds: self.week,
        resetAt: self.now.addingTimeInterval(-1)
      )
    )

    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)
    #expect(plan.status == .resetElapsed)
    #expect(plan.weeklyRemaining == nil)
    #expect(plan.targetNow == nil)
    #expect(plan.vsTarget == nil)
    #expect(plan.weeklyResetAt == nil)
    #expect(plan.nextCheckpoint == nil)
  }

  @Test("An elapsed reset hides an old stale weekly balance")
  func elapsedResetHidesStaleWeeklyBalance() {
    let snapshot = ProviderSnapshot(
      provider: .claude,
      source: .fixture,
      capturedAt: self.now.addingTimeInterval(-3_600),
      weekly: QuotaWindow(
        remainingPercent: 73,
        durationSeconds: self.week,
        resetAt: self.now.addingTimeInterval(-1)
      )
    )

    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)
    #expect(plan.status == .resetElapsed)
    #expect(plan.freshness == .stale)
    #expect(plan.weeklyRemaining == nil)
    #expect(plan.targetNow == nil)
    #expect(plan.vsTarget == nil)
    #expect(plan.weeklyResetAt == nil)
    #expect(plan.nextCheckpoint == nil)
  }

  @Test("A far-future reset keeps a fresh weekly balance but withholds the plan")
  func farFutureResetKeepsWeeklyBalance() {
    let snapshot = ProviderSnapshot(
      provider: .claude,
      source: .fixture,
      capturedAt: self.now,
      weekly: QuotaWindow(
        remainingPercent: 73,
        durationSeconds: self.week,
        resetAt: self.now.addingTimeInterval(self.week + 1)
      )
    )

    let plan = QuotaPlanner.evaluate(snapshot, now: self.now)
    #expect(plan.status == .resetUnknown)
    #expect(plan.weeklyRemaining == 73)
    #expect(plan.targetNow == nil)
    #expect(plan.vsTarget == nil)
    #expect(plan.weeklyResetAt == nil)
    #expect(plan.nextCheckpoint == nil)
  }

  @Test("English and Japanese copy preserve comparison-only semantics")
  func localizedCopy() {
    #expect(MenuCopy(languageCode: "en").text("comparison.note").contains("does not recommend"))
    #expect(MenuCopy(languageCode: "ja").text("comparison.note").contains("推薦しません"))
    #expect(MenuCopy(languageCode: "ja").text("weekly.left") == "週間残量")
    #expect(MenuCopy(languageCode: "en").text("captured.at") == "Captured")
    #expect(MenuCopy(languageCode: "ja").text("captured.at") == "取得時刻")
    #expect(MenuCopy(languageCode: "en").text("weekly.reset") == "Weekly reset")
    #expect(MenuCopy(languageCode: "ja").text("weekly.reset") == "週間リセット")
    #expect(
      MenuCopy(languageCode: "en").text("weekly.reset.estimated")
        == "Weekly reset (estimated)")
    #expect(MenuCopy(languageCode: "en").source(.claudeDesktopHistory) == "Claude Desktop history")
    #expect(MenuCopy(languageCode: "ja").source(.claudeLocalCache) == "Claudeローカルキャッシュ")
    #expect(MenuCopy(languageCode: "en").source(.claudeLocalMerged) == "Claude local sources")
    #expect(MenuCopy(languageCode: "en").text("refresh") == "Refresh")
    #expect(MenuCopy(languageCode: "en").text("check.for.updates") == "Check for Updates...")
    #expect(MenuCopy(languageCode: "ja").text("check.for.updates") == "アップデートを確認...")
    #expect(MenuCopy(languageCode: "en").status(.resetUnknown) == "Reset time unavailable")
    #expect(MenuCopy(languageCode: "ja").status(.resetUnknown) == "リセット時刻未取得")
    #expect(MenuCopy(languageCode: "en").text("claude.reset.help").contains("Claude Code"))
    #expect(MenuCopy(languageCode: "ja").text("claude.reset.help").contains("リセット時刻"))
    #expect(MenuCopy(languageCode: "en").status(.resetElapsed) == "Waiting for new quota window")
    #expect(MenuCopy(languageCode: "ja").status(.resetElapsed) == "新しい利用枠を待機中")
    #expect(MenuCopy(languageCode: "en").text("quit") == "Quit QuotaTempo")
    #expect(MenuCopy(languageCode: "ja").text("quit") == "QuotaTempoを終了")
    #expect(MenuCopy(languageCode: "en").text("providers") == "Providers")
    #expect(MenuCopy(languageCode: "ja").text("providers") == "表示するprovider")
    #expect(MenuCopy(languageCode: "en").text("launch.at.login") == "Launch at login")
    #expect(
      MenuCopy(languageCode: "en").text("login.item.requires.approval")
        .contains("not active yet")
    )
    #expect(
      MenuCopy(languageCode: "ja").text("login.item.requires.approval")
        .contains("まだ有効ではありません")
    )
    #expect(MenuCopy(languageCode: "ja").text("copy.diagnostics") == "診断情報をコピー")
    #expect(MenuCopy(languageCode: "en").codexExecutableSource(.desktopBundled).contains("app"))
    #expect(MenuCopy(languageCode: "ja").codexExecutableSource(.packageManager).contains("パッケージ"))
    for error in [
      AcquisitionErrorCode.sourceNotInstalled,
      .launchFailed,
      .versionTooOld,
      .protocolIncompatible,
      .timeout,
      .temporaryFailure,
    ] {
      #expect(MenuCopy(languageCode: "en").error(error) != "error.\(error.rawValue)")
      #expect(MenuCopy(languageCode: "ja").error(error) != "error.\(error.rawValue)")
    }
    #expect(MenuCopy(languageCode: "en").text("third.party.notices") == "Third-party notices")
    #expect(MenuCopy(languageCode: "en").text("got.it") == "Got It")
  }

  @Test("Menu bar full and compact modes format both providers deterministically")
  func menuBarModes() throws {
    let scenario = try FixtureLoader.load("baseline")
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .full)
        == "Cx W34/P48 ↓14 · Cl W60/P48 ↑12")
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .compact)
        == "Cx 34↓14 · Cl 60↑12")
    #expect(MenuBarTitleFormatter.title(scenario: scenario, mode: .iconOnly) == nil)
    #expect(
      MenuBarTitleFormatter.parts(scenario: scenario, mode: .full)
        == [
          MenuBarProviderPart(provider: .codex, value: "W34/P48 ↓14"),
          MenuBarProviderPart(provider: .claude, value: "W60/P48 ↑12"),
        ])
    #expect(MenuBarTitleFormatter.parts(scenario: scenario, mode: .iconOnly).isEmpty)
  }

  @Test("Provider menu icons load as template images")
  func providerMenuIcons() throws {
    let codex = try #require(ProviderIconAsset.image(for: .codex))
    let claude = try #require(ProviderIconAsset.image(for: .claude))
    #expect(codex.isTemplate)
    #expect(claude.isTemplate)
    #expect(codex.size == NSSize(width: 15, height: 15))
    #expect(claude.size == NSSize(width: 15, height: 15))
  }

  @Test("Menu bar provider label is one intrinsic image containing both segments")
  func providerMenuBarCompositeImage() throws {
    let scenario = try FixtureLoader.load("baseline")
    let full = try #require(
      ProviderMenuBarImageRenderer.image(scenario: scenario, mode: .full)
    )
    let compact = try #require(
      ProviderMenuBarImageRenderer.image(scenario: scenario, mode: .compact)
    )

    #expect(full.isTemplate)
    #expect(compact.isTemplate)
    #expect(full.size.height == ProviderMenuBarImageRenderer.canvasHeight)
    #expect(compact.size.height == ProviderMenuBarImageRenderer.canvasHeight)
    #expect(full.size.width > compact.size.width)
    #expect(compact.size.width > ProviderMenuBarImageRenderer.iconSize * 2)
    #expect(ProviderMenuBarImageRenderer.image(scenario: scenario, mode: .iconOnly) == nil)
  }

  @Test("Single-provider menu bar image does not reserve a separator")
  func singleProviderMenuBarWidth() throws {
    let scenario = ProviderSelection(enabled: [.codex]).filtering(
      try FixtureLoader.load("baseline")
    )
    let image = try #require(
      ProviderMenuBarImageRenderer.image(scenario: scenario, mode: .full)
    )
    let font = NSFont.menuBarFont(ofSize: 0)
    let textWidth = ("W34/P48 ↓14" as NSString).size(withAttributes: [.font: font]).width
    let expectedWidth = ceil(ProviderMenuBarImageRenderer.iconSize + 4 + ceil(textWidth))

    #expect(image.size.width == expectedWidth)
  }

  @Test("Menu bar formatter separates stale planning from unavailable comparisons")
  func menuBarDegradedStates() throws {
    let missingResetURL = try #require(
      Bundle.module.url(forResource: "malformed-missing-reset", withExtension: "json")
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let missingReset = try decoder.decode(
      FixtureScenario.self,
      from: Data(contentsOf: missingResetURL)
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: missingReset, mode: .full)
        == "Cx W62/P— —")

    let unavailable = try FixtureLoader.load("all-unavailable")
    #expect(
      MenuBarTitleFormatter.title(scenario: unavailable, mode: .compact)
        == "Cx — · Cl —")

    let stale = FixtureScenario(
      id: "stale-menu",
      now: self.now,
      snapshots: [
        self.snapshot(
          remaining: 62,
          resetAt: self.now.addingTimeInterval(self.week / 2),
          capturedAt: self.now.addingTimeInterval(-3_600)
        )
      ]
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: stale, mode: .full)
        == "Cx W62?/P50 —")
    #expect(
      MenuBarTitleFormatter.title(scenario: stale, mode: .compact)
        == "Cx 62? —")
  }

  @Test("Stale estimated reset retains only an explicitly estimated planning target")
  func staleEstimatedTarget() {
    let scenario = FixtureScenario(
      id: "stale-estimated-target",
      now: self.now,
      snapshots: [
        ProviderSnapshot(
          provider: .claude,
          source: .claudeLocalMerged,
          capturedAt: self.now.addingTimeInterval(-3_600),
          weekly: QuotaWindow(
            remainingPercent: 75,
            durationSeconds: self.week,
            resetAt: self.now.addingTimeInterval(self.week / 2),
            resetAtIsEstimated: true
          )
        )
      ]
    )
    let plan = QuotaPlanner.evaluate(scenario.snapshots[0], now: self.now)

    #expect(plan.status == .stale)
    #expect(plan.targetIsEstimated)
    #expect(plan.vsTarget == nil)
    #expect(plan.availableUntilCheckpoint == nil)
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .full)
        == "Cl W75?/P≈50 —")
  }

  @Test("Stale comparison help distinguishes confirmed and estimated reset bases")
  func staleComparisonHelp() {
    #expect(
      MenuCopy(languageCode: "en").text("stale.comparison.confirmed.help")
        == "W? is the last observed balance. P is calculated from the last confirmed reset. Difference and available capacity are waiting for a current balance."
    )
    #expect(
      MenuCopy(languageCode: "ja").text("stale.comparison.confirmed.help")
        == "W?は最後に確認した残量です。Pは最後に確認したリセットから計算しています。目標差と利用可能量は最新の残量待ちです。"
    )
    #expect(
      MenuCopy(languageCode: "en").text("stale.comparison.estimated.help")
        == "W? is the last observed balance. P≈ is calculated from a one-window reset estimate. Difference and available capacity are waiting for a current balance."
    )
    #expect(
      MenuCopy(languageCode: "ja").text("stale.comparison.estimated.help")
        == "W?は最後に確認した残量です。P≈はリセットを1期間だけ進めた推定から計算しています。目標差と利用可能量は最新の残量待ちです。"
    )
  }

  @Test("Estimated Claude reset is visible in full, compact, detail, and accessibility output")
  func estimatedClaudeResetPresentation() {
    let scenario = FixtureScenario(
      id: "estimated-claude-reset",
      now: self.now,
      snapshots: [
        ProviderSnapshot(
          provider: .claude,
          source: .claudeDesktopHistory,
          capturedAt: self.now,
          weekly: QuotaWindow(
            remainingPercent: 75,
            durationSeconds: self.week,
            resetAt: self.now.addingTimeInterval(self.week / 2),
            resetAtIsEstimated: true
          )
        )
      ]
    )
    let plan = QuotaPlanner.evaluate(scenario.snapshots[0], now: self.now)

    #expect(plan.targetIsEstimated)
    #expect(plan.weeklyResetAt == self.now.addingTimeInterval(self.week / 2))
    #expect(plan.weeklyResetIsEstimated)
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .full)
        == "Cl W75/P≈50 ↑25")
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .compact)
        == "Cl 75↑25 P≈")
    #expect(
      MenuCopy(languageCode: "en").text("target.basis.estimated")
        == "Estimated from the last confirmed weekly reset")
    #expect(MenuCopy(languageCode: "ja").text("target.basis.estimated").contains("推定"))
  }

  @Test("Menu bar render identity changes when a reset makes the plan available")
  func menuBarRenderIdentityTracksPlanAvailability() {
    let withoutReset = FixtureScenario(
      id: "menu-render-identity",
      now: self.now,
      snapshots: [
        ProviderSnapshot(
          provider: .claude,
          source: .fixture,
          capturedAt: self.now,
          weekly: QuotaWindow(
            remainingPercent: 85,
            durationSeconds: self.week,
            resetAt: nil
          )
        )
      ]
    )
    let withReset = FixtureScenario(
      id: withoutReset.id,
      now: self.now,
      snapshots: [
        ProviderSnapshot(
          provider: .claude,
          source: .fixture,
          capturedAt: self.now,
          weekly: QuotaWindow(
            remainingPercent: 85,
            durationSeconds: self.week,
            resetAt: self.now.addingTimeInterval(self.week / 2)
          )
        )
      ]
    )

    #expect(
      MenuBarTitleFormatter.renderIdentity(scenario: withoutReset, mode: .full)
        != MenuBarTitleFormatter.renderIdentity(scenario: withReset, mode: .full)
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: withoutReset, mode: .full)
        == "Cl W85/P— —"
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: withReset, mode: .full)
        == "Cl W85/P50 ↑35"
    )
  }

  @Test("Menu bar formatter rounds zero and one-hundred boundaries")
  func menuBarBoundaryValues() {
    let reset = self.now.addingTimeInterval(self.week / 2)
    let scenario = FixtureScenario(
      id: "menu-boundaries",
      now: self.now,
      snapshots: [
        ProviderSnapshot(
          provider: .codex,
          source: .fixture,
          capturedAt: self.now,
          weekly: QuotaWindow(remainingPercent: 0, durationSeconds: self.week, resetAt: reset)
        ),
        ProviderSnapshot(
          provider: .claude,
          source: .fixture,
          capturedAt: self.now,
          weekly: QuotaWindow(remainingPercent: 100, durationSeconds: self.week, resetAt: reset)
        ),
      ]
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .full)
        == "Cx W0/P50 ↓50 · Cl W100/P50 ↑50")
  }

  @Test("Menu bar formatter uses a neutral marker on target")
  func menuBarNeutralTarget() {
    let reset = self.now.addingTimeInterval(self.week / 2)
    let scenario = FixtureScenario(
      id: "neutral-target",
      now: self.now,
      snapshots: [self.snapshot(remaining: 50, resetAt: reset)]
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .compact)
        == "Cx 50=0")
  }

  @Test("Menu bar difference matches the displayed rounded values")
  func menuBarRoundedDifferenceConsistency() {
    let reset = self.now.addingTimeInterval(self.week * 0.475)
    let scenario = FixtureScenario(
      id: "rounded-difference",
      now: self.now,
      snapshots: [self.snapshot(remaining: 34.4, resetAt: reset)]
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .full)
        == "Cx W34/P48 ↓14")
    let plan = QuotaPlanner.evaluate(scenario.snapshots[0], now: scenario.now)
    #expect(
      QuotaPlanner.displayedDifference(
        weeklyRemaining: plan.weeklyRemaining,
        targetNow: plan.targetNow
      ) == -14)
  }

  @Test("Menu bar formatter handles duplicate provider snapshots deterministically")
  func menuBarDuplicateProvider() {
    let reset = self.now.addingTimeInterval(self.week / 2)
    let scenario = FixtureScenario(
      id: "duplicate-provider",
      now: self.now,
      snapshots: [
        self.snapshot(remaining: 40, resetAt: reset),
        self.snapshot(remaining: 90, resetAt: reset),
      ]
    )
    #expect(
      MenuBarTitleFormatter.title(scenario: scenario, mode: .compact)
        == "Cx 40↓10")
    #expect(QuotaPlanner.evaluateUnique(scenario.snapshots, now: scenario.now).count == 1)
  }

  @Test("Provider selection filters presentation without deleting observations")
  func providerSelectionFiltersScenario() throws {
    let scenario = try FixtureLoader.load("baseline")
    let codexOnly = ProviderSelection(enabled: [.codex]).filtering(scenario)
    let claudeOnly = ProviderSelection(enabled: [.claude]).filtering(scenario)

    #expect(codexOnly.snapshots.map(\.provider) == [.codex])
    #expect(claudeOnly.snapshots.map(\.provider) == [.claude])
    #expect(scenario.snapshots.count == 2)
    #expect(
      MenuBarTitleFormatter.title(scenario: codexOnly, mode: .full)
        == "Cx W34/P48 ↓14")
    #expect(
      MenuBarTitleFormatter.title(scenario: claudeOnly, mode: .full)
        == "Cl W60/P48 ↑12")
  }

  @Test("Provider selection always retains at least one provider")
  func providerSelectionRetainsOneProvider() {
    let both = ProviderSelection.all
    let codexOnly = both.setting(.claude, enabled: false)

    #expect(codexOnly.enabled == [.codex])
    #expect(codexOnly.setting(.codex, enabled: false) == codexOnly)
    #expect(codexOnly.setting(.claude, enabled: true) == both)
    #expect(ProviderSelection(enabled: []).enabled == both.enabled)
  }

  @Test("Initial provider detection completes after both providers are accounted for")
  func initialProviderDetectionTracksSkippedAndCompletedAttempts() {
    var tracker = InitialProviderDetectionTracker()

    let afterCodex = tracker.record(.codex)
    let afterClaude = tracker.record(.claude)
    let afterRepeatedClaude = tracker.record(.claude)
    #expect(!afterCodex)
    #expect(afterClaude)
    #expect(afterRepeatedClaude)
  }

  @Test("A login item awaiting approval remains an enabled user request")
  func loginItemRequestState() {
    #expect(!LoginItemState.disabled.isRequested)
    #expect(LoginItemState.enabled.isRequested)
    #expect(LoginItemState.requiresApproval.isRequested)
    #expect(!LoginItemState.requiresMoveToApplications.isRequested)
    #expect(!LoginItemState.unavailable.isRequested)
    #expect(LoginItemState.from(.notRegistered) == .disabled)
    #expect(LoginItemState.from(.notFound) == .disabled)
    #expect(LoginItemState.from(.enabled) == .enabled)
    #expect(LoginItemState.from(.requiresApproval) == .requiresApproval)
    #expect(LoginItemState.canRegister(.notRegistered))
    #expect(LoginItemState.canRegister(.notFound))
    #expect(!LoginItemState.canRegister(.enabled))
    #expect(!LoginItemState.canRegister(.requiresApproval))
  }

  @Test("Login launch is available only from a stable Applications folder")
  func loginItemInstallLocationBoundary() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    #expect(
      LoginItemInstallLocation.isSupported(
        bundleURL: URL(fileURLWithPath: "/Applications/QuotaTempo.app"),
        homeDirectory: home
      ))
    #expect(
      LoginItemInstallLocation.isSupported(
        bundleURL: URL(fileURLWithPath: "/Users/example/Applications/QuotaTempo.app"),
        homeDirectory: home
      ))
    #expect(
      !LoginItemInstallLocation.isSupported(
        bundleURL: URL(fileURLWithPath: "/Users/example/Downloads/QuotaTempo.app"),
        homeDirectory: home
      ))
    #expect(
      !LoginItemInstallLocation.isSupported(
        bundleURL: URL(fileURLWithPath: "/private/tmp/QuotaTempo.app"),
        homeDirectory: home
      ))
    #expect(
      !LoginItemInstallLocation.isSupported(
        bundleURL: URL(
          fileURLWithPath:
            "/private/var/folders/xx/AppTranslocation/random/d/QuotaTempo.app"
        ),
        homeDirectory: home
      ))
  }

  @Test("First-run detection selects only providers with observations")
  func providerSelectionDetection() {
    let empty = [
      ProviderSnapshot(
        provider: .codex,
        source: .codexAppServer,
        capturedAt: nil,
        weekly: nil,
        sourceState: .neverObserved
      )
    ]
    #expect(ProviderSelection.detected(in: empty) == nil)

    let observed =
      empty + [
        ProviderSnapshot(
          provider: .claude,
          source: .claudeDesktopHistory,
          capturedAt: self.now,
          weekly: nil,
          fiveHour: QuotaWindow(
            remainingPercent: 20,
            durationSeconds: 18_000,
            resetAt: self.now.addingTimeInterval(3_600)
          )
        )
      ]
    #expect(ProviderSelection.detected(in: observed)?.enabled == [.claude])
  }

  @Test("Provider selection preferences persist an explicit single-provider choice")
  @MainActor
  func providerSelectionPreferencesPersist() throws {
    let suiteName = "QuotaTempoTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = ProviderSelectionPreferences(defaults: defaults)

    #expect(preferences.load() == nil)
    preferences.save(ProviderSelection(enabled: [.claude]))
    #expect(preferences.load()?.enabled == [.claude])
  }

  @Test("Safe diagnostics includes support metadata but excludes quota values and dates")
  func safeDiagnosticsExcludesQuotaData() throws {
    let scenario = try FixtureLoader.load("baseline")
    let report = SafeDiagnostics.report(
      scenario: scenario,
      productVersion: "0.1.0-rc.5",
      operatingSystem: "macOS test"
    )

    #expect(report.contains("Version: 0.1.0-rc.5"))
    #expect(report.contains("Enabled providers: Codex, Claude"))
    #expect(report.contains("Source: fixture"))
    #expect(report.contains("Freshness: live"))
    #expect(!report.contains("34%"))
    #expect(!report.contains("60%"))
    #expect(!report.contains("2026-"))
    #expect(!report.contains("/Users/"))
    #expect(!report.contains("https://"))
  }

  @Test("Safe diagnostics includes normalized Codex provenance without a path")
  func safeDiagnosticsIncludesCodexProvenance() {
    let scenario = FixtureScenario(
      id: "codex-provenance",
      now: self.now,
      snapshots: [
        ProviderSnapshot(
          provider: .codex,
          source: .codexAppServer,
          capturedAt: nil,
          weekly: nil,
          lastAttemptAt: self.now,
          sourceState: .attemptFailed,
          errorCode: .versionTooOld,
          codexExecutableSource: .packageManager,
          codexExecutableVersion: "0.133.0"
        )
      ]
    )
    let report = SafeDiagnostics.report(
      scenario: scenario,
      productVersion: "test",
      operatingSystem: "macOS test"
    )

    #expect(report.contains("Codex executable source: packageManager"))
    #expect(report.contains("Codex executable version: 0.133.0"))
    #expect(report.contains("Refresh error: versionTooOld"))
    #expect(!report.contains("/opt/"))
    #expect(!report.contains("/Applications/"))
  }

  @Test("Safe diagnostics follows the selected provider set")
  func safeDiagnosticsFollowsSelection() throws {
    let scenario = ProviderSelection(enabled: [.codex]).filtering(
      try FixtureLoader.load("baseline")
    )
    let report = SafeDiagnostics.report(
      scenario: scenario,
      productVersion: "test",
      operatingSystem: "macOS test"
    )

    #expect(report.contains("Enabled providers: Codex"))
    #expect(report.contains("[Codex]"))
    #expect(!report.contains("[Claude]"))
  }

  private func plan(
    remaining: Double,
    resetAt: Date,
    duration: TimeInterval? = nil,
    capturedAt: Date? = nil
  ) -> PlannedProvider {
    QuotaPlanner.evaluate(
      self.snapshot(
        remaining: remaining,
        resetAt: resetAt,
        duration: duration,
        capturedAt: capturedAt
      ),
      now: self.now
    )
  }

  private func snapshot(
    remaining: Double,
    resetAt: Date,
    duration: TimeInterval? = nil,
    capturedAt: Date? = nil
  ) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: .codex,
      source: .fixture,
      capturedAt: capturedAt ?? self.now,
      weekly: QuotaWindow(
        remainingPercent: remaining,
        durationSeconds: duration ?? self.week,
        resetAt: resetAt
      )
    )
  }
}
