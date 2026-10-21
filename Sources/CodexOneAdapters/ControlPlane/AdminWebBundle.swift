import CodexOneCore
import Dispatch
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// An immutable, bounded startup snapshot; never a general filesystem or data-directory server.
public struct AdminWebBundle: Sendable {
  struct Asset: Sendable {
    let data: Data
    let contentType: String
  }
  private let assets: [String: Asset]
  func asset(path: String) -> Asset? { assets[path] }

  public static func load(path: String) async throws -> Self {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do { continuation.resume(returning: try read(path: path)) } catch {
          continuation.resume(throwing: ExecutionError.invalidCommand)
        }
      }
    }
  }
  private static func read(path: String) throws -> Self {
    guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else {
      throw ExecutionError.invalidCommand
    }
    let root = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw ExecutionError.invalidCommand }
    defer { close(root) }
    try checkDirectory(root)
    let index = try file(root, name: "index.html", maximum: 65_536)
    var assets: [String: Asset] = [
      "/": .init(data: index, contentType: "text/html; charset=utf-8"),
      "/index.html": .init(data: index, contentType: "text/html; charset=utf-8"),
    ]
    let directory = openat(root, "assets", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw ExecutionError.invalidCommand }
    defer { close(directory) }
    try checkDirectory(directory)
    let descriptor = dup(directory)
    guard descriptor >= 0 else { throw ExecutionError.invalidCommand }
    guard let entries = fdopendir(descriptor) else {
      close(descriptor)
      throw ExecutionError.invalidCommand
    }
    defer { closedir(entries) }
    var count = 0
    var total = index.count
    while true {
      errno = 0
      guard let entry = readdir(entries) else {
        guard errno == 0 else { throw ExecutionError.invalidCommand }
        break
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) { value in
        value.withMemoryRebound(
          to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
        ) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      count += 1
      guard count <= 32, name.utf8.count <= 128,
        name.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || [45, 46, 95].contains($0)
        }),
        name.hasSuffix(".js") || name.hasSuffix(".css")
      else { throw ExecutionError.invalidCommand }
      let data = try file(directory, name: name, maximum: 1_048_576)
      total += data.count
      guard total <= 4_194_304 else { throw ExecutionError.invalidCommand }
      assets["/assets/" + name] = .init(
        data: data,
        contentType: name.hasSuffix(".js")
          ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8")
    }
    guard count > 0 else { throw ExecutionError.invalidCommand }
    return Self(assets: assets)
  }
  private static func checkDirectory(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      [0, geteuid()].contains(info.st_uid), info.st_mode & 0o022 == 0
    else { throw ExecutionError.invalidCommand }
  }
  private static func file(_ parent: Int32, name: String, maximum: Int) throws -> Data {
    let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw ExecutionError.invalidCommand }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      [0, geteuid()].contains(info.st_uid), info.st_mode & 0o022 == 0,
      info.st_size > 0, info.st_size <= maximum
    else { throw ExecutionError.invalidCommand }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data = try file.read(upToCount: maximum + 1) ?? Data()
    guard data.count == info.st_size else { throw ExecutionError.invalidCommand }
    return data
  }
}
