import Darwin
import Foundation

@MainActor
enum CodeComparisonStartupValidation {
  static let flag = "--code-comparison-startup-validation"

  struct Result: Equatable {
    let passed: Bool
    var exitCode: Int32 { passed ? 0 : 2 }
    var json: String {
      passed
        ? "{\"status\":\"startupValidated\",\"passed\":true,\"providersDisabled\":true,\"guiStarted\":false,\"liveCodeAccepted\":false}"
        : "{\"status\":\"startupValidationFailed\",\"passed\":false}"
    }
  }

  // Exercise the bundled defaults getter and real app composition without
  // App.main(), provider acquisition or existing preference/store reads.
  static func run(
    _ arguments: [String],
    isCodePreview: () -> Bool = { QuotaTempoAppDefaults.isBundledCodePreview },
    initialize: @MainActor (URL) throws -> Void = initializeApplication
  ) -> Result {
    guard arguments.count == 3, arguments[0] == flag,
      arguments[1] == "--private-test-directory", isCodePreview(),
      let match = arguments[2].range(
        of:
          "^/private/tmp/qtc-startup-validation-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: .regularExpression), match == arguments[2].startIndex..<arguments[2].endIndex
    else { return Result(passed: false) }
    let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { return Result(passed: false) }
    defer { close(parent) }
    let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
    guard mkdirat(parent, root.lastPathComponent, 0o700) == 0 else {
      return Result(passed: false)
    }
    let fd = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return Result(passed: false) }
    defer { close(fd) }
    var identity = stat()
    guard fstat(fd, &identity) == 0, identity.st_uid == getuid(),
      identity.st_mode & 0o7777 == 0o700
    else { return Result(passed: false) }
    do {
      try initialize(root)
      var current = stat()
      guard fstatat(parent, root.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
        current.st_uid == getuid(), current.st_mode & 0o7777 == 0o700
      else { return Result(passed: false) }
      return Result(passed: true)
    } catch { return Result(passed: false) }
  }

  private static func initializeApplication(_ root: URL) throws {
    // Construct, but do not read, the production defaults object. This reaches
    // the exact getter that crashed before any SwiftUI scene was created.
    guard QuotaTempoAppDefaults.defaults === UserDefaults.standard else {
      throw ValidationError.invalidDefaults
    }
    let suite = "QuotaTempoStartupValidation.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw ValidationError.invalidDefaults
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let app = QuotaTempoApp(
      arguments: ["QuotaTempo", "--provider-disabled"],
      supportDirectory: root.appendingPathComponent("support", isDirectory: true),
      defaults: defaults)
    withExtendedLifetime(app) {}
  }

  private enum ValidationError: Error { case invalidDefaults }
}
