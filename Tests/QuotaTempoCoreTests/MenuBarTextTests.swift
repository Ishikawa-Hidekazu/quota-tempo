import AppKit
import Testing

@testable import QuotaTempoCore

@Suite("Plain-text provider menu bar", .serialized)
@MainActor
struct MenuBarTextTests {
  @Test(
    "Native labels are complete text with no provider artwork or reserved icon space",
    arguments: [MenuBarDisplayMode.full, .compact],
    [
      Set(ProviderID.allCases), Set([ProviderID.codex]), Set([ProviderID.claude]),
    ]
  )
  func textOnlyImage(mode: MenuBarDisplayMode, providers: Set<ProviderID>) throws {
    let scenario = ProviderSelection(enabled: providers).filtering(
      try FixtureLoader.load("baseline"))
    let title = try #require(MenuBarTitleFormatter.title(scenario: scenario, mode: mode))
    for provider in ProviderID.allCases {
      #expect(title.contains(provider.displayName) == providers.contains(provider))
    }
    #expect(title.contains("·") == (providers.count == 2))

    let actual = try #require(ProviderMenuBarImageRenderer.image(scenario: scenario, mode: mode))
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.black,
    ]
    let text = title as NSString
    let textSize = text.size(withAttributes: attributes)
    #expect(actual.size.width == ceil(textSize.width))
    #expect(actual.size.height >= ceil(textSize.height))
    #expect(actual.isTemplate)

    let expected = NSImage(size: actual.size, flipped: false) { rect in
      text.draw(
        at: NSPoint(x: 0, y: floor((rect.height - textSize.height) / 2)),
        withAttributes: attributes)
      return true
    }
    let actualPixels = try self.pixels(actual)
    let expectedPixels = try self.pixels(expected)
    #expect(actualPixels == expectedPixels)

    if let directory = ProcessInfo.processInfo.environment["QUOTATEMPO_MENU_BAR_RENDER_DIR"] {
      let output = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let selection = providers.count == 2 ? "both" : try #require(providers.first).rawValue
      for dark in [false, true] {
        let preview = try self.preview(actual, dark: dark)
        let name = "\(mode.rawValue)-\(selection)-\(dark ? "dark" : "light").png"
        try preview.write(to: output.appendingPathComponent(name), options: .atomic)
      }
    }
  }

  private func pixels(_ image: NSImage) throws -> Data {
    let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    return try #require(
      NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
  }

  private func preview(_ image: NSImage, dark: Bool) throws -> Data {
    let tint = NSImage(size: image.size)
    tint.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    (dark ? NSColor.white : NSColor.black).setFill()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
    tint.unlockFocus()

    let size = NSSize(width: image.size.width + 24, height: 32)
    let preview = NSImage(size: size, flipped: false) { rect in
      (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
      rect.fill()
      tint.draw(
        at: NSPoint(x: 12, y: floor((rect.height - image.size.height) / 2)),
        from: .zero, operation: .sourceOver, fraction: 1)
      return true
    }
    return try self.pixels(preview)
  }
}
