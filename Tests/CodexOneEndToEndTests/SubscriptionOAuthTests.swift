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

private let oauthNonce = String(repeating: "n", count: 43)
private let oauthVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
private enum OAuthPlan: Sendable {
  case reply(Data, type: String = "application/json", status: Int = 200)
  case redirect(String)
  case headersStall, bodyDrip, oversized, abort
}
private func oauthJWT(_ claims: [String: Any], algorithm: String = "RS256") throws -> String {
  let header = SubscriptionOAuthProvider.base64URL(
    try JSONSerialization.data(withJSONObject: ["alg": algorithm]))
  let payload = SubscriptionOAuthProvider.base64URL(
    try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
  return header + "." + payload + "."
    + SubscriptionOAuthProvider.base64URL(Data("synthetic-signature".utf8))
}
private func oauthTokens(
  account: String = "synthetic-workspace", subject: String = "synthetic-user",
  refresh: String = "synthetic-refresh-next", nonce: String = oauthNonce, idAudience: String? = nil,
  accessExpiry: Int64? = nil, missingAccount: Bool = false, includeID: Bool = true,
  accessAccount: String? = nil, idExpiry: Int64? = nil,
  idIssuer: String = SubscriptionOAuthProvider.issuer, idAlgorithm: String = "RS256"
) throws -> Data {
  let now = Int64(Date().timeIntervalSince1970)
  let auth: [String: Any] =
    missingAccount
    ? [:] : ["chatgpt_account_id": accessAccount ?? account, "chatgpt_user_id": "synthetic-member"]
  let access = try oauthJWT([
    "iss": SubscriptionOAuthProvider.issuer, "sub": subject, "exp": accessExpiry ?? now + 3600,
    "aud": ["https://api.openai.com/v1"], "https://api.openai.com/auth": auth,
  ])
  var body: [String: Any] = [
    "access_token": access, "refresh_token": refresh, "expires_in": 3600, "token_type": "Bearer",
  ]
  if includeID {
    body["id_token"] = try oauthJWT(
      [
        "iss": idIssuer, "sub": subject, "exp": idExpiry ?? now + 3600,
        "aud": idAudience ?? SubscriptionOAuthProvider.clientID, "nonce": nonce,
        "https://api.openai.com/auth": [
          "chatgpt_account_id": account, "chatgpt_user_id": "synthetic-member",
        ],
      ], algorithm: idAlgorithm)
  }
  return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}
private final class OAuthServerShared: Sendable {
  let mutex: Mutex<OAuthServer.State>
  init(_ value: OAuthServer.State) { mutex = Mutex(value) }
}
private final class OAuthServer: Sendable {
  struct State {
    var plan: OAuthPlan
    var calls = 0
    var invalidRequests = 0
    var expectedVerifier: String? = oauthVerifier
    var expectedChallenge: String?
    var channels: [ObjectIdentifier: any Channel] = [:]
  }
  let state: OAuthServerShared
  let listener: any Channel
  var port: Int { listener.localAddress!.port! }
  var counts: (calls: Int, active: Int, invalid: Int) {
    state.mutex.withLock { ($0.calls, $0.channels.count, $0.invalidRequests) }
  }
  func set(_ plan: OAuthPlan) { state.mutex.withLock { $0.plan = plan } }
  private init(state: OAuthServerShared, listener: any Channel) {
    self.state = state
    self.listener = listener
  }
  static func open(group: any EventLoopGroup, plan: OAuthPlan) async throws -> Self {
    let state = OAuthServerShared(.init(plan: plan))
    let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      // Continue reading peer FIN while deliberately withholding a response.
      channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
        channel.pipeline.addHandler(OAuthHandler(state: state))
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    return Self(state: state, listener: listener)
  }
  func close() async {
    let channels = state.mutex.withLock { Array($0.channels.values) }
    for channel in channels { try? await channel.close().get() }
    try? await listener.close().get()
  }
}
/// Mutable channel fields are confined to its NIO event loop; shared observations use Mutex.
private final class OAuthHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let state: OAuthServerShared
  private var head: HTTPRequestHead?
  private var body = Data()
  private var timer: Scheduled<Void>?
  init(state: OAuthServerShared) { self.state = state }
  func channelActive(context: ChannelHandlerContext) {
    state.mutex.withLock { $0.channels[ObjectIdentifier(context.channel)] = context.channel }
    context.fireChannelActive()
  }
  func channelInactive(context: ChannelHandlerContext) {
    timer?.cancel()
    timer = nil
    _ = state.mutex.withLock { $0.channels.removeValue(forKey: ObjectIdentifier(context.channel)) }
    context.fireChannelInactive()
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): self.head = head
    case .body(let bytes):
      body.append(contentsOf: bytes.readableBytesView)
      if body.count > 65_536 { context.close(promise: nil) }
    case .end:
      let valid = validateRequest()
      let plan = state.mutex.withLock { value in
        value.calls += 1
        if !valid { value.invalidRequests += 1 }
        return value.plan
      }
      switch plan {
      case .reply(let data, let type, let status):
        reply(context, data: data, type: type, status: status)
      case .redirect(let location): reply(context, data: Data(), status: 307, location: location)
      case .headersStall: break
      case .bodyDrip:
        let headers: HTTPHeaders = [
          "content-type": "application/json", "content-length": "10000", "connection": "close",
        ]
        context.write(
          wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: headers))),
          promise: nil)
        context.writeAndFlush(
          wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: "{")))),
          promise: nil)
        drip(context)
      case .oversized: reply(context, data: Data(repeating: 32, count: 65_537))
      case .abort: context.close(promise: nil)
      }
    }
  }
  private func validateRequest() -> Bool {
    guard let head, head.method == .POST, head.uri == "/oauth/token",
      head.headers["authorization"].isEmpty
    else { return false }
    var fields: [String: String] = [:]
    if head.headers.first(name: "content-type") == "application/x-www-form-urlencoded",
      let raw = String(data: body, encoding: .utf8)
    {
      for item in URLComponents(string: "http://synthetic.invalid/?" + raw)?.queryItems ?? [] {
        fields[item.name] = item.value
      }
      guard let verifier = fields["code_verifier"], !verifier.isEmpty else { return false }
      let expected = state.mutex.withLock { ($0.expectedVerifier, $0.expectedChallenge) }
      let verifierMatches: Bool
      if let fixed = expected.0 {
        verifierMatches = verifier == fixed
      } else if let challenge = expected.1 {
        verifierMatches =
          SubscriptionOAuthProvider.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
          == challenge
      } else {
        verifierMatches = false
      }
      return fields["client_id"] == SubscriptionOAuthProvider.clientID
        && fields["grant_type"] == "authorization_code"
        && fields["code"]?.hasPrefix("synthetic-code") == true
        && fields["code"]?.hasSuffix("+/=") == true
        && verifierMatches
        && fields["redirect_uri"] == SubscriptionOAuthProvider.callbackURI
    }
    guard let document = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
      return false
    }
    return head.headers.first(name: "content-type") == "application/json"
      && document["client_id"] == SubscriptionOAuthProvider.clientID
      && document["grant_type"] == "refresh_token"
      && document["refresh_token"]?.hasPrefix("synthetic-refresh-") == true
  }
  private func reply(
    _ context: ChannelHandlerContext, data: Data, type: String = "application/json",
    status: Int = 200, location: String? = nil
  ) {
    var headers: HTTPHeaders = [
      "content-type": type, "content-length": String(data.count), "connection": "close",
    ]
    if let location { headers.add(name: "location", value: location) }
    context.write(
      wrapOutboundOut(
        .head(.init(version: .http1_1, status: .init(statusCode: status), headers: headers))),
      promise: nil)
    context.write(
      wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: data)))),
      promise: nil)
    let promise = context.eventLoop.makePromise(of: Void.self)
    let channel = context.channel
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
    promise.futureResult.whenComplete { _ in channel.close(promise: nil) }
  }
  private func drip(_ context: ChannelHandlerContext) {
    let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
    timer = context.eventLoop.scheduleTask(in: .milliseconds(10)) { [self] in
      let context = bound.value
      guard context.channel.isActive else { return }
      context.writeAndFlush(
        wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: " ")))),
        promise: nil)
      drip(context)
    }
  }
}
private struct OAuthHarness: Sendable {
  let group: MultiThreadedEventLoopGroup
  let server: OAuthServer
  let provider: SubscriptionOAuthProvider
  let supervisor: AccountRefreshSupervisor
  let store: SQLiteExecutionStore
  let app: AccountCredentials
  let owner: Task<Void, any Error>
  let root: URL
  static func open(timeout: Int) async throws -> Self {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await OAuthServer.open(
      group: group, plan: .reply(try oauthTokens(refresh: "synthetic-refresh-initial")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store: SQLiteExecutionStore?
    var owner: Task<Void, any Error>?
    do {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let key = root.appendingPathComponent("master")
      try Data(String(repeating: "5a", count: 32).utf8).write(to: key)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
      let cipher = try await AccountCredentialCipher.load(path: key.path)
      let database = try await SQLiteExecutionStore.open(
        path: root.appendingPathComponent("core.sqlite").path,
        limits: .init(requests: 100, active: 4, unresolved: 4, budgetMicros: 100))
      store = database
      let app = AccountCredentials(store: database, protection: cipher)
      let provider = try SubscriptionOAuthProvider(
        group: group, authority: .syntheticLoopback(port: server.port), timeoutMilliseconds: timeout
      )
      let supervisor = try AccountRefreshSupervisor(application: app, provider: provider)
      let task = Task {
        try await GatewayRuntime(services: [provider, supervisor]).run(handleSignals: false)
      }
      owner = task
      try await awaitOAuth { provider.isAccepting && supervisor.isAccepting }
      return Self(
        group: group, server: server, provider: provider, supervisor: supervisor, store: database,
        app: app, owner: task, root: root)
    } catch {
      owner?.cancel()
      _ = await owner?.result
      await store?.close()
      await server.close()
      try? await group.shutdownGracefully()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
  func login(code: String = "synthetic-code+/=") async throws -> VerifiedSubscriptionLogin {
    try await provider.exchangeAuthorizationCode(
      code: code, verifier: oauthVerifier, expectedNonce: oauthNonce)
  }
  func close() async {
    owner.cancel()
    _ = await owner.result
    await store.close()
    await server.close()
    try? await group.shutdownGracefully()
    try? FileManager.default.removeItem(at: root)
  }
}
private func awaitOAuth(
  _ label: String = "owned-state", _ condition: @Sendable () async throws -> Bool
) async throws {
  for _ in 0..<600 {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Synthetic OAuth socket did not reach bounded state: \(label)")
  throw AccountRefreshError.unavailable
}
private func withOAuth(timeout: Int = 1000, _ operation: (OAuthHarness) async throws -> Void)
  async throws
{
  let fixture = try await OAuthHarness.open(timeout: timeout)
  do { try await operation(fixture) } catch {
    await fixture.close()
    throw error
  }
  await fixture.close()
}

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
      let data = try Data(contentsOf: file)
      #expect(!data.contains(Data(login.credential.accessToken.utf8)))
      #expect(!data.contains(Data(login.credential.refreshToken.utf8)))
      #expect(!data.contains(Data(String(repeating: "5a", count: 32).utf8)))
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
