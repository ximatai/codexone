import CodexOneCore
import CodexOneRuntime
import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import CodexOneAdapters

@Test(.timeLimit(.minutes(1))) func realOAuthSocketEstablishesScopeAndRefreshesOneDurableVersion()
  async throws
{
  try await withOAuth { h in
    let url = try h.provider.authorizationURL(
      state: String(repeating: "s", count: 43), nonce: oauthNonce, verifier: oauthVerifier)
    let query = URLComponents(string: url)?.queryItems ?? []
    #expect(
      query.first { $0.name == "code_challenge" }?.value
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(!url.contains(oauthVerifier))
    let login = try await h.login()
    let account = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    await #expect(throws: AccountRefreshError.invalidCommand) {
      try await h.provider.refresh(credential: login.credential, namespace: "forged-namespace")
    }
    #expect(h.server.counts.calls == 1)
    // Optional refreshed ID/refresh token may be absent only when fresh access claims prove the same scope.
    let bytes = try oauthTokens(includeID: false)
    var body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    body.removeValue(forKey: "refresh_token")
    h.server.set(.reply(try JSONSerialization.data(withJSONObject: body)))
    let refreshed = try await h.supervisor.refreshAccount(
      id: account.id, revision: account.revision)
    #expect(
      refreshed.authorization == .ready && refreshed.credentialVersion == 2
        && refreshed.mode == .disabled)
    #expect(h.server.counts.calls == 2 && h.server.counts.invalid == 0)
    try await awaitOAuth { h.server.counts.active == 0 && h.provider.activeRequests == 0 }
    let metadata = try JSONEncoder().encode(await h.store.listAccounts())
    #expect(!metadata.contains(Data("synthetic-refresh-initial".utf8)))
    for file in try FileManager.default.contentsOfDirectory(
      at: h.root, includingPropertiesForKeys: nil)
    where file.lastPathComponent.hasPrefix("core.sqlite") {
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      #expect(data.range(of: Data(login.credential.accessToken.utf8)) == nil)
      #expect(data.range(of: Data(login.credential.refreshToken.utf8)) == nil)
      #expect(data.range(of: Data(String(repeating: "5a", count: 32).utf8)) == nil)
    }
  }
}

@Test(.timeLimit(.minutes(1))) func realOAuthFailuresNeverPublishChangedOrUnknownIdentityOrReplay()
  async throws
{
  for mode in [
    "account", "subject", "audience", "expired", "missing", "malformed", "oversized", "empty-type",
    "abort", "private-error", "auth-required", "revoked", "contradictory-rejection",
    "auth-marker-failure",
  ] {
    try await withOAuth { h in
      let login = try await h.login()
      let account = try await h.app.importVerified(
        id: "account", namespace: login.namespace, credential: login.credential)
      let plan: OAuthPlan
      switch mode {
      case "account": plan = .reply(try oauthTokens(account: "other-workspace"))
      case "subject": plan = .reply(try oauthTokens(subject: "other-user"))
      case "audience": plan = .reply(try oauthTokens(idAudience: "other-client"))
      case "expired":
        plan = .reply(try oauthTokens(accessExpiry: Int64(Date().timeIntervalSince1970) - 60))
      case "missing": plan = .reply(try oauthTokens(missingAccount: true))
      case "oversized": plan = .oversized
      case "empty-type": plan = .reply(try oauthTokens(), type: "")
      case "abort": plan = .abort
      case "private-error":
        plan = .reply(
          Data("{\"error_description\":\"synthetic-refresh-initial\"}".utf8), status: 500)
      case "auth-required", "auth-marker-failure":
        plan = .reply(Data("{\"error\":\"invalid_grant\"}".utf8), status: 400)
      case "revoked":
        plan = .reply(
          Data(
            "{\"error\":{\"code\":\"refresh_token_invalidated\",\"message\":\"synthetic-refresh-initial\"}}"
              .utf8), status: 401)
      case "contradictory-rejection":
        var value = try #require(
          JSONSerialization.jsonObject(with: oauthTokens()) as? [String: Any])
        value["error"] = "invalid_grant"
        plan = .reply(try JSONSerialization.data(withJSONObject: value), status: 400)
      default: plan = .reply(Data("{}".utf8))
      }
      if mode == "auth-marker-failure" {
        try await h.store.perform { db in
          try db.exec(
            "CREATE TRIGGER fail_auth_marker BEFORE INSERT ON account_events WHEN NEW.action='refresh_requires_auth' BEGIN SELECT RAISE(ABORT,'synthetic'); END"
          )
        }
      }
      h.server.set(plan)
      let requiresAuth = ["auth-required", "revoked"].contains(mode)
      let expected: AccountRefreshError =
        mode == "auth-marker-failure"
        ? .storageUnavailable : (requiresAuth ? .authorizationRequired : .unavailable)
      await #expect(throws: expected) {
        try await h.supervisor.refreshAccount(id: account.id, revision: account.revision)
      }
      let failed = try await h.store.accountCredential(id: account.id).account
      #expect(
        failed.authorization
          == (mode == "auth-marker-failure"
            ? .refreshing : (requiresAuth ? .requiresAuth : .authUncertain))
          && failed.credentialVersion == 1)
      await #expect(throws: AccountRefreshError.conflict) {
        try await h.supervisor.refreshAccount(id: failed.id, revision: failed.revision)
      }
      #expect(h.server.counts.calls == 2 && h.server.counts.invalid == 0)
      try await awaitOAuth { h.provider.activeRequests == 0 && h.server.counts.active == 0 }
    }
  }
}

