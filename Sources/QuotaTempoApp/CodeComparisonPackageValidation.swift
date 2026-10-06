import Darwin
import Foundation

enum CodeComparisonPackageValidation {
  static let flag = "--code-comparison-package-validation"

  struct Result: Equatable {
    let passed: Bool
    var exitCode: Int32 { passed ? 0 : 2 }
    var json: String {
      passed
        ? "{\"status\":\"packageValidated\",\"passed\":true,\"version\":\"0.0.4\",\"liveCodeAccepted\":false}"
        : "{\"status\":\"packageValidationFailed\",\"passed\":false}"
    }
  }

  // This preview-only path validates resources without creating SwiftUI,
  // preferences, provider clients or a Code session.
  static func run(
    _ arguments: [String],
    stage: (URL) throws -> CodeComparisonPluginCommands = {
      try CodeComparisonPluginPackage.stageBundled(storageOverride: $0)
    }
  ) -> Result {
    guard arguments.count == 3, arguments[0] == flag,
      arguments[1] == "--private-test-directory",
      let match = arguments[2].range(
        of:
          "^/private/tmp/qtc-package-validation-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: .regularExpression), match == arguments[2].startIndex..<arguments[2].endIndex
    else { return Result(passed: false) }
    let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { return Result(passed: false) }
    defer { close(parent) }
    let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
    guard mkdirat(parent, root.lastPathComponent, 0o700) == 0 else {
      return Result(passed: false)
    }
    let fd = openat(
      parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return Result(passed: false) }
    defer { close(fd) }
    var identity = stat()
    guard fstat(fd, &identity) == 0, identity.st_uid == getuid(),
      identity.st_mode & 0o7777 == 0o700
    else { return Result(passed: false) }
    do {
      let result = try stage(root.appendingPathComponent("packages", isDirectory: true))
      var current = stat()
      guard fstatat(parent, root.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
        current.st_uid == getuid(), current.st_mode & 0o7777 == 0o700,
        result.version == CodeComparisonPluginPackage.version,
        result.directory.path.hasPrefix(root.path + "/packages/")
      else { return Result(passed: false) }
      return Result(passed: true)
    } catch { return Result(passed: false) }
  }
}
