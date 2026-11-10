import Darwin
import Foundation

public enum PrivateFile {
  /// Exclusive creation with private permissions from the first byte, without following symlinks.
  public static func writeNew(_ data: Data, to url: URL) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw VaultError.invalid(L("无法新建文件，请选择不存在的文件名")) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try file.write(contentsOf: data)
      try file.synchronize()
      try file.close()
    } catch {
      try? file.close()
      unlink(url.path)
      throw error
    }
  }
}
