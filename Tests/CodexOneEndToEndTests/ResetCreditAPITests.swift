import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

@testable import CodexOneAdapters

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test(.timeLimit(.minutes(1))) func resetCreditAdminSocketAuthCSRFInputsAndSafeDTO() async throws {
  try await withOAuth(timeout: 3000) { h in
    let login = try await h.login()
    let account = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    h.server.state.mutex.withLock {
      $0.quotaAuthorization = (login.credential.accessToken, "synthetic-workspace")
    }
    let secret = "synthetic-reset-admin-" + String(repeating: "a", count: 32)
    let key = h.root.appendingPathComponent("admin")
    try Data(secret.utf8).write(to: key)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    let keys = try await KeyAdminAPI.load(path: key.path, store: h.store)
    let auth = try AccountAuthorizationSupervisor(application: h.app, provider: h.provider)
    let provider = try SubscriptionQuotaProvider(
      group: h.group, verifier: h.provider, target: .syntheticLoopback(port: h.server.port))
    let resets = try ResetCreditSupervisor(
      store: h.store, credentials: h.app, provider: provider, clock: testClock)
    let accounts = AccountAdminAPI(
      store: h.store, authorization: auth, refreshing: h.supervisor, resetCredits: resets)
    let port = AccountAdminPort()
    let admin = AdminService(
      group: h.group, port: 0, reportProvider: { .init(checks: []) }, keys: keys,
      accounts: accounts, onBound: { value in port.value.withLock { $0 = value } })
    let owner = Task {
      try await GatewayRuntime(services: [provider, resets, auth, admin]).run(handleSignals: false)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      try await awaitOAuth {
        port.value.withLock { $0 > 0 } && resets.isAccepting && provider.isAccepting
      }
      let client = AccountAdminClient(port: port.value.withLock { $0 }, session: session)
      let base = "/api/accounts/" + account.id + "/reset-credits"
      #expect(try await client.call("GET", base).0 == 401)
      let origin = "http://127.0.0.1:\(client.port)"
      let sessionLogin = try await client.call(
        "POST", "/api/session",
        body: .object(["username": .string("admin"), "secret": .string(secret)]),
        headers: ["origin": origin])
      let cookie = try #require(sessionLogin.2?.split(separator: ";").first.map(String.init))
      let csrf = try #require(sessionLogin.1["csrf"]?.string)
      let browser = ["origin": origin, "cookie": cookie, "x-codexone-csrf": csrf]
      for route in [base + "/consume", base + "/settings"] {
        #expect(
          try await client.call(
            route.hasSuffix("settings") ? "PUT" : "POST", route, body: .object([:]),
            headers: ["origin": origin, "cookie": cookie]
          ).0 == 403)
      }
      #expect(
        try await client.call(
          "POST", base + "/consume", body: .object([:]),
          headers: [
            "origin": "https://synthetic.invalid", "cookie": cookie, "x-codexone-csrf": csrf,
          ]
        ).0 == 403)
      let prior = h.server.counts.calls
      for body: JSONValue in [
        .object(["creditID": .null]), .object(["creditID": .string("")]),
        .object(["redeem_request_id": .string("client-chosen")]),
        .object(["owner": .string("other")]),
      ] {
        #expect(
          try await client.call("POST", base + "/consume", body: body, headers: browser).0 == 400)
      }
      #expect(try await client.call("GET", base + "?owner=other", headers: browser).0 == 400)
      #expect(h.server.counts.calls == prior)
      h.server.set(.reply(Data("{\"credits\":[],\"available_count\":0}".utf8)))
      let list = try await client.call("GET", base, headers: browser)
      #expect(list.0 == 200 && list.3 == "no-store")
      #expect(list.1["state"]?["settings"]?["autoUseBeforeExpiry"] == .bool(false))
      for hours in [0, 169] {
        #expect(
          try await client.call(
            "PUT", base + "/settings",
            body: .object([
              "revision": .number(1), "autoUseBeforeExpiry": .bool(true),
              "leadHours": .number(Decimal(hours)),
            ]), headers: browser
          ).0 == 400)
      }
      let settings: JSONValue = .object([
        "revision": .number(1), "autoUseBeforeExpiry": .bool(true), "leadHours": .number(48),
      ])
      #expect(
        try await client.call("PUT", base + "/settings", body: settings, headers: browser).0 == 200)
      #expect(
        try await client.call("PUT", base + "/settings", body: settings, headers: browser).0 == 409)
      h.server.set(.reply(Data("{\"code\":\"nothing_to_reset\",\"windows_reset\":0}".utf8)))
      let consumed = try await client.call(
        "POST", base + "/consume", body: .object([:]), headers: browser)
      #expect(consumed.0 == 200 && consumed.1["code"] == .string("nothing_to_reset"))
      let state = try await client.call("GET", base + "/state", headers: browser)
      #expect(
        state.1["pending"] == .bool(false) && state.1["lastCode"] == .string("nothing_to_reset"))
      let encoded = String(decoding: try state.1.data(), as: UTF8.self)
      #expect(
        !encoded.contains("requestID") && !encoded.contains("namespace")
          && !encoded.contains(login.credential.accessToken))
      #expect(h.server.counts.invalid == 0)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    _ = await owner.result
  }
}
