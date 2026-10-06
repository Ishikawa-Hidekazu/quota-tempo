import CryptoKit
import Darwin
import Foundation
import Testing

@testable import QuotaTempoApp

@Suite("Code comparison bundled immutable package")
struct CodeComparisonPluginPackageTests {
  private let marketplace = "quotatempo-code-11111111-1111-4111-8111-111111111111"

  private func fixture() throws -> (URL, URL, URL) {
    // Foundation can rewrite /private/var back to the /var symlink on macOS.
    // Use POSIX canonicalization for the no-symlink package contract.
    guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw CodeComparisonPluginPackageError.ioFailure
    }
    defer { free(canonical) }
    let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
      .appendingPathComponent("Code Package QA \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let source = root.appendingPathComponent("bundle/CodeComparisonPlugin", isDirectory: true)
    for directory in [
      source, source.appendingPathComponent(".claude-plugin"),
      source.appendingPathComponent("hooks"),
    ] {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
    }
    for file in CodeComparisonPluginPackage.files {
      let bytes: Data
      if file == ".claude-plugin/plugin.json" {
        bytes = try JSONSerialization.data(withJSONObject: [
          "name": "quotatempo-usage-probe", "version": "0.0.4",
        ])
      } else if file == ".claude-plugin/marketplace.json" {
        bytes = try JSONSerialization.data(withJSONObject: [
          "name": marketplace, "metadata": ["version": "0.0.4"],
          "plugins": [["name": "quotatempo-usage-probe", "source": "./"]],
        ])
      } else {
        bytes = Data("synthetic resource; never executable\n".utf8)
      }
      let url = source.appendingPathComponent(file)
      try bytes.write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
    try manifest(source)
    return (root, source, root.appendingPathComponent("app-owned support/PluginPackages"))
  }

  private func manifest(_ source: URL, version: String = "0.0.4") throws {
    let hashes = try Dictionary(
      uniqueKeysWithValues: CodeComparisonPluginPackage.files.map { file in
        let bytes = try Data(contentsOf: source.appendingPathComponent(file))
        return (file, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      })
    let bytes = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1, "purpose": "quotatempo-code-comparison-plugin",
        "releaseVersion": version, "files": hashes,
      ], options: [.sortedKeys])
    try bytes.write(to: source.appendingPathComponent(CodeComparisonPluginPackage.manifestName))
  }

