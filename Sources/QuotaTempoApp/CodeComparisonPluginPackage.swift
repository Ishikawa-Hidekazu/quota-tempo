import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

enum CodeComparisonPluginPackageError: Error {
  case notBundledPreview, unsafePath, invalidPackage, ioFailure
}

struct CodeComparisonPluginCommands: Equatable, Sendable {
  let directory: URL
  let pluginID: String
  let version: String
  let digest: String

  // These are interactive Code commands, not shell commands or execution receipts.
  var marketplaceAdd: String { "/plugin marketplace add \"\(directory.path)\"" }
  var install: String { "/plugin install \(pluginID)" }
  var disable: String { "/plugin disable" }
  var enable: String { "/plugin enable" }
  var uninstall: String { "/plugin uninstall" }
}

enum CodeComparisonPluginPackage {
  static let version = "0.0.4"
  static let resourceName = "CodeComparisonPlugin"
  static let bundleID = "co.ishikawa.QuotaTempo.CodeComparisonPreview"
  static let channel = "code-comparison-preview"
  static let nativeMarketplaceName = "quotatempo-code-d276298d-6c66-477a-8c58-cf2b5d8e6104"
  // This digest pins the deterministic bundled payload to the compiled executable.
  static let nativeManifestDigest =
    "22024700344b34c645f47906425d90a375a46e14c1e3e17c90a729393215766c"
  static let files = [
    ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json",
    "hooks/register.mjs", "producer.mjs", "protocol.mjs", "transport-crypto.mjs",
    "THIRD_PARTY_NOTICES.txt",
  ]
  static let manifestName = "quotatempo-package.json"
  static let maximumFileBytes = 256 * 1_024
  static let maximumManifestBytes = 16 * 1_024

  static func stageBundled(bundle: Bundle = .main, storageOverride: URL? = nil) throws
    -> CodeComparisonPluginCommands
  {
    guard bundle.bundleIdentifier == bundleID,
      bundle.object(forInfoDictionaryKey: "QTReleaseChannel") as? String == channel,
      bundle.object(forInfoDictionaryKey: "QTCodeComparisonPluginBundled") as? Bool == true,
      let resources = bundle.resourceURL,
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { throw CodeComparisonPluginPackageError.notBundledPreview }
    let app = try canonicalBundlePath(bundle.bundleURL)
    let source = try bundledSource(app: app, resources: resources)
    let seal = try validateBundle(app)
    let result = try stage(
      source: source,
      storage: storageOverride
        ?? support.appendingPathComponent("QuotaTempoCodeComparisonPreview", isDirectory: true)
        .appendingPathComponent("PluginPackages", isDirectory: true),
      expectedDigest: nativeManifestDigest,
      expectedMarketplace: nativeMarketplaceName)
    guard seal.manifestDigest == nativeManifestDigest else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    guard try validateBundle(app) == seal else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    return result
  }

  private struct BundleSeal: Equatable {
    let device: UInt64
    let inode: UInt64
    let hash: Data
    let team: String?
    let manifestDigest: String
  }

  // Foundation may replace /private/tmp and /private/var with symlink aliases.
  // Signature APIs and descriptor validation must refer to one POSIX path.
  static func canonicalBundlePath(_ url: URL) throws -> URL {
    guard url.isFileURL, let path = realpath(url.path, nil) else {
      throw CodeComparisonPluginPackageError.unsafePath
    }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
  }

  static func bundledSource(app: URL, resources: URL) throws -> URL {
    let canonicalResources = try canonicalBundlePath(resources)
    guard canonicalResources == app.appendingPathComponent("Contents/Resources", isDirectory: true)
    else { throw CodeComparisonPluginPackageError.unsafePath }
    return canonicalResources.appendingPathComponent(resourceName, isDirectory: true)
  }

