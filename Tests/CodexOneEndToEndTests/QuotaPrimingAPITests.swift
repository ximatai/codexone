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
    let at: Int64 = 1_800_000_000
    let accounts = AccountAdminAPI(
      store: h.store, authorization: auth, refreshing: h.supervisor,
      clock: WallClock { TimeInterval(at) }, priming: PrimingAdminProbe())
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
      let trend = "/api/accounts/account/quota-trend"
      #expect(try await client.call("GET", trend).0 == 401)
      let credits = "/api/accounts/account/usage-credit-history"
      #expect(try await client.call("GET", credits + "?range=24h").0 == 401)
      let origin = "http://127.0.0.1:\(client.port)"
      let sessionLogin = try await client.call(
        "POST", "/api/session",
        body: .object(["username": .string("admin"), "secret": .string(secret)]),
        headers: ["origin": origin])
      let cookie = try #require(sessionLogin.2?.split(separator: ";").first.map(String.init))
      let csrf = try #require(sessionLogin.1["csrf"]?.string)
      let browser = ["origin": origin, "cookie": cookie, "x-codexone-csrf": csrf]
      let emptyTrend = try await client.call("GET", trend, headers: browser)
      #expect(emptyTrend.0 == 200 && emptyTrend.1 == .object([:]) && emptyTrend.3 == "no-store")
      let account = try await h.store.accountCredential(id: "account").account
      let quota = try SubscriptionQuota(
        limits: [
          .init(
            id: "codex", allowed: true, limitReached: false,
            primary: .init(
              usedPercent: 80, durationSeconds: 18_000, resetsAtUnixSeconds: at + 3600),
            secondary: nil)
        ], usageCredits: .balance("12345.9876543210"))
      _ = try await h.store.recordQuotaObservation(
        account: account, atUnixSeconds: at, result: .success(quota))
      let recorded = try await client.call("GET", trend, headers: browser)
      #expect(
        recorded.0 == 200
          && recorded.1["primary"]?["samples"]
            == .array([.array([.number(Decimal(at)), .number(20)])])
      )
      #expect(try await client.call("GET", trend + "?unused=1", headers: browser).0 == 400)
      let history = try await client.call("GET", credits + "?range=24h", headers: browser)
      #expect(history.0 == 200 && history.3 == "no-store")
      #expect(
        history.1["segments"]
          == .array([
            .array([
              .object([
                "at": .number(Decimal(at)), "balance": .string("12345.9876543210"),
              ])
            ])
          ]))
      #expect(try await client.call("GET", credits + "?range=7d", headers: browser).0 == 200)
      #expect(try await client.call("GET", credits + "?range=30d", headers: browser).0 == 400)
      #expect(
        try await client.call("GET", credits + "?range=7d&range=24h", headers: browser).0 == 400)
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