  @Test(
    "Eight resources plus manifest stage privately, reuse without writes, and expose only builtin plans"
  )
  func stageAndReuse() throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    let before = try FileManager.default.attributesOfItem(atPath: first.directory.path)
    let second = try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    let after = try FileManager.default.attributesOfItem(atPath: second.directory.path)
    #expect(first == second)
    #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
    #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    #expect(first.pluginID == "quotatempo-usage-probe@\(marketplace)")
    #expect(first.marketplaceAdd == "/plugin marketplace add \"\(first.directory.path)\"")
    #expect(first.install == "/plugin install \(first.pluginID)")
    #expect(first.disable == "/plugin disable")
    #expect(first.enable == "/plugin enable")
    #expect(first.uninstall == "/plugin uninstall")
    #expect(CodeComparisonPluginPackage.files.count == 8)
    for file in CodeComparisonPluginPackage.files + [CodeComparisonPluginPackage.manifestName] {
      let attrs = try FileManager.default.attributesOfItem(
        atPath: first.directory.appendingPathComponent(file).path)
      #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
      #expect(
        try Data(contentsOf: first.directory.appendingPathComponent(file))
          == Data(contentsOf: source.appendingPathComponent(file)))
    }
    for directory in [
      storage, first.directory, first.directory.appendingPathComponent("hooks"),
      first.directory.appendingPathComponent(".claude-plugin"),
    ] {
      let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
      #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
  }

  @Test("Tampered existing staging is not repaired, deleted or replaced")
  func noRepair() throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    let target = first.directory.appendingPathComponent("producer.mjs")
    let sentinel = Data("preserve changed resource".utf8)
    try sentinel.write(to: target)
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    }
    #expect(try Data(contentsOf: target) == sentinel)
  }

  @Test(
    "Compiled expected digest and namespace reject self-consistent unpinned packages before storage"
  )
  func rejectsUnpinnedPackage() throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.stage(
        source: source, storage: storage,
        expectedDigest: String(repeating: "0", count: 64))
    }
    let bytes = try Data(
      contentsOf: source.appendingPathComponent(CodeComparisonPluginPackage.manifestName))
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.stage(
        source: source, storage: storage,
        expectedDigest: digest,
        expectedMarketplace: "quotatempo-code-22222222-2222-4222-8222-222222222222")
    }
    #expect(!FileManager.default.fileExists(atPath: storage.path))
    _ = try CodeComparisonPluginPackage.stage(
      source: source, storage: storage,
      expectedDigest: digest, expectedMarketplace: marketplace)
  }

  @Test("Unknown stale stages remain untouched and do not poison the final package")
  func staleStage() throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let stale = storage.appendingPathComponent(".stage-unknown")
    try FileManager.default.createDirectory(
      at: stale, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let sentinel = stale.appendingPathComponent("keep.txt")
    try Data("preserve unknown partial stage".utf8).write(to: sentinel)
    let result = try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    #expect(!result.directory.lastPathComponent.hasPrefix(".stage-"))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve unknown partial stage")
  }

  @Test(
    "Inventory, versions, hashes, sizes and permission changes fail closed",
    arguments: [
      "extra", "nested-extra", "missing", "hash", "version", "oversize", "mode", "directory",
    ])
  func rejectsPackage(_ kind: String) throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = source.appendingPathComponent("producer.mjs")
    switch kind {
    case "extra": try Data("unexpected".utf8).write(to: source.appendingPathComponent("README.md"))
    case "nested-extra":
      try Data("unexpected".utf8).write(to: source.appendingPathComponent("hooks/extra.mjs"))
    case "missing": try FileManager.default.removeItem(at: target)
    case "hash": try Data("changed".utf8).write(to: target)
    case "version": try manifest(source, version: "0.0.3")
    case "oversize":
      try Data(repeating: 65, count: CodeComparisonPluginPackage.maximumFileBytes + 1).write(
        to: target)
    case "mode":
      try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: target.path)
    default:
      try FileManager.default.removeItem(at: target)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    }
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    }
    #expect(!FileManager.default.fileExists(atPath: storage.path))
  }

  @Test(
    "Symlinked source components, resources and storage are rejected",
    arguments: ["source", "source-parent", "resource", "hooks", "storage"])
  func symlinks(_ kind: String) throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var input = source
    var output = storage
    if kind == "resource" || kind == "hooks" {
      let target = source.appendingPathComponent(kind == "hooks" ? "hooks" : "producer.mjs")
      let moved = root.appendingPathComponent("original")
      try FileManager.default.moveItem(at: target, to: moved)
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
    } else if kind == "storage" {
      let alias = root.appendingPathComponent("support-alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
      output = alias.appendingPathComponent("PluginPackages")
    } else {
      let alias = root.appendingPathComponent("source-alias")
      let destination = kind == "source" ? source : source.deletingLastPathComponent()
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
      input = kind == "source" ? alias : alias.appendingPathComponent("CodeComparisonPlugin")
    }
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.stage(source: input, storage: output)
    }
  }

  @Test("Hardlinked source files and overlarge manifests fail before staging")
  func linksAndManifest() throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = source.appendingPathComponent("producer.mjs")
    let alias = root.appendingPathComponent("hardlink")
    #expect(Darwin.link(target.path, alias.path) == 0)
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    }
    try FileManager.default.removeItem(at: alias)
    try Data(repeating: 65, count: CodeComparisonPluginPackage.maximumManifestBytes + 1)
      .write(to: source.appendingPathComponent(CodeComparisonPluginPackage.manifestName))
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    }
  }

  @Test("Non-preview bundles cannot stage resources")
  func distributionRefusal() {
    #expect(throws: CodeComparisonPluginPackageError.notBundledPreview) {
      try CodeComparisonPluginPackage.stageBundled(bundle: .main)
    }
  }

  @Test("Bundle canonicalization retains POSIX private paths rather than Foundation aliases")
  func canonicalBundlePath() throws {
    #expect(
      try CodeComparisonPluginPackage.canonicalBundlePath(URL(fileURLWithPath: "/tmp"))
        .path == "/private/tmp")
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.canonicalBundlePath(URL(string: "https://example.invalid")!)
    }
    #expect(throws: (any Error).self) {
      try CodeComparisonPluginPackage.canonicalBundlePath(
        URL(fileURLWithPath: "/private/tmp/qtc-missing-\(UUID().uuidString)"))
    }
  }

  @Test("Writable package ancestors are rejected without changing their permissions")
  func writableAncestor() throws {
    let (root, source, storage) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
    #expect(throws: CodeComparisonPluginPackageError.unsafePath) {
      try CodeComparisonPluginPackage.stage(source: source, storage: storage)
    }
    let permissions = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o777)
    #expect(!FileManager.default.fileExists(atPath: storage.path))
  }

  @Test("Canonical resource paths are passed to staging, while outside resources are rejected")
  func canonicalResources() throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/Code Resource QA \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Preview.app", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(
      at: resources, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let alias = URL(
      fileURLWithPath: String(resources.path.dropFirst("/private".count)), isDirectory: true)
    #expect(
      try CodeComparisonPluginPackage.bundledSource(app: app, resources: alias)
        == resources.appendingPathComponent(
          CodeComparisonPluginPackage.resourceName, isDirectory: true))
    #expect(throws: CodeComparisonPluginPackageError.unsafePath) {
      try CodeComparisonPluginPackage.bundledSource(app: app, resources: root)
    }
  }
}