@Test(.timeLimit(.minutes(1))) func realOAuthRedirectCannotForwardCredentialsToAnotherEndpoint()
  async throws
{
  try await withOAuth { h in
    let sink = try await OAuthServer.open(group: h.group, plan: .reply(Data("{}".utf8)))
    do {
      let login = try await h.login()
      let account = try await h.app.importVerified(
        id: "account", namespace: login.namespace, credential: login.credential)
      h.server.set(.redirect("http://127.0.0.1:\(sink.port)/credential-sink"))
      await #expect(throws: AccountRefreshError.unavailable) {
        try await h.supervisor.refreshAccount(id: account.id, revision: account.revision)
      }
      #expect(h.server.counts.calls == 2 && sink.counts.calls == 0)
      #expect(
        try await h.store.accountCredential(id: account.id).account.authorization == .authUncertain)
    } catch {
      await sink.close()
      throw error
    }
    await sink.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func realOAuthHeaderAndProgressingBodyDeadlinesAndShutdownCloseSockets() async throws {
  for mode in ["headers", "body", "shutdown"] {
    try await withOAuth(timeout: mode == "shutdown" ? 10_000 : 500) { h in
      let login = try await h.login()
      let account = try await h.app.importVerified(
        id: "account", namespace: login.namespace, credential: login.credential)
      h.server.set(mode == "headers" ? .headersStall : .bodyDrip)
      let started = ContinuousClock.now
      let caller = Task {
        try await h.supervisor.refreshAccount(id: account.id, revision: account.revision)
      }
      try await awaitOAuth(mode + "-accepted") {
        h.server.counts.calls == 2 && h.server.counts.active == 1
      }
      if mode == "shutdown" { h.owner.cancel() }
      _ = await caller.result
      if mode == "shutdown" { _ = await h.owner.result }
      try await awaitOAuth(mode + "-released") {
        h.server.counts.active == 0 && h.provider.activeRequests == 0
      }
      #expect(started.duration(to: .now) < .seconds(2))
      #expect(
        try await h.store.accountCredential(id: account.id).account.authorization == .authUncertain)
      #expect(h.server.counts.calls == 2)
    }
  }
}

