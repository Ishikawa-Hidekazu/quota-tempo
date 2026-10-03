import Darwin
import Foundation

// Empty process-lifetime lock only; no credentials, observations or settings.
final class DesktopPreviewInstanceLock {
  private let descriptor: Int32

  init(directory: URL) throws {
    let path = directory.appendingPathComponent("desktop-preview.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw LockError.unavailable }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid(), metadata.st_nlink == 1,
      flock(descriptor, LOCK_EX | LOCK_NB) == 0
    else {
      close(descriptor)
      throw LockError.unavailable
    }
    self.descriptor = descriptor
  }

  enum LockError: Error { case unavailable }
  deinit { close(descriptor) }
}
