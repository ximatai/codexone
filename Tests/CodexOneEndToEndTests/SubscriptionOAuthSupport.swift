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

let oauthNonce = String(repeating: "n", count: 43)
let oauthVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
enum OAuthPlan: Sendable {
  case reply(Data, type: String = "application/json", status: Int = 200)
  case replyAfterDelay(Data)
  case redirect(String)
  case headersStall, bodyDrip, oversized, abort
}
func oauthJWT(_ claims: [String: Any], algorithm: String = "RS256") throws -> String {
  let header = SubscriptionOAuthProvider.base64URL(
    try JSONSerialization.data(withJSONObject: ["alg": algorithm]))
  let payload = SubscriptionOAuthProvider.base64URL(
    try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
  return header + "." + payload + "."
    + SubscriptionOAuthProvider.base64URL(Data("synthetic-signature".utf8))
}
func oauthTokens(
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
final class OAuthServerShared: Sendable {
  let mutex: Mutex<OAuthServer.State>
  init(_ value: OAuthServer.State) { mutex = Mutex(value) }
}
final class OAuthServer: Sendable {
  struct State {
    var plan: OAuthPlan
    var calls = 0
    var invalidRequests = 0
    var expectedVerifier: String? = oauthVerifier
    var expectedChallenge: String?
    var quotaAuthorization: (String, String)?
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
final class OAuthHandler: ChannelInboundHandler, @unchecked Sendable {
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
      case .replyAfterDelay(let data):
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: .milliseconds(500)) { [self] in
          reply(bound.value, data: data)
        }
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
    if let head, head.method == .GET {
      let expected = state.mutex.withLock { $0.quotaAuthorization }
      return head.uri == "/backend-api/wham/usage" && body.isEmpty
        && expected.map {
          head.headers["authorization"] == ["Bearer " + $0.0]
            && head.headers["chatgpt-account-id"] == [$0.1]
        } == true
        && head.headers["x-openai-codex-luna-reserve"].isEmpty
    }
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
struct OAuthHarness: Sendable {
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
func awaitOAuth(
  _ label: String = "owned-state", _ condition: @Sendable () async throws -> Bool
) async throws {
  for _ in 0..<600 {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Synthetic OAuth socket did not reach bounded state: \(label)")
  throw AccountRefreshError.unavailable
}
func withOAuth(timeout: Int = 1000, _ operation: (OAuthHarness) async throws -> Void)
  async throws
{
  let fixture = try await OAuthHarness.open(timeout: timeout)
  do { try await operation(fixture) } catch {
    await fixture.close()
    throw error
  }
  await fixture.close()
}
