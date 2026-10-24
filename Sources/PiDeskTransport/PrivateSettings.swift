import Darwin
import Foundation

public enum PrivateSettings {
  private static func directory(_ url: URL) throws {
    guard url.path.hasPrefix("/"), url.standardized.path == url.path else {
      throw SocketFailure.unsafePath
    }
    let parts = url.deletingLastPathComponent().path.split(separator: "/")
    var path = ""
    for (i, part) in parts.enumerated() {
      path += "/" + part
      var info = stat()
      if lstat(path, &info) != 0 {
        guard errno == ENOENT, mkdir(path, 0o700) == 0, lstat(path, &info) == 0 else {
          throw SocketFailure.unsafeDirectory
        }
      }
      guard (info.st_mode & S_IFMT) == S_IFDIR else { throw SocketFailure.unsafeDirectory }
      if i == parts.count - 1 {
        guard info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
          throw SocketFailure.unsafeDirectory
        }
      }
    }
  }
  private static func checked(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
      (info.st_mode & 0o077) == 0, info.st_nlink == 1, info.st_size <= 16384
    else { throw SocketFailure.unsafePath }
  }
  public static func load(_ url: URL) throws -> Data {
    try directory(url)
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw SocketFailure.unsafePath }
    defer { Darwin.close(fd) }
    try checked(fd)
    var bytes = [UInt8](repeating: 0, count: 16385)
    let n = Darwin.read(fd, &bytes, bytes.count)
    guard n >= 0, n <= 16384 else { throw SocketFailure.unsafePath }
    return Data(bytes.prefix(n))
  }
  public static func save(_ data: Data, to url: URL) throws {
    guard data.count <= 16384 else { throw SocketFailure.unsafePath }
    try directory(url)
    var info = stat()
    if lstat(url.path, &info) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
        (info.st_mode & 0o077) == 0
      else { throw SocketFailure.unsafePath }
    } else if errno != ENOENT {
      throw SocketFailure.unsafePath
    }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".settings-" + UUID().uuidString)
    let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw SocketFailure.unsafePath }
    defer {
      Darwin.close(fd)
      _ = unlink(temporary.path)
    }
    let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    guard n == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
      throw SocketFailure.systemCall
    }
  }
}
