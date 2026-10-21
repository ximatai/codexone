import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func bundleDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
  try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
  try Data("export {};".utf8).write(to: root.appendingPathComponent("assets/app.js"))
  return root
}
@Test func webBundleIsAnImmutableExactPathSnapshot() async throws {
  let root = try bundleDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundle = try await AdminWebBundle.load(path: root.path)
  #expect(bundle.asset(path: "/")?.contentType == "text/html; charset=utf-8")
  #expect(bundle.asset(path: "/assets/app.js")?.contentType == "text/javascript; charset=utf-8")
  #expect(bundle.asset(path: "/assets/../index.html") == nil)
  #expect(bundle.asset(path: "/missing") == nil)
  try FileManager.default.removeItem(at: root.appendingPathComponent("assets/app.js"))
  #expect(bundle.asset(path: "/assets/app.js")?.data == Data("export {};".utf8))
}
@Test func webBundleRejectsLinksWritableFilesAndOversizedOrUnknownAssets() async throws {
  for mode in ["symlink", "hardlink", "writable", "oversized", "unknown", "count"] {
    let root = try bundleDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let asset = root.appendingPathComponent("assets/app.js")
    switch mode {
    case "symlink":
      try FileManager.default.removeItem(at: asset)
      try FileManager.default.createSymbolicLink(
        at: asset, withDestinationURL: root.appendingPathComponent("index.html"))
    case "hardlink":
      try FileManager.default.linkItem(at: asset, to: root.appendingPathComponent("extra.js"))
    case "writable":
      try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: asset.path)
    case "oversized":
      try Data(repeating: 32, count: 1_048_577).write(to: asset)
    case "unknown":
      try Data("private".utf8).write(to: root.appendingPathComponent("assets/config.json"))
    default:
      for index in 0..<32 {
        try Data("x".utf8).write(to: root.appendingPathComponent("assets/a\(index).css"))
      }
    }
    await #expect(throws: ExecutionError.invalidCommand) {
      try await AdminWebBundle.load(path: root.path)
    }
  }
}