  private static func validateBundle(_ app: URL) throws -> BundleSeal {
    let fd = try directory(app, create: false, privateOnly: false)
    defer { Darwin.close(fd) }
    var identity = stat()
    var disk: SecStaticCode?
    var running: SecCode?
    let defaults = SecCSFlags(rawValue: 0)
    let strict = SecCSFlags(
      rawValue:
        kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    let statStatus = fstat(fd, &identity)
    let diskStatus = SecStaticCodeCreateWithPath(app as CFURL, defaults, &disk)
    let selfStatus = SecCodeCopySelf(defaults, &running)
    guard statStatus == 0, diskStatus == errSecSuccess,
      let disk,
      selfStatus == errSecSuccess, let running
    else { throw CodeComparisonPluginPackageError.invalidPackage }
    // Security APIs accept both dynamic and static code refs for these calls.
    // Dynamic information binds the on-disk seal to this executing process.
    let runningRef = unsafeBitCast(running, to: SecStaticCode.self)
    var runningPath: CFURL?
    var designated: SecRequirement?
    guard SecCodeCopyPath(runningRef, defaults, &runningPath) == errSecSuccess,
      let runningPath, try canonicalBundlePath(runningPath as URL) == app,
      SecCodeCopyDesignatedRequirement(runningRef, defaults, &designated) == errSecSuccess,
      let designated,
      SecCodeCheckValidity(running, defaults, designated) == errSecSuccess,
      SecStaticCodeCheckValidity(disk, strict, designated) == errSecSuccess
    else { throw CodeComparisonPluginPackageError.invalidPackage }
    let liveInfo = try signingInformation(runningRef)
    let diskInfo = try signingInformation(disk)
    guard let hash = liveInfo[kSecCodeInfoUnique as String] as? Data,
      !hash.isEmpty, diskInfo[kSecCodeInfoUnique as String] as? Data == hash,
      liveInfo[kSecCodeInfoIdentifier as String] as? String == bundleID,
      diskInfo[kSecCodeInfoIdentifier as String] as? String == bundleID,
      let flags = diskInfo[kSecCodeInfoFlags as String] as? NSNumber,
      let signedInfo = liveInfo[kSecCodeInfoPList as String] as? [String: Any],
      signedInfo["CFBundleIdentifier"] as? String == bundleID,
      signedInfo["QTReleaseChannel"] as? String == channel,
      signedInfo["QTCodeComparisonPluginBundled"] as? Bool == true,
      let manifestDigest = signedInfo["QTCodeComparisonManifestDigest"] as? String,
      manifestDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw CodeComparisonPluginPackageError.invalidPackage }
    let team = liveInfo[kSecCodeInfoTeamIdentifier as String] as? String
    guard diskInfo[kSecCodeInfoTeamIdentifier as String] as? String == team else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    if flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0 {
      // Ad-hoc seals provide integrity for a local preview, not publisher trust.
      guard team == nil,
        signedInfo["QTCodeComparisonSigningMode"] as? String == "local-ad-hoc",
        signedInfo["QTCodeComparisonSigningTeam"] == nil
      else { throw CodeComparisonPluginPackageError.invalidPackage }
    } else {
      guard let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
        signedInfo["QTCodeComparisonSigningMode"] as? String == "developer-id",
        signedInfo["QTCodeComparisonSigningTeam"] as? String == team
      else { throw CodeComparisonPluginPackageError.invalidPackage }
      let text =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(bundleID)\""
      var requirement: SecRequirement?
      guard
        SecRequirementCreateWithString(text as CFString, defaults, &requirement) == errSecSuccess,
        let requirement, SecStaticCodeCheckValidity(disk, strict, requirement) == errSecSuccess,
        SecCodeCheckValidity(running, defaults, requirement) == errSecSuccess
      else { throw CodeComparisonPluginPackageError.invalidPackage }
    }
    return BundleSeal(
      device: UInt64(identity.st_dev), inode: UInt64(identity.st_ino), hash: hash, team: team,
      manifestDigest: manifestDigest)
  }

  private static func signingInformation(_ code: SecStaticCode) throws -> [String: Any] {
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess, let info, let result = info as? [String: Any]
    else { throw CodeComparisonPluginPackageError.invalidPackage }
    return result
  }

  private struct CheckedPackage {
    let bytes: [String: Data]
    let digest: String
    let marketplace: String
  }

