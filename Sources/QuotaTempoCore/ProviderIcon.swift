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
  public static let canvasHeight: CGFloat = 18

  public static func image(
    scenario: FixtureScenario,
    mode: MenuBarDisplayMode
  ) -> NSImage? {
    guard let title = MenuBarTitleFormatter.title(scenario: scenario, mode: mode) else {
      return nil
    }

    let font = NSFont.menuBarFont(ofSize: 0)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.black,
    ]
    let text = title as NSString
    let textSize = text.size(withAttributes: attributes)
    let size = NSSize(width: ceil(textSize.width), height: Self.canvasHeight)

    let image = NSImage(size: size, flipped: false) { rect in
      text.draw(
        at: NSPoint(x: 0, y: floor((rect.height - textSize.height) / 2)),
        withAttributes: attributes
      )
      return true
    }
    image.isTemplate = true
    return image
  }

}
