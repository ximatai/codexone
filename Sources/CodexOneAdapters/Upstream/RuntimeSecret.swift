import CodexOneCore
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// External runtime injection only; the gateway never saves or refreshes this short-lived credential.
func readPrivateData(_ path: String, maximum: Int) throws -> Data {
  let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else { throw ExecutionError.invalidCommand }
  defer { close(descriptor) }
  var info = stat()
  guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
    info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size > 0,
    info.st_size <= maximum
  else {
    throw ExecutionError.invalidCommand
  }
  let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  let data = try file.read(upToCount: maximum + 1) ?? Data()
  guard data.count <= maximum else { throw ExecutionError.invalidCommand }
  return data
}

func readRuntimeSecret(_ path: String) throws -> String {
  let data = try readPrivateData(path, maximum: 16_384)
  guard let raw = String(data: data, encoding: .utf8) else {
    throw ExecutionError.invalidCommand
  }
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty, value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
    throw ExecutionError.invalidCommand
  }
  return value
}
