import AppKit
import SwiftUI

public enum ProviderIconAsset {
  public static func image(for provider: ProviderID, pointSize: CGFloat = 15) -> NSImage? {
    let symbol = provider == .codex ? "terminal" : "sparkles"
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
      return nil
    }

    image.size = NSSize(width: pointSize, height: pointSize)
    image.isTemplate = true
    return image
  }
}

public struct ProviderIconView: View {
  private let provider: ProviderID
  private let size: CGFloat

  public init(provider: ProviderID, size: CGFloat = 15) {
    self.provider = provider
    self.size = size
  }

  public var body: some View {
    Group {
      if let image = ProviderIconAsset.image(for: self.provider, pointSize: self.size) {
        Image(nsImage: image)
      } else {
        Image(systemName: self.provider == .codex ? "terminal" : "sparkles")
          .font(.system(size: self.size))
      }
    }
    .frame(width: self.size, height: self.size)
    .accessibilityHidden(true)
  }
}

public struct ProviderMenuBarLabel: View {
  private let scenario: FixtureScenario
  private let mode: MenuBarDisplayMode
  private let accessibilityText: String

  public init(scenario: FixtureScenario, mode: MenuBarDisplayMode) {
    self.scenario = scenario
    self.mode = mode
    self.accessibilityText = MenuBarTitleFormatter.title(scenario: scenario, mode: mode) ?? ""
  }

  public var body: some View {
    Group {
      if let image = ProviderMenuBarImageRenderer.image(
        scenario: self.scenario,
        mode: self.mode
      ) {
        Image(nsImage: image)
      } else {
        Image(systemName: "metronome")
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("QuotaTempo \(self.accessibilityText)")
  }
}

public enum ProviderMenuBarImageRenderer {
  public static let iconSize: CGFloat = 15
  public static let canvasHeight: CGFloat = 18

  public static func image(
    scenario: FixtureScenario,
    mode: MenuBarDisplayMode
  ) -> NSImage? {
    let parts = MenuBarTitleFormatter.parts(scenario: scenario, mode: mode)
    guard !parts.isEmpty else { return nil }

    let font = NSFont.menuBarFont(ofSize: 0)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.black,
    ]
    let iconTextSpacing: CGFloat = 4
    let separator = "  ·  " as NSString
    let separatorSize = separator.size(withAttributes: attributes)
    let textSizes = parts.map { ($0.value as NSString).size(withAttributes: attributes) }
    let segmentWidths = textSizes.map { Self.iconSize + iconTextSpacing + ceil($0.width) }
    let separatorCount = max(parts.count - 1, 0)
    let width = ceil(
      segmentWidths.reduce(0, +) + separatorSize.width * CGFloat(separatorCount)
    )
    let size = NSSize(width: width, height: Self.canvasHeight)

    let image = NSImage(size: size, flipped: false) { rect in
      var x: CGFloat = 0
      for (index, part) in parts.enumerated() {
        if index > 0 {
          let point = NSPoint(
            x: x,
            y: floor((rect.height - separatorSize.height) / 2)
          )
          separator.draw(at: point, withAttributes: attributes)
          x += separatorSize.width
        }

        let icon =
          ProviderIconAsset.image(for: part.provider, pointSize: Self.iconSize)
          ?? Self.fallbackImage(for: part.provider)
        icon.draw(
          in: NSRect(
            x: x,
            y: floor((rect.height - Self.iconSize) / 2),
            width: Self.iconSize,
            height: Self.iconSize
          ),
          from: .zero,
          operation: .sourceOver,
          fraction: 1
        )
        x += Self.iconSize + iconTextSpacing

        let text = part.value as NSString
        let textSize = textSizes[index]
        text.draw(
          at: NSPoint(x: x, y: floor((rect.height - textSize.height) / 2)),
          withAttributes: attributes
        )
        x += ceil(textSize.width)
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func fallbackImage(for provider: ProviderID) -> NSImage {
    let image =
      NSImage(
        systemSymbolName: provider == .codex ? "terminal" : "sparkles",
        accessibilityDescription: nil
      ) ?? NSImage(size: NSSize(width: Self.iconSize, height: Self.iconSize))
    image.size = NSSize(width: Self.iconSize, height: Self.iconSize)
    image.isTemplate = true
    return image
  }
}
