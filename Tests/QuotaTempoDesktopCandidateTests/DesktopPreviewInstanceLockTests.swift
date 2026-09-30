import Foundation
import Testing

@testable import QuotaTempoDesktopCandidate

@Suite("Desktop preview instance lock")
struct DesktopPreviewInstanceLockTests {
  @Test func secondInstanceIsRejectedAndClosingAllowsRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var first: DesktopPreviewInstanceLock? = try DesktopPreviewInstanceLock(directory: directory)
    #expect(first != nil)
    #expect(throws: DesktopPreviewInstanceLock.LockError.self) {
      try DesktopPreviewInstanceLock(directory: directory)
    }
    first = nil
    let next = try DesktopPreviewInstanceLock(directory: directory)
    withExtendedLifetime(next) {}
    let data = try Data(contentsOf: directory.appendingPathComponent("desktop-preview.lock"))
    #expect(data.isEmpty)
  }

  @Test func symlinkLockIsRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("desktop-preview.lock"), withDestinationURL: target)
    #expect(throws: DesktopPreviewInstanceLock.LockError.self) {
      try DesktopPreviewInstanceLock(directory: directory)
    }
  }
}