@Test(.timeLimit(.minutes(1))) func realOAuthTransportCapacityIsAcquiredBeforeSendingAnotherToken()
  async throws
{
  try await withOAuth { h in
    var logins: [VerifiedSubscriptionLogin] = []
    for index in 0..<5 {
      h.server.set(
        .reply(
          try oauthTokens(
            account: "workspace-" + String(index), refresh: "synthetic-refresh-" + String(index))))
      logins.append(try await h.login(code: "synthetic-code-" + String(index) + "+/="))
    }
    h.server.set(.headersStall)
    let callers = logins.prefix(4).map { login in
      Task {
        try await h.provider.refresh(credential: login.credential, namespace: login.namespace)
      }
    }
    try await awaitOAuth("capacity-dispatched") {
      h.server.counts.calls == 9 && h.provider.activeRequests == 4
    }
    let rejected = logins[4]
    await #expect(throws: AccountRefreshError.capacity) {
      try await h.provider.refresh(credential: rejected.credential, namespace: rejected.namespace)
    }
    #expect(h.server.counts.calls == 9)
    for caller in callers { caller.cancel() }
    for caller in callers { _ = await caller.result }
    try await awaitOAuth("capacity-released") {
      h.server.counts.active == 0 && h.provider.activeRequests == 0
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func realOAuthLoginRequiresExpectedNonceAudienceAndCurrentMatchingClaims() async throws {
  for mode in ["nonce", "audience", "scope", "expired", "issuer", "algorithm"] {
    try await withOAuth { h in
      let bytes: Data
      switch mode {
      case "nonce": bytes = try oauthTokens(nonce: String(repeating: "x", count: 43))
      case "audience": bytes = try oauthTokens(idAudience: "other-client")
      case "scope": bytes = try oauthTokens(accessAccount: "other-workspace")
      case "expired": bytes = try oauthTokens(idExpiry: Int64(Date().timeIntervalSince1970) - 60)
      case "issuer": bytes = try oauthTokens(idIssuer: "https://foreign.example")
      default: bytes = try oauthTokens(idAlgorithm: "none")
      }
      h.server.set(.reply(bytes))
      await #expect(throws: AccountRefreshError.unavailable) { try await h.login() }
      #expect(h.server.counts.calls == 1 && h.server.counts.invalid == 0)
      #expect(try await h.store.listAccounts().isEmpty)
    }
  }
}

@Test(.timeLimit(.minutes(1))) func authorizationOwnerPersistsOnlyAfterRealSocketVerification()
  async throws
{
  try await withOAuth { h in
    let service = try AccountAuthorizationSupervisor(application: h.app, provider: h.provider)
    let owner = Task { try await service.run() }
    do {
      try await awaitOAuth { await service.isAccepting }
      let flow = try await service.begin(owner: "synthetic-session", target: .create)
      let query = try #require(URLComponents(string: flow.authorizationURL)?.queryItems)
      let nonce = try #require(query.first(where: { $0.name == "nonce" })?.value)
      let state = try #require(query.first(where: { $0.name == "state" })?.value)
      let challenge = try #require(query.first(where: { $0.name == "code_challenge" })?.value)
      h.server.state.mutex.withLock {
        $0.expectedVerifier = nil
        $0.expectedChallenge = challenge
      }
      h.server.set(.reply(try oauthTokens(nonce: nonce)))
      let url =
        SubscriptionOAuthProvider.callbackURI + "?state=" + state
        + "&code=synthetic-code%2B%2F%3D"
      let account = try await service.complete(
        owner: "synthetic-session", flowID: flow.flowID, callbackURL: url)
      #expect(account.authorization == .ready && account.mode == .disabled)
      #expect(h.server.counts.calls == 1 && h.server.counts.invalid == 0)
      #expect(try await h.store.listAccounts().count == 1)
      await #expect(throws: AccountRefreshError.conflict) {
        try await service.complete(
          owner: "synthetic-session", flowID: flow.flowID, callbackURL: url)
      }
      #expect(h.server.counts.calls == 1)
      owner.cancel()
      try await owner.value
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
  }
}

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
private final class AccountAdminPort: Sendable { let value = Mutex(0) }
private struct AccountAdminClient: Sendable {
  let port: Int
  let session: URLSession
  func call(
    _ method: String, _ path: String, body: JSONValue? = nil, headers: [String: String] = [:]
  ) async throws -> (Int, JSONValue, String?) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
    request.httpMethod = method
    request.timeoutInterval = 5
    if let body {
      request.httpBody = try body.data()
      request.setValue("application/json", forHTTPHeaderField: "content-type")
    }
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (bytes, raw) = try await session.data(for: request)
    let response = try #require(raw as? HTTPURLResponse)
    return (
      response.statusCode, try JSONValue.decode(bytes),
      response.value(forHTTPHeaderField: "set-cookie")
    )
  }
}

@Test(.timeLimit(.minutes(1))) func accountManagementUsesRealAuthGuardsAndVerifiedSocketFlows()
  async throws
{
  try await withOAuth(timeout: 3000) { h in
    let secret = "synthetic-admin-secret-" + String(repeating: "a", count: 32)
    let path = h.root.appendingPathComponent("admin")
    try Data(secret.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let keys = try await KeyAdminAPI.load(path: path.path, store: h.store)
    let authorization = try AccountAuthorizationSupervisor(application: h.app, provider: h.provider)
    let accounts = AccountAdminAPI(
      store: h.store, authorization: authorization, refreshing: h.supervisor)
    let port = AccountAdminPort()
    let admin = AdminService(
      group: h.group, port: 0, reportProvider: { .init(checks: []) }, keys: keys,
      accounts: accounts,
      onBound: { bound in port.value.withLock { $0 = bound } })
    let owner = Task {
      try await GatewayRuntime(services: [authorization, admin]).run(handleSignals: false)
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    do {
      try await awaitOAuth { port.value.withLock { $0 > 0 } && h.provider.isAccepting }
      let client = AccountAdminClient(port: port.value.withLock { $0 }, session: session)
      let bearer = ["authorization": "Bearer " + secret]
      #expect(try await client.call("GET", "/api/accounts").0 == 401)
      let origin = "http://127.0.0.1:\(client.port)"
      let login = try await client.call(
        "POST", "/api/session", body: .object(["secret": .string(secret)]),
        headers: ["origin": origin])
      #expect(login.0 == 200)
      let cookie = try #require(login.2?.split(separator: ";").first.map(String.init))
      let csrf = try #require(login.1["csrf"]?.string)
      let browser = ["origin": origin, "cookie": cookie, "x-codexone-csrf": csrf]
      #expect(
        try await client.call(
          "POST", "/api/accounts/authorization", body: .object(["target": .null]),
          headers: ["origin": origin, "cookie": cookie]
        ).0 == 403)
      #expect(
        try await client.call(
          "GET", "/api/accounts", headers: ["origin": origin, "authorization": "Bearer " + secret]
        ).0 == 403)
      let start = try await client.call(
        "POST", "/api/accounts/authorization", body: .object(["target": .null]), headers: bearer)
      #expect(start.0 == 200)
      let flowID = try #require(start.1["flowID"]?.string)
      let query = try #require(
        URLComponents(string: start.1["authorizationURL"]?.string ?? "")?.queryItems)
      let nonce = try #require(query.first(where: { $0.name == "nonce" })?.value)
      let state = try #require(query.first(where: { $0.name == "state" })?.value)
      let challenge = try #require(query.first(where: { $0.name == "code_challenge" })?.value)
      h.server.state.mutex.withLock {
        $0.expectedVerifier = nil
        $0.expectedChallenge = challenge
      }
      h.server.set(.reply(try oauthTokens(nonce: nonce)))
      let callback =
        SubscriptionOAuthProvider.callbackURI + "?state=" + state + "&code=synthetic-code%2B%2F%3D"
      let completionPath = "/api/accounts/authorization/" + flowID
      let document: JSONValue = .object(["callbackURL": .string(callback)])
      #expect(
        try await client.call("POST", completionPath, body: document, headers: browser).0 == 409)
      #expect(h.server.counts.calls == 0)
      let completed = try await client.call("POST", completionPath, body: document, headers: bearer)
      #expect(completed.0 == 200)
      let account = try #require(completed.1["account"])
      let id = try #require(account["id"]?.string)
      #expect(account["mode"]?.string == "disabled" && account["authorization"]?.string == "ready")
      #expect(
        account["namespace"] == nil && account["refreshIntent"] == nil
          && account["credential"] == nil)
      #expect(
        try await client.call("POST", completionPath, body: document, headers: bearer).0 == 409)
      let enabled = try await client.call(
        "PUT", "/api/accounts/" + id,
        body: .object(["revision": account["revision"]!, "mode": .string("enabled")]),
        headers: browser)
      #expect(enabled.0 == 200)
      #expect(
        try await client.call(
          "PUT", "/api/accounts/" + id,
          body: .object(["revision": account["revision"]!, "mode": .string("disabled")]),
          headers: browser
        ).0 == 409)
      h.server.set(.reply(Data(#"{"error":"invalid_grant"}"#.utf8), status: 400))
      let refresh = try await client.call(
        "POST", "/api/accounts/" + id + "/refresh",
        body: .object(["revision": enabled.1["account"]!["revision"]!]), headers: browser)
      #expect(refresh.0 == 409 && refresh.1["error"]?["code"]?.string == "authorization_required")
      let listed = try await client.call("GET", "/api/accounts", headers: browser)
      #expect(
        listed.0 == 200
          && listed.1["accounts"]?.array?.first?["authorization"]?.string == "requires_auth")
      #expect(h.server.counts.calls == 2 && h.server.counts.invalid == 0)
      let previous = try #require(listed.1["accounts"]?.array?.first)
      let restart = try await client.call(
        "POST", "/api/accounts/authorization",
        body: .object(["target": .object(["id": .string(id), "revision": previous["revision"]!])]),
        headers: browser)
      let restartID = try #require(restart.1["flowID"]?.string)
      let restartQuery = try #require(
        URLComponents(string: restart.1["authorizationURL"]?.string ?? "")?.queryItems)
      let restartState = try #require(restartQuery.first(where: { $0.name == "state" })?.value)
      let restartNonce = try #require(restartQuery.first(where: { $0.name == "nonce" })?.value)
      let restartChallenge = try #require(
        restartQuery.first(where: { $0.name == "code_challenge" })?.value)
      h.server.state.mutex.withLock { $0.expectedChallenge = restartChallenge }
      h.server.set(.replyAfterDelay(try oauthTokens(nonce: restartNonce)))
      let completionBody = try JSONValue.object([
        "callbackURL": .string(
          SubscriptionOAuthProvider.callbackURI + "?state=" + restartState
            + "&code=synthetic-code%2B%2F%3D")
      ]).data()
      let connection = try await ClientBootstrap(group: h.group).connect(
        host: "127.0.0.1", port: client.port
      ).get()
      var wire =
        "POST /api/accounts/authorization/" + restartID
        + " HTTP/1.1\r\nHost: 127.0.0.1:\(client.port)\r\nContent-Type: application/json\r\nContent-Length: \(completionBody.count)\r\nCookie: "
        + cookie + "\r\nOrigin: " + origin + "\r\nX-CodexOne-CSRF: " + csrf
        + "\r\nConnection: close\r\n\r\n"
      wire += String(decoding: completionBody, as: UTF8.self)
      try await connection.writeAndFlush(ByteBuffer(string: wire)).get()
      try await awaitOAuth { h.server.counts.calls == 3 }
      #expect(try await h.store.accountCredential(id: id).account.authorization == .requiresAuth)
      try await connection.close().get()
      // A detached HTTP response is not a rollback; the Service still owns the accepted operation.
      try await awaitOAuth {
        try await h.store.accountCredential(id: id).account.credentialVersion == 2
      }
      let reauthorized = try await client.call("GET", "/api/accounts", headers: browser)
      let final = try #require(reauthorized.1["accounts"]?.array?.first)
      #expect(reauthorized.0 == 200 && final["id"]?.string == id)
      #expect(final["authorization"]?.string == "ready" && final["mode"]?.string == "enabled")
      #expect(h.server.counts.calls == 3 && h.server.counts.invalid == 0)
      _ = try await client.call("DELETE", "/api/session", headers: browser)
      #expect(try await client.call("GET", "/api/accounts", headers: browser).0 == 401)
      owner.cancel()
      try await owner.value
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func subscriptionDataAccessUsesVerifiedScopeAndSeparatesSyntheticTargets() async throws {
  try await withOAuth { h in
    let login = try await h.login()
    var account = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    account = try await h.store.setAccountMode(
      id: account.id, revision: account.revision, mode: .enabled)
    let work = try await h.app.prepareDispatch(id: account.id, continuation: false)
    let access = try h.provider.dataAccess(work: work, target: .syntheticLoopback(port: 12345))
    #expect(access.baseURL == "http://127.0.0.1:12345/backend-api/codex")
    #expect(access.headers["authorization"] == ["Bearer " + login.credential.accessToken])
    #expect(access.headers["chatgpt-account-id"] == ["synthetic-workspace"])
    #expect(access.headers.count == 2)
    #expect(String(reflecting: access) == "SubscriptionDataAccess(redacted)")
    #expect(throws: AccountDispatchError.unavailable) { try h.provider.dataAccess(work: work) }
    for port in [0, 65536] {
      #expect(throws: AccountDispatchError.unavailable) {
        try h.provider.dataAccess(work: work, target: .syntheticLoopback(port: port))
      }
    }
    let production = try SubscriptionOAuthProvider(group: h.group)
    #expect(throws: AccountDispatchError.unavailable) {
      try production.dataAccess(work: work, target: .syntheticLoopback(port: 12345))
    }
    #expect(throws: AccountDispatchError.unavailable) { try production.dataAccess(work: work) }
    let claims = try SubscriptionClaims.idToken(
      #require(login.credential.idToken), nonce: nil, requireCurrent: false)
    let productionNamespace = try production.identityNamespace(claims)
    let productionAccount = try await h.app.importVerified(
      id: "production-fixture", namespace: productionNamespace, credential: login.credential)
    _ = try await h.store.setAccountMode(
      id: productionAccount.id, revision: productionAccount.revision, mode: .enabled)
    let productionWork = try await h.app.prepareDispatch(
      id: productionAccount.id, continuation: false)
    let productionAccess = try production.dataAccess(work: productionWork)
    #expect(productionAccess.baseURL == "https://chatgpt.com/backend-api/codex")
    #expect(throws: AccountDispatchError.unavailable) {
      try production.dataAccess(work: productionWork, target: .syntheticLoopback(port: 12345))
    }
    #expect(h.server.counts.calls == 1)
  }
}

