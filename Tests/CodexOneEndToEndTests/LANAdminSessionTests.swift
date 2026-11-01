import CodexOneAdapters
import CodexOneRuntime
import Foundation
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import CodexOneCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    "https://admin.example", "http://127.0.0.1:19876", "http://192.168.1.10:18081",
  ])
func actualAdminSocketsPreserveSessionRejectionAndCookieContracts(origin: String) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let secret = "synthetic-lan-session-credential-for-socket-tests"
  let credential = root.appendingPathComponent("admin")
  try Data(secret.utf8).write(to: credential)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
  let store = try await SQLiteExecutionStore.open(
    path: root.appendingPathComponent("core.sqlite").path,
    limits: .init(requests: 10, active: 2, unresolved: 2, budgetMicros: 100))
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let bound = Mutex(0)
  let keys = try await KeyAdminAPI.load(
    path: credential.path, store: store, publicOrigin: origin, listenAddress: "192.168.1.10")
  let admin = AdminService(
    group: group, port: 0, reportProvider: { .unconfigured }, keys: keys,
    onBound: { port in bound.withLock { $0 = port } })
  let owner = Task { try await GatewayRuntime(services: [admin]).run(handleSignals: false) }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.httpShouldSetCookies = false
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  do {
    for _ in 0..<300 {
      if bound.withLock({ $0 }) > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let port = bound.withLock { $0 }
    try #require(port > 0)
    let authority = String(origin.split(separator: "/", omittingEmptySubsequences: true)[1])
    func request(
      _ method: String, host: String? = nil, browserOrigin: String? = nil,
      cookie: String? = nil, csrf: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/session")!)
      request.timeoutInterval = 3
      request.httpMethod = method
      request.setValue(host ?? authority, forHTTPHeaderField: "host")
      request.setValue(browserOrigin ?? origin, forHTTPHeaderField: "origin")
      request.setValue(cookie, forHTTPHeaderField: "cookie")
      request.setValue(csrf, forHTTPHeaderField: "x-codexone-csrf")
      if method == "POST" {
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
          "username": "admin", "secret": secret,
        ])
      }
      let (body, response) = try await session.data(for: request)
      return (body, try #require(response as? HTTPURLResponse))
    }
    #expect(try await request("POST", host: "foreign.example").1.statusCode == 403)
    #expect(try await request("POST", browserOrigin: "https://foreign.example").1.statusCode == 403)
    let (body, response) = try await request("POST")
    #expect(response.statusCode == 200)
    let header = try #require(response.value(forHTTPHeaderField: "set-cookie"))
    let lan = origin.hasPrefix("http://192.")
    let name = lan ? "codexone_admin" : "__Host-codexone_admin"
    #expect(header.hasPrefix(name + "=as1_"))
    #expect(
      header.hasSuffix(lan ? "; HttpOnly; SameSite=Strict" : "; HttpOnly; Secure; SameSite=Strict"))
    #expect(!header.contains("Domain="))
    let cookie = String(header.split(separator: ";")[0])
    let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let csrf = try #require(object?["csrf"] as? String)
    #expect(try await request("GET", cookie: cookie).1.statusCode == 200)
    #expect(try await request("DELETE", cookie: cookie).1.statusCode == 403)
    #expect(try await request("DELETE", cookie: cookie, csrf: "wrong-proof").1.statusCode == 403)
    let (_, logout) = try await request("DELETE", cookie: cookie, csrf: csrf)
    #expect(logout.statusCode == 200)
    #expect(
      logout.value(forHTTPHeaderField: "set-cookie") == name + "=; Path=/; Max-Age=0; HttpOnly;"
        + (lan ? "" : " Secure;") + " SameSite=Strict")
    #expect(try await request("GET", cookie: cookie).1.statusCode == 401)
  } catch {
    owner.cancel()
    _ = await owner.result
    await store.close()
    try await group.shutdownGracefully()
    throw error
  }
  owner.cancel()
  try await owner.value
  await store.close()
  try await group.shutdownGracefully()
}
