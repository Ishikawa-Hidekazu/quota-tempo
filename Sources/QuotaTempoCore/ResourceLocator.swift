import Foundation

enum QuotaTempoResourceLocator {
  private static let directoryName = "QuotaTempoCoreResources"

  static func url(
    forResource name: String,
    withExtension extensionName: String,
    subdirectory: String? = nil
  ) -> URL? {
    let safeName = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard
      !name.isEmpty,
      name.unicodeScalars.allSatisfy(safeName.contains),
      !extensionName.isEmpty,
      extensionName.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    else { return nil }
    guard let root = self.rootURL() else { return nil }
    let directory = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    let candidate = directory.appendingPathComponent("\(name).\(extensionName)")

    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    return candidate
  }

  static func localizedBundle(languageCode: String) -> Bundle? {
    guard let root = self.rootURL() else { return nil }
    let candidate = root.appendingPathComponent("\(languageCode).lproj", isDirectory: true)
    return Bundle(path: candidate.path)
  }

  private static func rootURL() -> URL? {
    let fileManager = FileManager.default
    let appCandidate = Bundle.main.resourceURL?.appendingPathComponent(
      self.directoryName,
      isDirectory: true
    )
    var candidates = [appCandidate].compactMap { $0 }
    if Bundle.main.bundleURL.pathExtension.lowercased() != "app" {
      var executableParent = Bundle.main.executableURL?.deletingLastPathComponent()
      for _ in 0..<12 {
        guard let directory = executableParent else { break }
        candidates.append(
          directory.appendingPathComponent(
            "Sources/QuotaTempoCore/Resources",
            isDirectory: true
          )
        )
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { break }
        executableParent = parent
      }
      candidates.append(
        URL(
          fileURLWithPath: fileManager.currentDirectoryPath,
          isDirectory: true
        ).appendingPathComponent("Sources/QuotaTempoCore/Resources", isDirectory: true)
      )
    }

    for candidate in candidates {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return candidate
      }
    }
    return nil
  }
}
