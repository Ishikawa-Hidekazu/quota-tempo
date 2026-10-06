import Foundation
import Testing

@testable import QuotaTempoApp

@Suite("Code preview headless application initialization")
@MainActor
struct CodeComparisonStartupValidationTests {
  @Test("Reserved startup prefix cannot fall through to GUI startup")
  func reserved() {
    for flag in [CodeComparisonStartupValidation.flag, CodeComparisonStartupValidation.flag + "=x"]
    {
      #expect(QuotaTempoEntryPoint.requestsCodeStartupValidation([flag]))
    }
    #expect(!QuotaTempoEntryPoint.requestsCodeStartupValidation(["--provider-disabled"]))
  }

  @Test("Malformed or non-preview requests never initialize the application")
  func invalid() {
    for args in [
      [], [CodeComparisonStartupValidation.flag],
      [CodeComparisonStartupValidation.flag, "--private-test-directory", "/Users/synthetic"],
      [CodeComparisonStartupValidation.flag + "=x", "--private-test-directory", freshRoot().path],
    ] {
      var initialized = false
      let result = CodeComparisonStartupValidation.run(
        args, isCodePreview: { true }, initialize: { _ in initialized = true })
      #expect(!result.passed && !initialized)
    }
    var initialized = false
    let result = CodeComparisonStartupValidation.run(
      arguments(freshRoot()), isCodePreview: { false }, initialize: { _ in initialized = true })
    #expect(!result.passed && !initialized)
  }

  @Test("A fresh private root reaches composition without claiming GUI or live Code")
  func valid() throws {
    let root = freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var initialized = false
    let result = CodeComparisonStartupValidation.run(
      arguments(root), isCodePreview: { true },
      initialize: { received in
        #expect(received.path == root.path)
        initialized = true
      })
    #expect(result.passed && initialized && result.exitCode == 0)
    #expect(result.json.contains("\"guiStarted\":false"))
    #expect(result.json.contains("\"liveCodeAccepted\":false"))
    #expect(!result.json.contains(root.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect(attributes[.posixPermissions] as? Int == 0o700)
  }

  @Test("Existing directories remain untouched and cannot authorize startup")
  func existing() throws {
    let root = freshRoot()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var initialized = false
    let result = CodeComparisonStartupValidation.run(
      arguments(root), isCodePreview: { true }, initialize: { _ in initialized = true })
    #expect(!result.passed && !initialized)
  }

  @Test("Initialization failure has fixed failure output")
  func failure() {
    let root = freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = CodeComparisonStartupValidation.run(
      arguments(root), isCodePreview: { true },
      initialize: { _ in
        throw CocoaError(.fileReadUnknown)
      })
    #expect(!result.passed && result.exitCode == 2)
    #expect(result.json == "{\"status\":\"startupValidationFailed\",\"passed\":false}")
  }

  private func freshRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp/qtc-startup-validation-\(UUID().uuidString.lowercased())")
  }
  private func arguments(_ root: URL) -> [String] {
    [CodeComparisonStartupValidation.flag, "--private-test-directory", root.path]
  }
}
