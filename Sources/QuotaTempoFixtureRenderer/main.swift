import AppKit
import QuotaTempoCore
import SwiftUI

struct RenderArguments {
  let fixture: String
  let language: String
  let output: String
  let onboarding: Bool

  init(_ arguments: [String]) throws {
    var fixture = "baseline"
    var language = "en"
    var output: String?
    var onboarding = false
    var index = 1

    while index < arguments.count {
      switch arguments[index] {
      case "--fixture":
        index += 1
        guard index < arguments.count else { throw RenderError.missingValue("--fixture") }
        fixture = arguments[index]
      case "--language":
        index += 1
        guard index < arguments.count else { throw RenderError.missingValue("--language") }
        language = arguments[index]
      case "--output":
        index += 1
        guard index < arguments.count else { throw RenderError.missingValue("--output") }
        output = arguments[index]
      case "--view-mode":
        index += 1
        guard index < arguments.count else { throw RenderError.missingValue("--view-mode") }
        onboarding = arguments[index] == "onboarding"
      default:
        throw RenderError.unknownArgument(arguments[index])
      }
      index += 1
    }

    guard let output else { throw RenderError.missingValue("--output") }
    self.fixture = fixture
    self.language = language
    self.output = output
    self.onboarding = onboarding
  }
}

enum RenderError: Error {
  case missingValue(String)
  case unknownArgument(String)
  case bitmapUnavailable
  case encodingFailed
}

@MainActor
func render(_ arguments: RenderArguments) throws {
  let scenario = try FixtureLoader.load(arguments.fixture)
  let view = QuotaMenuView(
    scenario: scenario,
    languageCode: arguments.language,
    timeZone: TimeZone(secondsFromGMT: 0)!,
    onboardingPresented: .constant(arguments.onboarding),
    enabledProviders: Set(scenario.snapshots.map(\.provider)),
    onRefresh: {},
    onQuit: {}
  )
  .environment(\.colorScheme, .light)

  let host = NSHostingView(rootView: view)
  let size = host.fittingSize
  host.frame = NSRect(origin: .zero, size: size)
  host.layoutSubtreeIfNeeded()

  let scale = 2.0
  guard
    let representation = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(ceil(size.width * scale)),
      pixelsHigh: Int(ceil(size.height * scale)),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  else {
    throw RenderError.bitmapUnavailable
  }
  representation.size = size
  host.cacheDisplay(in: host.bounds, to: representation)
  guard let data = representation.representation(using: .png, properties: [:]) else {
    throw RenderError.encodingFailed
  }
  try data.write(to: URL(fileURLWithPath: arguments.output), options: .atomic)
}

do {
  let arguments = try RenderArguments(CommandLine.arguments)
  try MainActor.assumeIsolated {
    try render(arguments)
  }
} catch {
  FileHandle.standardError.write(Data("Render failed: \(error)\n".utf8))
  exit(2)
}
