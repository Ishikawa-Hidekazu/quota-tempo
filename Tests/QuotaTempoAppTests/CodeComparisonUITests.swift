import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuotaTempoApp

@Suite("Code comparison offscreen UI", .serialized)
@MainActor
struct CodeComparisonUITests {
  @Test("Nonblank raster coverage is scale independent and rejects empty images")
  func rasterCoverage() {
    #expect(hasVisibleContent(ink: 287, samples: 10_000))
    #expect(hasVisibleContent(ink: 1_148, samples: 40_000))
    #expect(!hasVisibleContent(ink: 0, samples: 10_000))
    #expect(!hasVisibleContent(ink: 1, samples: 10_000))
    #expect(!hasVisibleContent(ink: 0, samples: 0))
  }

  @Test(
    "Connection arguments are shown only while waiting for a fresh connection",
    arguments: [
      CodeUsageComparisonStatus.disconnected, .preparing, .waitingForConnection,
      .waitingForMeasurement, .comparisonOnly, .stale, .resetPassed, .multipleSessions,
      .unavailable, .invalidClock, .storageUnavailable,
    ])
  func connectionArguments(_ status: CodeUsageComparisonStatus) {
    #expect(
      CodeUsageComparisonControls.showsConnectionArguments(status)
        == (status == .waitingForConnection))
  }

  @Test(
    "Expanded controls fit the menu width without opening a window", arguments: ["en", "ja"],
    [
      CodeUsageComparisonStatus.comparisonOnly, .waitingForConnection, .waitingForMeasurement,
      .stale,
    ])
  func render(_ language: String, _ status: CodeUsageComparisonStatus) async throws {
    try await validate(language, status, package: nil)
  }

  @Test(
    "Staged plugin onboarding fits with a long private path", arguments: ["en", "ja"],
    [false, true])
  func onboarding(_ language: String, _ expandedManagement: Bool) async throws {
    let digest = String(repeating: "a", count: 64)
    let package = CodeComparisonPluginCommands(
      directory: URL(
        fileURLWithPath:
          "/Users/synthetic/Library/Application Support/QuotaTempoCodeComparisonPreview/PluginPackages/0.0.4-\(digest)"
      ),
      pluginID: "quotatempo-usage-probe@quotatempo-code-11111111-1111-4111-8111-111111111111",
      version: "0.0.4", digest: digest)
    try await validate(
      language, .waitingForConnection, package: package, expandedManagement: expandedManagement)
  }

  private func validate(
    _ language: String, _ status: CodeUsageComparisonStatus,
    package: CodeComparisonPluginCommands?, expandedManagement: Bool = false
  ) async throws {
    let controller = CodeUsageComparisonController(service: RenderComparisonService(status: status))
    await controller.prepare()
    await controller.refresh()
    #expect(controller.command?.hasSuffix(" " + String(repeating: "a", count: 64)) == true)
    let controls = CodeUsageComparisonControls(
      connection: controller, enabled: true, initiallyExpanded: true,
      initiallyPreparedPackage: package, initiallyExpandedManagement: expandedManagement
    )
    .environment(\.locale, Locale(identifier: language))
    .environment(\.colorScheme, .light)
    .padding(16)
    .frame(width: 580, alignment: .leading)
    .background(Color.white)
    let hosting = NSHostingView(rootView: controls)
    let maximumHeight: CGFloat = package == nil ? 700 : 1_200
    hosting.setFrameSize(NSSize(width: 580, height: maximumHeight))
    hosting.layoutSubtreeIfNeeded()
    for _ in 0..<5 { await Task.yield() }
    let fitting = hosting.fittingSize
    #expect(fitting.width <= 580 && fitting.height > 120 && fitting.height < maximumHeight)
    hosting.setFrameSize(NSSize(width: 580, height: fitting.height.rounded(.up)))
    hosting.layoutSubtreeIfNeeded()
    let renderer = ImageRenderer(content: controls)
    let rendered = try #require(renderer.nsImage)
    let tiff = try #require(rendered.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 2_000)
    var ink = 0
    var samples = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
        samples += 1
        if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          pixel.alphaComponent > 0.5 && pixel.redComponent < 0.8
        {
          ink += 1
        }
      }
    }
    #expect(hasVisibleContent(ink: ink, samples: samples))
    if let output = ProcessInfo.processInfo.environment["QUOTATEMPO_CODE_RENDER_DIR"] {
      let path = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
      try png.write(
        to: path.appendingPathComponent(
          "code-comparison-\(language)-\(status.rawValue)\(package == nil ? "" : "-onboarding")\(expandedManagement ? "-setup-open" : "").png"
        ))
    }
    await controller.disconnect()
  }

  private func hasVisibleContent(ink: Int, samples: Int) -> Bool {
    samples > 0 && Double(ink) / Double(samples) > 0.01
  }
}

private actor RenderComparisonService: CodeComparisonServing {
  private let status: CodeUsageComparisonStatus
  init(status: CodeUsageComparisonStatus) { self.status = status }
  nonisolated func terminate() {}
  func prepare(now: Date) throws -> CodeComparisonSetup {
    CodeComparisonSetup(
      directory: URL(fileURLWithPath: "/private/tmp/quotatempo-synthetic-comparison"),
      connectionID: "11111111-1111-4111-8111-111111111111", grant: Data(), device: 0, inode: 0,
      publicKey: String(repeating: "a", count: 64))
  }
  func poll(connectionID: String, clock: @Sendable () -> Date) -> CodeUsageComparisonView {
    guard status == .comparisonOnly else { return CodeUsageComparisonView(status: status) }
    let now = Date(timeIntervalSince1970: 1_791_244_800)
    return CodeUsageComparisonView(
      status: .comparisonOnly,
      weekly: CodeUsageComparisonWindow(
        remainingPercent: 58, resetAt: now.addingTimeInterval(86_400)),
      fiveHour: CodeUsageComparisonWindow(
        remainingPercent: 65, resetAt: now.addingTimeInterval(3_600)),
      receivedAt: now)
  }
  func revoke(connectionID: String) -> Bool { true }
}