  static func stage(
    source: URL, storage: URL, expectedDigest: String? = nil,
    expectedMarketplace: String? = nil
  ) throws -> CodeComparisonPluginCommands {
    let sourceFD = try directory(source, create: false, privateOnly: false)
    defer { Darwin.close(sourceFD) }
    let checked = try verify(sourceFD, privateOnly: false)
    guard expectedDigest == nil || expectedDigest == checked.digest,
      expectedMarketplace == nil || expectedMarketplace == checked.marketplace
    else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    let storageFD = try directory(storage, create: true, privateOnly: true)
    defer { Darwin.close(storageFD) }
    // The manifest digest and build-unique marketplace bind an immutable location.
    // Never repair, overwrite, unlink or globally prune an existing package.
    let name = "\(version)-\(checked.digest)"
    let resultURL = storage.appendingPathComponent(name, isDirectory: true)
    var existing = stat()
    if fstatat(storageFD, name, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw CodeComparisonPluginPackageError.ioFailure }
      let stageName = ".stage-\(UUID().uuidString.lowercased())"
      guard mkdirat(storageFD, stageName, 0o700) == 0 else {
        throw CodeComparisonPluginPackageError.ioFailure
      }
      let fd = try childDirectory(stageName, in: storageFD, privateOnly: true)
      defer { Darwin.close(fd) }
      var stageIdentity = stat()
      guard fstat(fd, &stageIdentity) == 0 else { throw CodeComparisonPluginPackageError.ioFailure }
      var created: [(String, stat)] = []
      var moved = false
      defer {
        if !moved {
          // Stale/unknown stages are never scanned or pruned. Cleanup targets only
          // this call's exact directory and recorded inode identities.
          try? cleanupStage(
            stageName, in: storageFD, fd: fd, identity: stageIdentity, created: created)
        }
      }
      for child in [".claude-plugin", "hooks"] {
        guard mkdirat(fd, child, 0o700) == 0 else {
          throw CodeComparisonPluginPackageError.ioFailure
        }
        var info = stat()
        guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
          throw CodeComparisonPluginPackageError.ioFailure
        }
        created.append((child, info))
      }
      for file in files + [manifestName] {
        guard let bytes = checked.bytes[file] else {
          throw CodeComparisonPluginPackageError.invalidPackage
        }
        let (parent, leaf) = try parentOf(file, in: fd, privateOnly: true)
        defer { Darwin.close(parent) }
        let output = openat(
          parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw CodeComparisonPluginPackageError.ioFailure }
        do {
          var info = stat()
          guard fstat(output, &info) == 0 else { throw CodeComparisonPluginPackageError.ioFailure }
          created.append((file, info))
          try bytes.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
              let wrote = Darwin.write(
                output, buffer.baseAddress!.advanced(by: count), buffer.count - count)
              if wrote < 0 && errno == EINTR { continue }
              guard wrote > 0 else { throw CodeComparisonPluginPackageError.ioFailure }
              count += wrote
            }
          }
          guard fsync(output) == 0, fsync(parent) == 0 else {
            throw CodeComparisonPluginPackageError.ioFailure
          }
          Darwin.close(output)
        } catch {
          Darwin.close(output)
          throw error
        }
      }
      guard fsync(fd) == 0, fsync(storageFD) == 0 else {
        throw CodeComparisonPluginPackageError.ioFailure
      }
      guard try verify(fd, privateOnly: true).bytes == checked.bytes else {
        throw CodeComparisonPluginPackageError.invalidPackage
      }
      var namedStage = stat()
      guard fstatat(storageFD, stageName, &namedStage, AT_SYMLINK_NOFOLLOW) == 0,
        namedStage.st_dev == stageIdentity.st_dev, namedStage.st_ino == stageIdentity.st_ino
      else { throw CodeComparisonPluginPackageError.unsafePath }
      if renameatx_np(storageFD, stageName, storageFD, name, UInt32(RENAME_EXCL)) == 0 {
        moved = true
        guard fsync(storageFD) == 0 else { throw CodeComparisonPluginPackageError.ioFailure }
      } else {
        guard errno == EEXIST else { throw CodeComparisonPluginPackageError.ioFailure }
      }
    }
    let staged = try directory(resultURL, create: false, privateOnly: true)
    defer { Darwin.close(staged) }
    let verified = try verify(staged, privateOnly: true)
    guard verified.digest == checked.digest, verified.bytes == checked.bytes else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    // Recheck the named paths, not only still-open descriptors, before exposing commands.
    let currentSource = try directory(source, create: false, privateOnly: false)
    defer { Darwin.close(currentSource) }
    guard try verify(currentSource, privateOnly: false).bytes == checked.bytes else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    let current = try directory(resultURL, create: false, privateOnly: true)
    defer { Darwin.close(current) }
    guard try verify(current, privateOnly: true).bytes == checked.bytes else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    return CodeComparisonPluginCommands(
      directory: resultURL, pluginID: "quotatempo-usage-probe@\(checked.marketplace)",
      version: version, digest: checked.digest)
  }

  private static func verify(_ fd: Int32, privateOnly: Bool) throws -> CheckedPackage {
    let rootFiles = files.filter { !$0.contains("/") } + [manifestName, ".claude-plugin", "hooks"]
    guard Set(try names(fd)) == Set(rootFiles) else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    for child in [".claude-plugin", "hooks"] {
      let childFD = try childDirectory(child, in: fd, privateOnly: privateOnly)
      defer { Darwin.close(childFD) }
      let expected = files.filter { $0.hasPrefix(child + "/") }.map {
        String($0.dropFirst(child.count + 1))
      }
      guard Set(try names(childFD)) == Set(expected) else {
        throw CodeComparisonPluginPackageError.invalidPackage
      }
    }
    var bytes: [String: Data] = [:]
    for file in files + [manifestName] {
      let (parent, leaf) = try parentOf(file, in: fd, privateOnly: privateOnly)
      defer { Darwin.close(parent) }
      bytes[file] = try read(
        leaf, in: parent, limit: file == manifestName ? maximumManifestBytes : maximumFileBytes,
        privateOnly: privateOnly)
    }
    let manifestBytes = bytes[manifestName]!
    let manifest = try object(manifestBytes)
    guard Set(manifest.keys) == ["schemaVersion", "purpose", "releaseVersion", "files"],
      let schema = manifest["schemaVersion"] as? NSNumber,
      CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
      manifest["purpose"] as? String == "quotatempo-code-comparison-plugin",
      manifest["releaseVersion"] as? String == version,
      let hashes = manifest["files"] as? [String: String], Set(hashes.keys) == Set(files)
    else { throw CodeComparisonPluginPackageError.invalidPackage }
    for file in files {
      guard hashes[file] == digest(bytes[file]!) else {
        throw CodeComparisonPluginPackageError.invalidPackage
      }
    }
    let plugin = try object(bytes[files[0]]!)
    let marketplace = try object(bytes[files[1]]!)
    guard plugin["name"] as? String == "quotatempo-usage-probe",
      plugin["version"] as? String == version,
      let metadata = marketplace["metadata"] as? [String: Any],
      metadata["version"] as? String == version,
      let entries = marketplace["plugins"] as? [[String: Any]], entries.count == 1,
      entries[0]["name"] as? String == "quotatempo-usage-probe",
      entries[0]["source"] as? String == "./",
      entries[0]["version"] == nil || entries[0]["version"] as? String == version,
      let name = marketplace["name"] as? String,
      name.range(
        of: "^quotatempo-code-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: .regularExpression) != nil
    else { throw CodeComparisonPluginPackageError.invalidPackage }
    return CheckedPackage(bytes: bytes, digest: digest(manifestBytes), marketplace: name)
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func cleanupStage(
    _ name: String, in storage: Int32, fd: Int32, identity: stat, created: [(String, stat)]
  ) throws {
    var named = stat()
    guard fstatat(storage, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      named.st_dev == identity.st_dev, named.st_ino == identity.st_ino,
      (named.st_mode & S_IFMT) == S_IFDIR, named.st_uid == geteuid(),
      (named.st_mode & 0o7777) == 0o700
    else { throw CodeComparisonPluginPackageError.unsafePath }
    let rootNames = created.filter { !$0.0.contains("/") }.map(\.0)
    guard Set(try names(fd)).isSubset(of: Set(rootNames)) else {
      throw CodeComparisonPluginPackageError.unsafePath
    }
    // Validate all recorded directories before opening any path for cleanup.
    for (path, expected) in created where (expected.st_mode & S_IFMT) == S_IFDIR {
      var current = stat()
      guard fstatat(fd, path, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
        current.st_uid == geteuid(), (current.st_mode & 0o7777) == 0o700
      else { throw CodeComparisonPluginPackageError.unsafePath }
      let child = try childDirectory(path, in: fd, privateOnly: true)
      defer { Darwin.close(child) }
      let allowed = created.filter { $0.0.hasPrefix(path + "/") }
        .map { String($0.0.dropFirst(path.count + 1)) }
      guard Set(try names(child)).isSubset(of: Set(allowed)) else {
        throw CodeComparisonPluginPackageError.unsafePath
      }
    }
    for (path, expected) in created.reversed() {
      let (parent, leaf) = try parentOf(path, in: fd, privateOnly: true)
      defer { Darwin.close(parent) }
      var current = stat()
      guard fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
        (current.st_mode & S_IFMT) == (expected.st_mode & S_IFMT), current.st_uid == geteuid()
      else { throw CodeComparisonPluginPackageError.unsafePath }
      let flags = (expected.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0
      guard unlinkat(parent, leaf, flags) == 0 else {
        throw CodeComparisonPluginPackageError.ioFailure
      }
    }
    guard unlinkat(storage, name, AT_REMOVEDIR) == 0 else {
      throw CodeComparisonPluginPackageError.ioFailure
    }
  }

  private static func object(_ bytes: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw CodeComparisonPluginPackageError.invalidPackage
    }
    return result
  }

  private static func directory(_ url: URL, create: Bool, privateOnly: Bool) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/"),
      !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      !url.path.contains("\""), !url.path.contains("\\")
    else { throw CodeComparisonPluginPackageError.unsafePath }
    let parts = url.path.split(separator: "/").map(String.init)
    guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else {
      throw CodeComparisonPluginPackageError.unsafePath
    }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw CodeComparisonPluginPackageError.ioFailure }
    do {
      for (index, part) in parts.enumerated() {
        var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0 && errno == ENOENT && create {
          guard mkdirat(fd, part, 0o700) == 0 else {
            throw CodeComparisonPluginPackageError.ioFailure
          }
          next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else { throw CodeComparisonPluginPackageError.unsafePath }
        Darwin.close(fd)
        fd = next
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid() || info.st_uid == 0,
          (info.st_mode & 0o022) == 0 || (info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0)
        else { throw CodeComparisonPluginPackageError.unsafePath }
        if privateOnly && index == parts.count - 1 {
          guard info.st_uid == geteuid(), (info.st_mode & 0o7777) == 0o700 else {
            throw CodeComparisonPluginPackageError.unsafePath
          }
        }
      }
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  private static func childDirectory(_ name: String, in fd: Int32, privateOnly: Bool) throws
    -> Int32
  {
    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard child >= 0 else { throw CodeComparisonPluginPackageError.unsafePath }
    var info = stat()
    guard fstat(child, &info) == 0, info.st_uid == geteuid() || info.st_uid == 0,
      (info.st_mode & 0o022) == 0,
      !privateOnly || (info.st_uid == geteuid() && (info.st_mode & 0o7777) == 0o700)
    else {
      Darwin.close(child)
      throw CodeComparisonPluginPackageError.unsafePath
    }
    return child
  }

  private static func parentOf(_ path: String, in fd: Int32, privateOnly: Bool) throws -> (
    Int32, String
  ) {
    let parts = path.split(separator: "/").map(String.init)
    let parent =
      parts.count == 2 ? try childDirectory(parts[0], in: fd, privateOnly: privateOnly) : dup(fd)
    guard parent >= 0, let leaf = parts.last else {
      throw CodeComparisonPluginPackageError.ioFailure
    }
    return (parent, leaf)
  }

  private static func names(_ fd: Int32) throws -> [String] {
    // A fresh open-file description avoids the shared directory offset of dup().
    let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard copy >= 0 else { throw CodeComparisonPluginPackageError.ioFailure }
    guard let directory = fdopendir(copy) else {
      Darwin.close(copy)
      throw CodeComparisonPluginPackageError.ioFailure
    }
    defer { closedir(directory) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
      var name = entry.pointee.d_name
      let value = withUnsafePointer(to: &name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if value != "." && value != ".." { names.append(value) }
      guard names.count <= 16 else { throw CodeComparisonPluginPackageError.invalidPackage }
      errno = 0
    }
    guard errno == 0 else { throw CodeComparisonPluginPackageError.ioFailure }
    return names
  }

  private static func read(_ name: String, in parent: Int32, limit: Int, privateOnly: Bool) throws
    -> Data
  {
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw CodeComparisonPluginPackageError.unsafePath }
    defer { Darwin.close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
      before.st_size > 0, before.st_size <= limit, before.st_uid == geteuid() || before.st_uid == 0,
      (before.st_mode & 0o022) == 0,
      !privateOnly || (before.st_uid == geteuid() && (before.st_mode & 0o7777) == 0o600)
    else { throw CodeComparisonPluginPackageError.unsafePath }
    var data = Data(count: Int(before.st_size) + 1)
    let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    var after = stat()
    var named = stat()
    guard count == before.st_size, fstat(fd, &after) == 0,
      fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
      before.st_dev == named.st_dev, before.st_ino == named.st_ino,
      before.st_size == after.st_size, before.st_mode == after.st_mode,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw CodeComparisonPluginPackageError.unsafePath }
    data.removeLast()
    return data
  }
}
