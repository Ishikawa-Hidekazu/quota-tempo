import Darwin
import Foundation

struct DesktopFileStamp: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanos: Int
  let changedSeconds: Int
  let changedNanos: Int

  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
    size = info.st_size
    modifiedSeconds = info.st_mtimespec.tv_sec
    modifiedNanos = info.st_mtimespec.tv_nsec
    changedSeconds = info.st_ctimespec.tv_sec
    changedNanos = info.st_ctimespec.tv_nsec
  }
}

enum DesktopProtectedFile {
  // Component-wise openat prevents following symlinks in either the file or its parents.
  static func withDescriptor<T>(
    _ url: URL, maximumBytes: Int, body: (Int32, DesktopFileStamp) throws -> T
  ) throws -> T {
    guard url.isFileURL, maximumBytes > 0 else { throw DesktopCredentialError.unsafePath }
    let components = url.path.split(separator: "/").map(String.init)
    guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
      throw DesktopCredentialError.unsafePath
    }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw DesktopCredentialError.unavailable }
    defer { Darwin.close(fd) }
    for (index, part) in components.enumerated() {
      let isFile = index == components.count - 1
      let next = openat(
        fd, part, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (isFile ? 0 : O_DIRECTORY))
      guard next >= 0 else {
        throw errno == ENOENT ? DesktopCredentialError.unavailable : .unsafePath
      }
      Darwin.close(fd)
      fd = next
      var info = stat()
      guard fstat(fd, &info) == 0,
        info.st_uid == geteuid() || (!isFile && info.st_uid == 0),
        (info.st_mode & 0o022) == 0
          || (!isFile && info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0),
        (info.st_mode & S_IFMT) == (isFile ? S_IFREG : S_IFDIR)
      else { throw DesktopCredentialError.unsafePath }
      if isFile {
        guard info.st_nlink == 1 else { throw DesktopCredentialError.unsafePath }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
          throw DesktopCredentialError.inputTooLarge
        }
        return try body(fd, DesktopFileStamp(info))
      }
    }
    throw DesktopCredentialError.unsafePath
  }

  static func stamp(_ url: URL, maximumBytes: Int) throws -> DesktopFileStamp {
    try withDescriptor(url, maximumBytes: maximumBytes) { _, stamp in stamp }
  }

  static func read(_ url: URL, maximumBytes: Int) throws -> (data: Data, stamp: DesktopFileStamp) {
    try withDescriptor(url, maximumBytes: maximumBytes) { fd, before in
      var data = Data(count: Int(before.size) + 1)
      let capacity = data.count
      let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
      guard count >= 0, count == before.size else { throw DesktopCredentialError.changedDuringRead }
      data.count = count
      var info = stat()
      guard fstat(fd, &info) == 0, DesktopFileStamp(info) == before,
        try stamp(url, maximumBytes: maximumBytes) == before
      else { throw DesktopCredentialError.changedDuringRead }
      return (data, before)
    }
  }
}