@Test(.timeLimit(.minutes(1)))
func subscriptionDataAccessRejectsChangedScopeAndAcceptsExpiredTrustedIDBaseline() async throws {
  for mode in ["account", "subject", "namespace", "expired-id", "expired-access", "missing-id"] {
    try await withOAuth { h in
      let login = try await h.login()
      let now = Int64(Date().timeIntervalSince1970)
      let data = try oauthTokens(
        subject: mode == "subject" ? "other-subject" : "synthetic-user",
        accessExpiry: mode == "expired-access" ? now - 1 : now + 3600,
        accessAccount: mode == "account" ? "other-account" : nil,
        idExpiry: mode == "expired-id" ? now - 1 : now + 3600)
      let tokens = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      // Seal a deliberately inconsistent fixture to prove dispatch fails before sending any data.
      let credential = try AccountCredential(
        accessToken: #require(tokens["access_token"] as? String), refreshToken: "synthetic-refresh",
        idToken: mode == "missing-id" ? nil : login.credential.idToken,
        expiresAtUnixSeconds: now + 3600)
      let id = mode == "expired-id" ? tokens["id_token"] as? String : credential.idToken
      let stored = try AccountCredential(
        accessToken: credential.accessToken, refreshToken: credential.refreshToken, idToken: id,
        expiresAtUnixSeconds: credential.expiresAtUnixSeconds)
      var account = try await h.app.importVerified(
        id: "account", namespace: mode == "namespace" ? "synthetic/other" : login.namespace,
        credential: stored)
      account = try await h.store.setAccountMode(
        id: account.id, revision: account.revision, mode: .enabled)
      let work = try await h.app.prepareDispatch(id: account.id, continuation: false)
      if mode == "expired-id" {
        _ = try h.provider.dataAccess(work: work, target: .syntheticLoopback(port: 12345))
      } else {
        #expect(throws: AccountDispatchError.unavailable) {
          try h.provider.dataAccess(work: work, target: .syntheticLoopback(port: 12345))
        }
      }
      #expect(h.server.counts.calls == 1)
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func refusedOAuthConnectionPreservesValidCredentialAndClosesIntentWithoutRotation() async throws {
  try await withOAuth { h in
    let login = try await h.login()
    let account = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    await h.server.close()
    await #expect(throws: AccountRefreshError.notCompleted) {
      try await h.supervisor.refreshAccount(id: account.id, revision: account.revision)
    }
    let current = try await h.store.accountCredential(id: account.id).account
    #expect(current.authorization == .ready)
    #expect(current.refreshIntent == nil)
    #expect(current.credentialVersion == account.credentialVersion)
    #expect(h.server.counts.calls == 1)
  }
}
