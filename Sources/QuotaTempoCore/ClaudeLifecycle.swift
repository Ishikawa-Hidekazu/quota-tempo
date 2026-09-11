import Foundation

public enum ClaudeLifecycleStatus: String, Sendable {
  case inactive
  case active
  case backupOnly
}

public enum ClaudeLifecycleError: Error, Equatable {
  case consentRequired
  case unsafePath
  case invalidSettings
  case alreadyInstalled
  case missingSettings
  case missingBackup
  case ownershipDrift
  case writeFailed
}

public struct ClaudeStatusLineLifecycle {
  public let settingsURL: URL
  public let installationDirectory: URL
  public let bridgeExecutable: URL
  public let snapshotURL: URL
  private let writer: any AtomicDataWriting

  public init(
    settingsURL: URL,
    installationDirectory: URL,
    bridgeExecutable: URL,
    snapshotURL: URL,
    writer: any AtomicDataWriting = FileAtomicDataWriter()
  ) {
    self.settingsURL = settingsURL
    self.installationDirectory = installationDirectory
    self.bridgeExecutable = bridgeExecutable
    self.snapshotURL = snapshotURL
    self.writer = writer
  }

  public var wrapperURL: URL {
    self.installationDirectory.appendingPathComponent("claude-statusline-wrapper.sh")
  }

  public var backupURL: URL {
    self.installationDirectory.appendingPathComponent("claude-settings.backup.json")
  }

  public func status() throws -> ClaudeLifecycleStatus {
    let backupExists = FileManager.default.fileExists(atPath: self.backupURL.path)
    guard FileManager.default.fileExists(atPath: self.settingsURL.path) else {
      return backupExists ? .backupOnly : .inactive
    }
    let object = try self.settingsObject(from: Data(contentsOf: self.settingsURL))
    let command = (object["statusLine"] as? [String: Any])?["command"] as? String
    if command == self.wrapperURL.path { return .active }
    return backupExists ? .backupOnly : .inactive
  }

  public func activate(consent: Bool) throws {
    guard consent else { throw ClaudeLifecycleError.consentRequired }
    try self.validatePaths()
    guard !FileManager.default.fileExists(atPath: self.backupURL.path),
      !FileManager.default.fileExists(atPath: self.wrapperURL.path)
    else { throw ClaudeLifecycleError.alreadyInstalled }

    guard FileManager.default.fileExists(atPath: self.settingsURL.path) else {
      throw ClaudeLifecycleError.missingSettings
    }
    let original = try Data(contentsOf: self.settingsURL)
    var settings = try self.settingsObject(from: original)
    let hadStatusLine = settings.keys.contains("statusLine")
    let previousStatusLine = settings["statusLine"]
    let previousCommand = (settings["statusLine"] as? [String: Any])?["command"] as? String
    let wrapper = self.wrapper(previousCommand: previousCommand)
    var ownership: [String: Any] = ["hadStatusLine": hadStatusLine]
    if let previousStatusLine { ownership["statusLine"] = previousStatusLine }
    let ownershipData = try JSONSerialization.data(
      withJSONObject: ownership,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )

    do {
      try FileManager.default.createDirectory(
        at: self.installationDirectory,
        withIntermediateDirectories: true
      )
      try self.writer.write(ownershipData, to: self.backupURL)
      try self.writer.write(Data(wrapper.utf8), to: self.wrapperURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: self.wrapperURL.path
      )
      var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
      statusLine["type"] = "command"
      statusLine["command"] = self.wrapperURL.path
      settings["statusLine"] = statusLine
      let updated = try JSONSerialization.data(
        withJSONObject: settings,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      )
      try self.writer.write(updated, to: self.settingsURL)
    } catch {
      try? FileAtomicDataWriter().write(original, to: self.settingsURL)
      try? FileManager.default.removeItem(at: self.wrapperURL)
      try? FileManager.default.removeItem(at: self.backupURL)
      throw ClaudeLifecycleError.writeFailed
    }
  }

  public func rollback() throws {
    try self.restore(removeBackup: false)
  }

  public func uninstall() throws {
    if try self.status() == .backupOnly {
      guard try self.statusLineIsAlreadyRestored() else {
        throw ClaudeLifecycleError.ownershipDrift
      }
      try? FileManager.default.removeItem(at: self.wrapperURL)
      try? FileManager.default.removeItem(at: self.backupURL)
    } else {
      try self.restore(removeBackup: true)
    }
    if let contents = try? FileManager.default.contentsOfDirectory(
      at: self.installationDirectory,
      includingPropertiesForKeys: nil
    ), contents.isEmpty {
      try? FileManager.default.removeItem(at: self.installationDirectory)
    }
  }

