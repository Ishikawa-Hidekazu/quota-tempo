import Darwin
import Foundation
import Testing

@testable import QuotaTempoApp

@Suite("Code package headless resource validation")
struct CodeComparisonPackageValidationTests {
  @Test("Reserved prefix never falls through to the application")
  func reserved() {
    for value in ["--code-comparison-package-validation", "--code-comparison-package-validation=x"]
    {
      #expect(QuotaTempoEntryPoint.requestsCodePackageValidation([value]))
    }
    #expect(!QuotaTempoEntryPoint.requestsCodePackageValidation(["--provider-disabled"]))
  }

  @Test("Invalid arguments are inert and cannot choose a production directory")
  func invalid() {
    for arguments in [
      [], [CodeComparisonPackageValidation.flag],
      [CodeComparisonPackageValidation.flag, "--private-test-directory", "/Users/synthetic"],
      [CodeComparisonPackageValidation.flag, "--private-test-directory", "/private/tmp"],
      [CodeComparisonPackageValidation.flag, "--private-test-directory", "/private/tmp/../tmp"],
    ] {
      var called = false
      let result = CodeComparisonPackageValidation.run(arguments) { _ in
        called = true
        throw CodeComparisonPluginPackageError.invalidPackage
      }
      #expect(!result.passed && result.exitCode == 2 && !called)
    }
  }

  @Test("A fresh private root stages only package metadata and never proves live Code")
  func success() throws {
    let root = freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = CodeComparisonPackageValidation.run(arguments(root)) { storage in
      #expect(storage.path == root.appendingPathComponent("packages").path)
      return commands(storage)
    }
    #expect(result.passed && result.exitCode == 0)
    #expect(result.json.contains("\"liveCodeAccepted\":false"))
    #expect(!result.json.contains(root.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect(attributes[.posixPermissions] as? Int == 0o700)
  }

  @Test("Existing roots are preserved without reading or staging")
  func existing() throws {
    let root = freshRoot()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("unrelated.txt")
    try Data("synthetic".utf8).write(to: marker)
    var called = false
    let result = CodeComparisonPackageValidation.run(arguments(root)) { storage in
      called = true
      return commands(storage)
    }
    #expect(!result.passed && !called)
    #expect(try Data(contentsOf: marker) == Data("synthetic".utf8))
  }

  @Test("Signature or staging failure has fixed output and retains no false acceptance")
  func failed() {
    let root = freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = CodeComparisonPackageValidation.run(arguments(root)) { _ in
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    #expect(!result.passed && result.exitCode == 2)
    #expect(result.json == "{\"status\":\"packageValidationFailed\",\"passed\":false}")
  }

  private func freshRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp/qtc-package-validation-\(UUID().uuidString.lowercased())")
  }

  private func arguments(_ root: URL) -> [String] {
    [CodeComparisonPackageValidation.flag, "--private-test-directory", root.path]
  }

  private func commands(_ storage: URL) -> CodeComparisonPluginCommands {
    CodeComparisonPluginCommands(
      directory: storage.appendingPathComponent("0.0.4-synthetic"),
      pluginID: "quotatempo-usage-probe@quotatempo-code-11111111-1111-4111-8111-111111111111",
      version: "0.0.4", digest: String(repeating: "a", count: 64))
  }
}
