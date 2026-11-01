import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

@testable import CodexOneAdapters

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
private struct PrimingAdminProbe: QuotaPrimingExecuting {
  let models = ["synthetic-cheap", "synthetic-text"]
  let defaultModel: String? = "synthetic-cheap"
  func executePriming(id: String, settings: QuotaPrimingSettings) async throws {
    Issue.record("Management must never send a priming request")
  }
}
@Test(.timeLimit(.minutes(1))) func quotaPrimingAdminAuthCASModelAndMessageValidation() async throws
{
  try await withOAuth { h in
    let login = try await h.login()
    _ = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    let secret = "synthetic-admin-" + String(repeating: "a", count: 32)
    let key = h.root.appendingPathComponent("admin")
    try Data(secret.utf8).write(to: key)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    let keys = try await KeyAdminAPI.load(path: key.path, store: h.store)
    let auth = try AccountAuthorizationSupervisor(application: h.app, provider: h.provider)
    let accounts = AccountAdminAPI(
      store: h.store, authorization: auth, refreshing: h.supervisor, priming: PrimingAdminProbe())
    let port = AccountAdminPort()
    let admin = AdminService(
      group: h.group, port: 0, reportProvider: { .init(checks: []) }, keys: keys,
      accounts: accounts, onBound: { value in port.value.withLock { $0 = value } })
    let owner = Task {
      try await GatewayRuntime(services: [auth, admin]).run(handleSignals: false)
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    do {
      try await awaitOAuth { port.value.withLock { $0 > 0 } }
      let client = AccountAdminClient(port: port.value.withLock { $0 }, session: session)
      let base = "/api/accounts/account/quota-priming"
      #expect(try await client.call("GET", base).0 == 401)
      let origin = "http://127.0.0.1:\(client.port)"
      let sessionLogin = try await client.call(
        "POST", "/api/session",
        body: .object(["username": .string("admin"), "secret": .string(secret)]),
        headers: ["origin": origin])
      let cookie = try #require(sessionLogin.2?.split(separator: ";").first.map(String.init))
      let csrf = try #require(sessionLogin.1["csrf"]?.string)
      let browser = ["origin": origin, "cookie": cookie, "x-codexone-csrf": csrf]
      let saved = try await client.call("GET", base, headers: browser)
      #expect(saved.0 == 200 && saved.3 == "no-store")
      #expect(
        saved.1["settings"]?["enabled"] == .bool(false)
          && saved.1["settings"]?["message"] == .string("hello"))
      #expect(saved.1["defaultModel"] == .string("synthetic-cheap"))
      let valid: [String: JSONValue] = [
        "revision": .number(1), "enabled": .bool(true), "model": .string("synthetic-text"),
        "message": .string("hello"),
      ]
      #expect(
        try await client.call(
          "PUT", base, body: .object(valid), headers: ["origin": origin, "cookie": cookie]
        ).0 == 403)
      #expect(
        try await client.call(
          "PUT", base, body: .object(valid),
          headers: [
            "origin": "https://synthetic.invalid", "cookie": cookie, "x-codexone-csrf": csrf,
          ]
        ).0 == 403)
      for (field, value) in [
        ("model", JSONValue.string("removed")), ("message", .string("")),
        ("message", .string(String(repeating: "a", count: 201))),
        ("message", .string("line\nbreak")), ("max_output_tokens", .number(100)),
      ] {
        var body = valid
        body[field] = value
        #expect(try await client.call("PUT", base, body: .object(body), headers: browser).0 == 400)
      }
      #expect(try await client.call("GET", base + "?model=other", headers: browser).0 == 400)
      #expect(try await client.call("PUT", base, body: .object(valid), headers: browser).0 == 200)
      #expect(try await client.call("PUT", base, body: .object(valid), headers: browser).0 == 409)
      #expect(try await h.store.quotaPrimingState(id: "account").settings.enabled)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    _ = await owner.result
  }
}