  private func restore(removeBackup: Bool) throws {
    try self.validatePaths()
    guard FileManager.default.fileExists(atPath: self.backupURL.path) else {
      throw ClaudeLifecycleError.missingBackup
    }
    let ownership = try self.settingsObject(from: Data(contentsOf: self.backupURL))
    guard let hadStatusLine = ownership["hadStatusLine"] as? Bool else {
      throw ClaudeLifecycleError.invalidSettings
    }
    guard FileManager.default.fileExists(atPath: self.settingsURL.path) else {
      throw ClaudeLifecycleError.missingSettings
    }
    let currentData = try Data(contentsOf: self.settingsURL)
    var current = try self.settingsObject(from: currentData)
    let currentCommand = (current["statusLine"] as? [String: Any])?["command"] as? String
    guard currentCommand == self.wrapperURL.path else { throw ClaudeLifecycleError.ownershipDrift }
    if hadStatusLine {
      guard let previous = ownership["statusLine"] else {
        throw ClaudeLifecycleError.invalidSettings
      }
      current["statusLine"] = previous
    } else {
      current.removeValue(forKey: "statusLine")
    }
    let restored = try JSONSerialization.data(
      withJSONObject: current,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    do { try self.writer.write(restored, to: self.settingsURL) } catch {
      throw ClaudeLifecycleError.writeFailed
    }
    try? FileManager.default.removeItem(at: self.wrapperURL)
    if removeBackup { try? FileManager.default.removeItem(at: self.backupURL) }
  }

  private func statusLineIsAlreadyRestored() throws -> Bool {
    try self.validatePaths()
    guard FileManager.default.fileExists(atPath: self.backupURL.path) else {
      throw ClaudeLifecycleError.missingBackup
    }
    guard FileManager.default.fileExists(atPath: self.settingsURL.path) else {
      throw ClaudeLifecycleError.missingSettings
    }
    let ownership = try self.settingsObject(from: Data(contentsOf: self.backupURL))
    guard let hadStatusLine = ownership["hadStatusLine"] as? Bool else {
      throw ClaudeLifecycleError.invalidSettings
    }
    let current = try self.settingsObject(from: Data(contentsOf: self.settingsURL))
    if !hadStatusLine { return !current.keys.contains("statusLine") }
    guard let previous = ownership["statusLine"], let currentStatusLine = current["statusLine"]
    else {
      return false
    }
    return try self.canonicalJSON(previous) == self.canonicalJSON(currentStatusLine)
  }

  private func canonicalJSON(_ value: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(["value": value]) else {
      throw ClaudeLifecycleError.invalidSettings
    }
    return try JSONSerialization.data(withJSONObject: ["value": value], options: [.sortedKeys])
  }

  private func settingsObject(from data: Data) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data),
      let object = value as? [String: Any]
    else { throw ClaudeLifecycleError.invalidSettings }
    return object
  }

  private func validatePaths() throws {
    for url in [
      self.settingsURL, self.installationDirectory, self.bridgeExecutable, self.snapshotURL,
    ] {
      let standardized = url.standardizedFileURL
      if FileManager.default.fileExists(atPath: standardized.path),
        (try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
      {
        throw ClaudeLifecycleError.unsafePath
      }

      let canonicalPath: String
      if standardized.path == "/tmp" || standardized.path.hasPrefix("/tmp/") {
        canonicalPath = "/private\(standardized.path)"
      } else if standardized.path == "/var" || standardized.path.hasPrefix("/var/") {
        canonicalPath = "/private\(standardized.path)"
      } else {
        canonicalPath = standardized.path
      }

      var candidate = URL(fileURLWithPath: "/")
      for component in URL(fileURLWithPath: canonicalPath).pathComponents.dropFirst() {
        candidate.appendPathComponent(component)
        if FileManager.default.fileExists(atPath: candidate.path),
          (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        {
          throw ClaudeLifecycleError.unsafePath
        }
      }
    }
  }

  private func wrapper(previousCommand: String?) -> String {
    let bridge = Self.shellQuote(self.bridgeExecutable.path)
    let snapshot = Self.shellQuote(self.snapshotURL.path)
    let previous = previousCommand.map(Self.shellQuote) ?? ""
    let forward =
      previousCommand == nil
      ? ""
      : "printf '%s' \"$payload\" | /bin/zsh -lc \(previous)"
    return """
      #!/bin/zsh
      set -u
      payload_with_sentinel="$(/usr/bin/head -c 262145; /usr/bin/printf '\\036')"
      payload="${payload_with_sentinel%$'\\036'}"
      payload_bytes="$(LC_ALL=C /usr/bin/printf '%s' "$payload" | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
      if (( payload_bytes > 262144 )); then
        exit 2
      fi
      printf '%s' "$payload" | \(bridge) ingest-claude --output \(snapshot) >/dev/null 2>&1 || true
      \(forward)
      """
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

extension ClaudeLifecycleError {
  public var stableCode: String {
    switch self {
    case .consentRequired: "consent_required"
    case .unsafePath: "unsafe_path"
    case .invalidSettings: "invalid_settings"
    case .alreadyInstalled: "already_installed"
    case .missingSettings: "missing_settings"
    case .missingBackup: "missing_backup"
    case .ownershipDrift: "ownership_drift"
    case .writeFailed: "write_failed"
    }
  }
}
