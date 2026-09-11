import Foundation

public struct MenuCopy: Sendable {
  private let bundle: Bundle?

  public init(languageCode: String) {
    let normalized = languageCode.lowercased().hasPrefix("ja") ? "ja" : "en"
    self.bundle = QuotaTempoResourceLocator.localizedBundle(languageCode: normalized)
  }

  public func text(_ key: String) -> String {
    self.bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
  }

  public func status(_ status: TargetStatus) -> String {
    switch status {
    case .aboveTarget: self.text("status.above")
    case .onTarget: self.text("status.on")
    case .belowTarget: self.text("status.below")
    case .resetUnknown: self.text("status.resetUnknown")
    case .resetElapsed: self.text("status.resetElapsed")
    case .stale: self.text("status.stale")
    case .unavailable: self.text("status.unavailable")
    }
  }

  public func freshness(_ freshness: Freshness) -> String {
    self.text("freshness.\(freshness.rawValue)")
  }

  public func sourceState(_ state: SourceState) -> String {
    self.text("source.state.\(state.rawValue)")
  }

  public func source(_ source: SnapshotSource) -> String {
    self.text("source.\(source.rawValue)")
  }

  public func error(_ error: AcquisitionErrorCode) -> String {
    self.text("error.\(error.rawValue)")
  }

  public func codexExecutableSource(_ source: CodexExecutableSource) -> String {
    self.text("codex.executable.source.\(source.rawValue)")
  }
}
