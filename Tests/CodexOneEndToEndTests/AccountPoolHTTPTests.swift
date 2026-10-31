import CSQLite
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import Testing

@testable import CodexOneAdapters

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// Accept both ordinary subscription array input and the independent image/compact contracts.
private func poolInput(_ request: JSONValue) -> String? {
  request["prompt"]?.string ?? request["input"]?.string
    ?? request["input"]?.array?.first?["content"]?.string
}

private let poolImageBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQUDBgAAABBQBh3ab18QAAAABJRU5ErkJggg=="
private func poolImageOutput(_ request: JSONValue, count: Int) -> JSONValue {
  guard
    request["tools"]?.array?.contains(where: { $0["type"]?.string == "image_generation" }) == true
  else { return .array([]) }
  return .array([
    .object([
      "id": .string("ig_pool_\(count)"), "type": .string("image_generation_call"),
      "status": .string("completed"), "result": .string(poolImageBase64),
      "usage": .object(["input_tokens": .number(2), "output_tokens": .number(3)]),
    ])
  ])
}
private func poolRefusalEvents(_ input: String?, response: JSONValue) -> [JSONValue]? {
  guard let input, ["refuse-error", "refuse-failed", "output-error"].contains(input) else {
    return nil
  }
  let error = JSONValue.object([
    "code": .string("invalid_request_error"), "message": .string("Synthetic refusal"),
  ])
  let failure = JSONValue.object(["type": .string("error"), "error": error])
  if input == "refuse-error" { return [failure] }
  if input == "refuse-failed" {
    var document = response.object!
    document["status"] = .string("failed")
    document["error"] = error
    document.removeValue(forKey: "usage")
    return [.object(["type": .string("response.failed"), "response": .object(document)])]
  }
  return [
    .object(["type": .string("response.created"), "response": response]),
    .object(["type": .string("response.output_text.delta"), "delta": .string("synthetic")]),
    failure,
  ]
}

private final class PoolHTTPState: Sendable {
  struct Call: Sendable {
    let account: String
    let path: String
    let previous: String?
    var body: Data? = nil
    var headers: HTTPHeaders? = nil
  }
  struct State {
    var expected: [String: String] = [:]
    var calls: [Call] = []
    var invalid = 0
    var upgrades = 0
    var upgradeAccounts: [String] = []
    var upgradeHeaders: [HTTPHeaders] = []
    var channels: [ObjectIdentifier: any Channel] = [:]
  }
  let value = Mutex(State())
}
private final class SilentUpgradeHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  let state: PoolHTTPState
  var seen = false
  init(_ state: PoolHTTPState) { self.state = state }
  func channelActive(context: ChannelHandlerContext) {
    state.value.withLock { $0.channels[ObjectIdentifier(context.channel)] = context.channel }
    context.fireChannelActive()
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if !seen {
      seen = true
      state.value.withLock { $0.upgrades += 1 }
    }
  }
}
private final class PoolHTTPHandler: ChannelInboundHandler, RemovableChannelHandler,
  @unchecked Sendable
{
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let state: PoolHTTPState
  let rejection: Int?
  var head: HTTPRequestHead?
  var body = Data()
  init(_ state: PoolHTTPState, rejection: Int? = nil) {
    self.state = state
    self.rejection = rejection
  }
  func channelActive(context: ChannelHandlerContext) {
    state.value.withLock { $0.channels[ObjectIdentifier(context.channel)] = context.channel }
    context.fireChannelActive()
  }
  func channelInactive(context: ChannelHandlerContext) {
    _ = state.value.withLock { $0.channels.removeValue(forKey: ObjectIdentifier(context.channel)) }
    context.fireChannelInactive()
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      self.head = head
    case .body(let bytes): body.append(contentsOf: bytes.readableBytesView)
    case .end:
      if head?.method == .GET, let rejection {
        reject(context, status: rejection)
        return
      }
      do {
        let request = try JSONValue.decode(body)
        guard let head else { throw ExecutionError.invalidCommand }
        let account = head.headers.first(name: "chatgpt-account-id") ?? ""
        let count = state.value.withLock { value in
          if head.headers["authorization"]
            != (value.expected[account].map({ ["Bearer " + $0] }) ?? [])
            || head.headers["chatgpt-account-id"].count != 1
            || !head.headers["x-client-private"].isEmpty
          {
            value.invalid += 1
          }
          value.calls.append(
            .init(
              account: account, path: head.uri, previous: request["previous_response_id"]?.string,
              body: body, headers: head.headers))
          return value.calls.count
        }
        if let input = poolInput(request), input.hasPrefix("http"),
          let status = Int(input.dropFirst(4))
        {
          reject(context, status: status)
          return
        }
        if let input = poolInput(request), input.hasPrefix("truncated"),
          let status = Int(input.dropFirst(9))
        {
          reject(context, status: status, truncated: true)
          return
        }
        if poolInput(request) == "abort" {
          context.close(promise: nil)
          return
        }
        let compact = head.uri.hasSuffix("/compact")
        let nativeImage = head.uri.contains("/images/")
        let control = head.uri.hasPrefix("/backend-api/codex/alpha/search")
        if !compact && !nativeImage && !control
          && request["tools"]?.array?.contains(where: { $0["type"]?.string == "image_generation" })
            != true
        {
          guard request["stream"]?.bool == true, request["store"]?.bool == false,
            request["input"]?.array != nil, request["previous_response_id"] == nil
          else {
            throw ExecutionError.invalidCommand
          }
        }
        var document: [String: JSONValue] = [
          "id": .string("synthetic-response-\(count)"),
          "object": .string(compact ? "response.compaction" : "response"), "created_at": .number(1),
          "output": poolImageOutput(request, count: count),
          "usage": .object([
            "input_tokens": .number(2), "output_tokens": .number(1), "total_tokens": .number(3),
            "input_tokens_details": .object(["cached_tokens": .number(0)]),
          ]),
        ]
        if poolInput(request) == "partial" {
          document["usage"] = .object(["input_tokens": .number(2)])
        }
        if !compact {
          document["status"] = .string(
            poolInput(request) == "terminal-failed" ? "failed" : "completed")
          document["model"] = .string("synthetic-text")
        }
        if !compact, let previous = request["previous_response_id"] {
          document["previous_response_id"] = previous
        }
        if nativeImage {
          document = [
            "data": .array([.object(["b64_json": .string(poolImageBase64)])]),
            "usage": .object(["input_tokens": .number(2), "output_tokens": .number(3)]),
          ]
        }
        let stream = request["stream"]?.bool == true && !compact
        let bytes: Data
        if stream {
          let event = JSONValue.object([
            "type": .string("response." + (document["status"]?.string ?? "completed")),
            "response": .object(document),
          ])
          if let refusals = poolRefusalEvents(poolInput(request), response: .object(document)) {
            bytes = try refusals.reduce(into: Data()) { data, event in
              data.append(
                Data("data: \(String(decoding: try event.data(), as: UTF8.self))\n\n".utf8))
            }
          } else {
            bytes = Data(
              "event: response.completed\ndata: \(String(decoding: try event.data(), as: UTF8.self))\n\n"
                .utf8)
          }
        } else {
          bytes = try JSONValue.object(document).data()
        }
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let reply: @Sendable () -> Void = { [self] in
          let context = bound.value
          context.write(
            wrapOutboundOut(
              .head(
                .init(
                  version: .http1_1, status: .ok,
                  headers: [
                    "content-type": stream ? "text/event-stream" : "application/json",
                    "content-length": String(bytes.count), "connection": "close",
                  ]))), promise: nil)
          context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(data: bytes)))), promise: nil)
          context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            bound.value.close(promise: nil)
          }
        }
        if poolInput(request) == "hold" {
          _ = context.eventLoop.scheduleTask(in: .milliseconds(400), reply)
        } else {
          reply()
        }
      } catch { context.close(promise: nil) }
    }
  }
  private func reject(_ context: ChannelHandlerContext, status: Int, truncated: Bool = false) {
    let body = ByteBuffer(string: "{\"error\":\"synthetic-private-status-marker\"}")
    context.write(
      wrapOutboundOut(
        .head(
          .init(
            version: .http1_1, status: .init(statusCode: status),
            headers: [
              "content-type": "application/json",
              "content-length": String(body.readableBytes + (truncated ? 64 : 0)),
              "retry-after": "60", "connection": "close",
            ]))), promise: nil)
    let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
    if truncated {
      // Error status with a body cut short: the status alone must still classify the account.
      context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(body)))).whenComplete { _ in
        bound.value.close(promise: nil)
      }
      return
    }
    context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      bound.value.close(promise: nil)
    }
  }

}
private struct PoolHTTPHarness {
  let oauth: OAuthHarness
  let store: SQLiteExecutionStore
  let listener: any Channel
  let state: PoolHTTPState
  let finalizer: ExecutionFinalizer
  let owner: Task<Void, any Error>
  let port: Int
  let alice: String
  let bob: String
  var calls: [PoolHTTPState.Call] { state.value.withLock { $0.calls } }
  static func open(
    _ oauth: OAuthHarness, wrongMaster: Bool = false, transport: String = "http",
    executionTimeout: Int = 5, handshake: String? = nil, images: Bool = false
  )
    async throws -> Self
  {
    let state = PoolHTTPState()
    for id in ["a", "b"] {
      oauth.server.set(
        .reply(try oauthTokens(account: "synthetic-\(id)", subject: "synthetic-user-\(id)")))
      let login = try await oauth.login()
      var account = try await oauth.app.importVerified(
        id: id, namespace: login.namespace, credential: login.credential)
      account = try await oauth.store.setAccountMode(
        id: id, revision: account.revision, mode: .enabled)
      state.value.withLock { $0.expected["synthetic-\(id)"] = login.credential.accessToken }
    }
    let alice = "synthetic-alice-data-key-0001"
    let bob = "synthetic-bob-data-key-0000002"
    let limits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 100)
    for (id, token) in [("alice", alice), ("bob", bob)] {
      _ = try await oauth.store.createKey(
        id: id, principal: id, digest: keyDigest(token),
        policy: KeyPolicy(
          models: images && id == "alice" ? [] : ["synthetic-text"], limits: limits,
          visionInput: images, imageGeneration: images,
          imageModels: images ? ["synthetic-image"] : []))
    }
    let listener = try await ServerBootstrap(group: oauth.group).childChannelInitializer {
      channel in
      channel.closeFuture.whenComplete { _ in
        _ = state.value.withLock { $0.channels.removeValue(forKey: ObjectIdentifier(channel)) }
      }
      let http = PoolHTTPHandler(state, rejection: Int(handshake ?? ""))
      if handshake == "stall" {
        return channel.pipeline.addHandler(SilentUpgradeHandler(state))
      }
      if transport == "websocket" {
        let upgrader = NIOWebSocketServerUpgrader(
          maxFrameSize: 524_288,
          shouldUpgrade: { channel, head in
            let account = head.headers.first(name: "chatgpt-account-id") ?? ""
            state.value.withLock { value in
              value.upgrades += 1
              value.upgradeAccounts.append(account)
              value.upgradeHeaders.append(head.headers)
              if head.headers["authorization"]
                != (value.expected[account].map { ["Bearer " + $0] } ?? [])
                || !head.headers["x-client-private"].isEmpty
              {
                value.invalid += 1
              }
            }
            if Int(handshake ?? "") != nil { return channel.eventLoop.makeSucceededFuture(nil) }
            if handshake == "delay" {
              let scheduled = channel.eventLoop.scheduleTask(in: .milliseconds(700)) {
                Optional(HTTPHeaders())
              }
              channel.closeFuture.whenComplete { _ in scheduled.cancel() }
              return scheduled.futureResult
            }
            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
          },
          upgradePipelineHandler: { channel, head in
            channel.pipeline.removeHandler(http).flatMap {
              channel.pipeline.addHandler(
                PoolWebSocketHandler(
                  state, account: head.headers.first(name: "chatgpt-account-id") ?? ""))
            }
          })
        return channel.pipeline.configureHTTPServerPipeline(
          withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
        ).flatMap { channel.pipeline.addHandler(http) }
      }
      return channel.pipeline.configureHTTPServerPipeline().flatMap {
        channel.pipeline.addHandler(http)
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    let configuration = try JSONDecoder().decode(
      AccountPoolConfiguration.self,
      from: JSONSerialization.data(withJSONObject: [
        "models": [
          [
            "id": "synthetic-text", "visionInput": images, "imageGeneration": images,
            "inputMicrosPerMillion": 1_000_000,
            "outputMicrosPerMillion": 1_000_000,
          ]
        ],
        "reservedMicros": 1, "executionTimeoutSeconds": executionTimeout,
        "upstreamTransport": transport,
        "imageGeneration": images
          ? [
            "defaultModel": "synthetic-image",
            "models": [
              [
                "id": "synthetic-image", "hostModel": "synthetic-text", "sizePolicy": "fixed1536",
                "supportsTransparency": true, "supportsInputFidelity": true,
                "inputMicrosPerMillion": 1_000_000, "outputMicrosPerMillion": 1_000_000,
              ]
            ],
          ] : NSNull(),
      ]))
    let store: SQLiteExecutionStore
    if wrongMaster {
      await oauth.store.close()
      store = try await SQLiteExecutionStore.open(
        path: oauth.root.appendingPathComponent("core.sqlite").path, limits: limits)
    } else {
      store = oauth.store
    }
    let finalizer = try ExecutionFinalizer(store: store)
    let bound = Mutex(0)
    let credentials =
      wrongMaster
      ? AccountCredentials(
        store: store,
        protection: try AccountCredentialCipher(hexKey: String(repeating: "7b", count: 32)))
      : oauth.app
    let service = try ResponsesDataService(
      group: oauth.group, port: 0, configuration: configuration, store: store,
      finalizer: finalizer, credentials: credentials, refresher: oauth.supervisor,
      provider: oauth.provider, target: .syntheticLoopback(port: listener.localAddress!.port!)
    ) { port in bound.withLock { $0 = port } }
    let owner = Task {
      try await GatewayRuntime(services: [finalizer, service]).run(handleSignals: false)
    }
    try await awaitOAuth { bound.withLock { $0 > 0 } && finalizer.isAccepting }
    return Self(
      oauth: oauth, store: store, listener: listener, state: state, finalizer: finalizer,
      owner: owner,
      port: bound.withLock { $0 }, alice: alice, bob: bob)
  }
  func request(
    _ input: String = "text", stream: Bool = false, previous: String? = nil, key: String? = nil,
    compact: Bool = false
  ) async throws -> (Int, Data) {
    var body: [String: JSONValue] = ["model": .string("synthetic-text"), "input": .string(input)]
    if !compact { body["stream"] = .bool(stream) }
    if let previous { body["previous_response_id"] = .string(previous) }
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:\(port)/v1/responses" + (compact ? "/compact" : ""))!)
    request.httpMethod = "POST"
    request.httpBody = try JSONValue.object(body).data()
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("Bearer " + (key ?? alice), forHTTPHeaderField: "authorization")
    request.setValue("synthetic-client-header", forHTTPHeaderField: "x-client-private")
    request.setValue("forged-downstream-account", forHTTPHeaderField: "chatgpt-account-id")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    return ((response as! HTTPURLResponse).statusCode, data)
  }
  func readiness() async throws -> (Int, Data) {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (body, response) = try await session.data(
      from: URL(string: "http://127.0.0.1:\(port)/health/ready")!)
    return ((response as! HTTPURLResponse).statusCode, body)
  }
  func close() async {
    owner.cancel()
    _ = await owner.result
    if store !== oauth.store { await store.close() }
    for channel in state.value.withLock({ Array($0.channels.values) }) {
      try? await channel.close().get()
    }
    try? await listener.close().get()
  }
}
private func withPoolHTTP(
  transport: String = "http", _ operation: (PoolHTTPHarness) async throws -> Void
) async throws {
  try await withOAuth(timeout: 3000) { oauth in
    let harness = try await PoolHTTPHarness.open(oauth, transport: transport)
    do { try await operation(harness) } catch {
      await harness.close()
      throw error
    }
    await harness.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPRoutesJSONSSEAndCompactWithPrincipalAffinityAndPrivateHeaders() async throws {
  try await withPoolHTTP { h in
    let first = try await h.request()
    #expect(first.0 == 200)
    let id = try #require(JSONValue.decode(first.1)["id"]?.string)
    let firstAccount = try #require(h.calls.first?.account)
    let stream = try await h.request(stream: true)
    #expect(
      stream.0 == 200 && String(decoding: stream.1, as: UTF8.self).contains("response.completed"))
    let beforeRejected = h.calls.count
    #expect(try await h.request(previous: id).0 == 400)
    #expect(h.calls.count == beforeRejected)
    let compact = try await h.request(previous: id, compact: true)
    #expect(compact.0 == 200)
    #expect(h.calls.last?.account == firstAccount)
    #expect(try JSONValue.decode(compact.1)["object"]?.string == "response.compaction")
    let before = h.calls.count
    let foreign = try await h.request(previous: id, key: h.bob)
    #expect(foreign.0 != 200)
    #expect(h.calls.count == before)
    let unknown = try await h.request(previous: "unknown-response")
    #expect(unknown.0 != 200 && h.calls.count == before)
    #expect(h.state.value.withLock { $0.invalid } == 0)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let settled = try await h.oauth.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='settled'")
    }
    #expect(settled == 3)
  }
}

@Test(.timeLimit(.minutes(1))) func poolHTTPConcurrentSelectionAndAbortNeverReplayAcrossAccounts()
  async throws
{
  try await withPoolHTTP { h in
    let first = Task { try await h.request("hold") }
    try await awaitOAuth { h.calls.count == 1 }
    let second = try await h.request()
    #expect(second.0 == 200)
    #expect(try await first.value.0 == 200)
    #expect(h.calls[0].account != h.calls[1].account)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let before = h.calls.count
    let failed = try await h.request("abort")
    #expect(failed.0 == 502)
    #expect(h.calls.count == before + 1)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let unknown = try await h.oauth.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
    }
    #expect(unknown == 1)
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPDisableAndKeyRevocationRefuseContinuationWithoutSwitching() async throws {
  try await withPoolHTTP { h in
    let first = try await h.request()
    let id = try #require(JSONValue.decode(first.1)["id"]?.string)
    let selected = try #require(h.calls.first?.account)
    let accountID = String(selected.dropFirst("synthetic-".count))
    let account = try await h.oauth.store.accountCredential(id: accountID).account
    _ = try await h.oauth.store.setAccountMode(
      id: account.id, revision: account.revision, mode: .disabled)
    let before = h.calls.count
    #expect(try await h.request(previous: id, compact: true).0 == 503)
    #expect(h.calls.count == before)
    #expect(try await h.request().0 == 200)
    #expect(h.calls.last?.account != selected)
    let key = try await h.oauth.store.authenticateKey(digest: keyDigest(h.alice))
    _ = try await h.oauth.store.updateKey(
      id: key.id, revision: key.revision, enabled: false, policy: key.policy)
    let count = h.calls.count
    #expect(try await h.request().0 == 401)
    #expect(h.calls.count == count)
  }
}

@Test(.timeLimit(.minutes(1))) func poolHTTPRefreshesPinnedAccountThroughRealOAuthSocket()
  async throws
{
  try await withPoolHTTP { h in
    let first = try await h.request()
    let id = try #require(JSONValue.decode(first.1)["id"]?.string)
    let selected = try #require(h.calls.first?.account)
    let accountID = String(selected.dropFirst("synthetic-".count))
    let account = try await h.oauth.store.accountCredential(id: accountID).account
    let work = try await h.oauth.app.prepareDispatch(id: accountID, continuation: true)
    _ = try await h.oauth.app.reauthorizeVerified(
      id: account.id, revision: account.revision, namespace: account.namespace,
      credential: AccountCredential(
        accessToken: work.credential.accessToken, refreshToken: work.credential.refreshToken,
        idToken: work.credential.idToken, expiresAtUnixSeconds: 1))
    let tokens = try oauthTokens(
      account: selected, subject: "synthetic-user-\(accountID)",
      accessExpiry: Int64(Date().timeIntervalSince1970) + 7200)
    let response = try #require(JSONSerialization.jsonObject(with: tokens) as? [String: Any])
    let token = try #require(response["access_token"] as? String)
    h.state.value.withLock { $0.expected[selected] = token }
    h.oauth.server.set(.reply(tokens))
    let continued = try await h.request(previous: id, compact: true)
    #expect(continued.0 == 200)
    #expect(h.calls.count == 2 && h.calls.last?.account == selected)
    #expect(h.oauth.server.counts.calls == 3 && h.oauth.server.counts.invalid == 0)
    #expect(h.state.value.withLock { $0.invalid } == 0)
    #expect(
      try await h.oauth.store.accountCredential(id: accountID).account.credentialVersion == 3)
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPDownstreamCancellationReleasesExecutionAndLeavesUnknown() async throws {
  try await withPoolHTTP { h in
    let request = Task { try await h.request("hold") }
    try await awaitOAuth { h.calls.count == 1 }
    request.cancel()
    _ = await request.result
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let unknown = try await h.oauth.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
    }
    #expect(unknown == 1)
    #expect(h.calls.count == 1)
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPPartialUsageRemainsUnknownWithoutDroppingObservedCosts()
  async throws
{
  try await withPoolHTTP { h in
    let response = try await h.request("partial", stream: true)
    #expect(response.0 == 200)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let unknown = try await h.oauth.store.perform { db in
      try db.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown' AND estimated=2")
    }
    #expect(unknown == 1 && h.calls.count == 1)
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPReadinessRejectsWrongMasterAndCorruptCiphertextWithoutChangingState() async throws {
  try await withOAuth { oauth in
    let h = try await PoolHTTPHarness.open(oauth, wrongMaster: true)
    do {
      #expect(try await h.readiness().0 == 503)
      #expect(try await h.request().0 == 503)
      #expect(h.calls.isEmpty && oauth.server.counts.calls == 2)
      #expect(try await h.store.listAccounts().allSatisfy { $0.authorization == .ready })
    } catch {
      await h.close()
      throw error
    }
    await h.close()
  }
  try await withPoolHTTP { h in
    #expect(try await h.readiness().0 == 200)
    for id in ["a", "b"] {
      let stored = try await h.oauth.store.accountCredential(id: id)
      let parts = stored.envelope.split(separator: ".")
      var combined = try #require(Data(base64Encoded: String(parts[2])))
      combined[0] ^= 1
      let tampered = parts[0] + "." + parts[1] + "." + combined.base64EncodedString()
      try await h.oauth.store.perform {
        try $0.write(
          "UPDATE accounts SET sealed_credential=? WHERE id=?", [.text(tampered), .text(id)])
      }
      #expect(try await h.readiness().0 == (id == "a" ? 200 : 503))
      #expect(try await h.request().0 == (id == "a" ? 200 : 503))
    }
    #expect(h.calls.count == 1 && h.calls[0].account == "synthetic-b")
    #expect(h.oauth.server.counts.calls == 2)
    #expect(try await h.oauth.store.listAccounts().allSatisfy { $0.authorization == .ready })
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPReadinessAllowsDecryptableExpiredCredentialsForOwnedRefresh() async throws {
  try await withPoolHTTP { h in
    for account in try await h.oauth.store.listAccounts() {
      let work = try await h.oauth.app.prepareDispatch(id: account.id, continuation: false)
      _ = try await h.oauth.app.reauthorizeVerified(
        id: account.id, revision: account.revision, namespace: account.namespace,
        credential: AccountCredential(
          accessToken: work.credential.accessToken, refreshToken: work.credential.refreshToken,
          idToken: work.credential.idToken, expiresAtUnixSeconds: 1))
    }
    #expect(try await h.readiness().0 == 200)
    #expect(h.calls.isEmpty && h.oauth.server.counts.calls == 2)
  }
}

private final class PoolWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  let state: PoolHTTPState
  let account: String
  private var pending: [String: (JSONValue, String)] = [:]
  private var recent: String?
  init(_ state: PoolHTTPState, account: String) {
    self.state = state
    self.account = account
  }
  func handlerAdded(context: ChannelHandlerContext) {
    state.value.withLock { $0.channels[ObjectIdentifier(context.channel)] = context.channel }
  }
  func channelInactive(context: ChannelHandlerContext) {
    _ = state.value.withLock { $0.channels.removeValue(forKey: ObjectIdentifier(context.channel)) }
    context.fireChannelInactive()
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    guard frame.opcode == .text else {
      if frame.opcode == .ping {
        context.writeAndFlush(
          wrapOutboundOut(.init(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
      } else {
        context.close(promise: nil)
      }
      return
    }
    do {
      let request = try JSONValue.decode(Data(frame.unmaskedData.readableBytesView))
      func emit(_ event: JSONValue) throws {
        context.writeAndFlush(
          wrapOutboundOut(
            .init(fin: true, opcode: .text, data: ByteBuffer(data: try event.data()))),
          promise: nil)
      }
      if request["type"]?.string == "response.interrupt" {
        let id = request["response_id"]!.string!
        guard let (completed, prompt) = pending.removeValue(forKey: id) else {
          throw ExecutionError.invalidCommand
        }
        let ack = JSONValue.object([
          "type": .string("response.interrupt.accepted"), "response_id": .string(id),
        ])
        for event in prompt == "cancel-after" ? [completed, ack] : [ack, completed] {
          try emit(event)
        }
        return
      }
      if request["type"]?.string == "synthetic.spawn" {
        try emit(
          .object([
            "type": .string("response.created"),
            "response": .object([
              "id": .string("synthetic-unadmitted"), "status": .string("in_progress"),
              "output": .array([]),
            ]),
          ]))
        return
      }
      if request["type"]?.string == "synthetic.future" {
        try emit(
          .object([
            "type": .string("synthetic.echo"), "response_id": .string(recent!),
            "payload": request["payload"]!,
          ]))
        return
      }
      guard request["type"]?.string == "response.create" else {
        throw ExecutionError.invalidCommand
      }
      let count = state.value.withLock { value in
        value.calls.append(
          .init(
            account: account, path: "/backend-api/codex/responses",
            previous: request["previous_response_id"]?.string))
        return value.calls.count
      }
      if poolInput(request) == "abort" {
        context.close(promise: nil)
        return
      }
      if poolInput(request) == "stallbody" { return }
      var document: [String: JSONValue] = [
        "id": .string("synthetic-ws-\(count)"), "object": .string("response"),
        "model": .string("synthetic-text"), "status": .string("in_progress"), "output": .array([]),
      ]
      if let previous = request["previous_response_id"] {
        document["previous_response_id"] = previous
      }
      var created: [String: JSONValue] = [
        "type": .string("response.created"), "response": .object(document),
      ]
      document["status"] = .string(
        poolInput(request) == "terminal-failed" ? "failed" : "completed")
      document["output"] = poolImageOutput(request, count: count)
      document["usage"] = .object([
        "input_tokens": .number(2), "output_tokens": .number(1),
        "input_tokens_details": .object(["cached_tokens": .number(0)]),
      ])
      var completed: [String: JSONValue] = [
        "type": .string("response." + (document["status"]?.string ?? "completed")),
        "response": .object(document),
      ]
      if let lane = request["stream_id"] {
        created["stream_id"] = lane
        completed["stream_id"] = lane
      }
      recent = document["id"]?.string
      if let prompt = poolInput(request),
        ["cancel-before", "cancel-after", "drain"].contains(prompt)
      {
        pending[recent!] = (.object(completed), prompt)
        try emit(.object(created))
        return
      }
      let wire =
        poolRefusalEvents(poolInput(request), response: .object(document))
        ?? [JSONValue.object(created), JSONValue.object(completed)]
      let bytes = try wire.map { try $0.data() }
      let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
      let send: @Sendable () -> Void = { [self] in
        for data in bytes {
          bound.value.writeAndFlush(
            wrapOutboundOut(.init(fin: true, opcode: .text, data: ByteBuffer(data: data))),
            promise: nil)
        }
      }
      if poolInput(request) == "hold" {
        _ = context.eventLoop.scheduleTask(in: .milliseconds(400), send)
      } else {
        send()
      }
    } catch { context.close(promise: nil) }
  }
}

@Test(.timeLimit(.minutes(1))) func poolHTTPWebSocketBridgeUsesSelectedAccountForJSONSSEAndCompact()
  async throws
{
  try await withPoolHTTP(transport: "websocket") { h in
    let first = try await h.request()
    #expect(first.0 == 200)
    let id = try #require(JSONValue.decode(first.1)["id"]?.string)
    _ = try #require(h.calls.first?.account)
    let continued = try await h.request(stream: true)
    #expect(continued.0 == 200 && h.calls.count == 2)
    #expect(String(decoding: continued.1, as: UTF8.self).contains("response.completed"))
    let before = h.calls.count
    #expect(try await h.request(previous: id, key: h.bob).0 == 400)
    #expect(h.calls.count == before)
    #expect(try await h.request(compact: true).0 == 200)
    #expect(h.state.value.withLock { $0.invalid } == 0)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let settled = try await h.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='settled'")
    }
    #expect(settled == 3)
  }
}

@Test(.timeLimit(.minutes(1))) func poolHTTPWebSocketBridgeBalancesInflightAndNeverReplaysAnAbort()
  async throws
{
  try await withPoolHTTP(transport: "websocket") { h in
    let first = Task { try await h.request("hold") }
    try await awaitOAuth { h.calls.count == 1 }
    #expect(try await h.request().0 == 200)
    #expect(try await first.value.0 == 200)
    #expect(h.calls[0].account != h.calls[1].account)
    let count = h.calls.count
    #expect(try await h.request("abort").0 == 502)
    #expect(h.calls.count == count + 1)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let unknown = try await h.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
    }
    #expect(unknown == 1)
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPWebSocketBridgeDeadlineIncludesHandshakeAndBodyWithoutReconnecting() async throws {
  for handshake in ["stall", "delay"] {
    try await withOAuth(timeout: 3000) { oauth in
      let h = try await PoolHTTPHarness.open(
        oauth, transport: "websocket", executionTimeout: 1, handshake: handshake)
      do {
        let started = ContinuousClock.now
        let result = try await h.request("hold")
        #expect(result.0 == 504)
        #expect(
          try JSONValue.decode(result.1)["error"]?["code"]?.string == "execution_deadline_exceeded")
        #expect(started.duration(to: .now) < .milliseconds(2500))
        try await awaitOAuth(handshake + "-released") {
          h.finalizer.outstanding == 0 && h.state.value.withLock { $0.channels.isEmpty }
        }
        #expect(h.state.value.withLock { $0.upgrades } == 1)
        #expect(h.calls.count == (handshake == "stall" ? 0 : 1))
        let unknown = try await h.store.perform {
          try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
        }
        let total = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
        #expect(unknown == 1 && total == 1)
      } catch {
        await h.close()
        throw error
      }
      await h.close()
    }
  }
}

/// Each command is one bounded line to an independent RFC6455 client. Blocking pipe
/// reads live on Dispatch, never on Swift's cooperative executor.
private final class PoolWSClient: @unchecked Sendable {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  private let closed = Mutex(false)
  private let exited = DispatchSemaphore(value: 0)
  init(_ h: PoolHTTPHarness, key: String? = nil) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "python3", "scripts/verify_pool_ws_client.py", String(h.port), key ?? h.alice,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [exited] _ in exited.signal() }
    try process.run()
  }
  func read() async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { [self] in
        do {
          var data = Data()
          while data.count < 4096 {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty
            else {
              throw ExecutionError.closed
            }
            if byte == Data([10]) {
              continuation.resume(returning: try JSONValue.decode(data))
              return
            }
            data.append(byte)
          }
          throw ExecutionError.capacity
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  func command(_ value: [String: JSONValue] = [:]) async throws -> JSONValue {
    var data = try JSONValue.object(value).data()
    data.append(10)
    try input.fileHandleForWriting.write(contentsOf: data)
    return try await read()
  }
  func close() {
    guard
      closed.withLock({ value in
        if value { return false }
        value = true
        return true
      })
    else { return }
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
    #expect(exited.wait(timeout: .now() + 6) == .success)
    try? output.fileHandleForReading.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketPinsAllLanesAndFinalizesEachTurnWhileConnectionLives() async throws {
  try await withPoolHTTP(transport: "websocket") { h in
    let client = try PoolWSClient(h)
    defer { client.close() }
    #expect(try await client.read()["ready"]?.bool == true)
    let warmup = try await client.command(["generate": .bool(false)])
    let id = try #require(warmup["response"]?["id"]?.string)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    #expect(h.state.value.withLock { $0.channels.count } == 1)
    #expect(
      try await client.command(["previous_response_id": .string(id)])["type"]?.string
        == "response.completed")
    #expect(try await client.command(["op": .string("multi")])["lanes"]?.integer == 2)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    #expect(h.calls.count == 4 && Set(h.calls.map(\.account)).count == 1)
    #expect(h.state.value.withLock { $0.upgrades == 1 && $0.invalid == 0 })
    let total = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
    #expect(total == 4)
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketRechecksAccountAndKeyBetweenTurnsWithoutReconnecting() async throws {
  for mutation in ["disabled", "draining", "key"] {
    try await withPoolHTTP(transport: "websocket") { h in
      let client = try PoolWSClient(h)
      defer { client.close() }
      _ = try await client.read()
      let first = try await client.command()
      let id = try #require(first["response"]?["id"]?.string)
      try await awaitOAuth { h.finalizer.outstanding == 0 }
      let selected = try #require(h.calls.first?.account).replacingOccurrences(
        of: "synthetic-", with: "")
      let account = try #require(try await h.store.listAccounts().first { $0.id == selected })
      if mutation == "key" {
        let key = try #require(try await h.store.listKeys(after: nil).first { $0.id == "alice" })
        _ = try await h.store.updateKey(
          id: key.id, revision: key.revision, enabled: false, policy: key.policy)
      } else {
        _ = try await h.store.setAccountMode(
          id: account.id, revision: account.revision,
          mode: mutation == "draining" ? .draining : .disabled)
      }
      if mutation == "draining" {
        #expect(
          try await client.command(["previous_response_id": .string(id)])["type"]?.string
            == "response.completed")
      }
      if mutation == "draining" {
        #expect(try await client.command()["type"]?.string == "response.completed")
        let drained = try #require(try await h.store.listAccounts().first { $0.id == selected })
        _ = try await h.store.setAccountMode(
          id: drained.id, revision: drained.revision, mode: .disabled)
      }
      let result = try await client.command()
      #expect(result["type"]?.string == "error")
      try await awaitOAuth {
        h.finalizer.outstanding == 0 && h.state.value.withLock { $0.channels.isEmpty }
      }
      #expect(h.calls.count == (mutation == "draining" ? 3 : 1))
      #expect(h.state.value.withLock { $0.upgrades } == 1)
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketRejectsCrossPrincipalAndCrossAccountReferencesBeforeDispatch() async throws
{
  try await withPoolHTTP(transport: "websocket") { h in
    let original = try PoolWSClient(h)
    defer { original.close() }
    _ = try await original.read()
    let first = try await original.command()
    let id = try #require(first["response"]?["id"]?.string)
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let accountName = try #require(h.calls.first?.account)
    let other = try #require(
      try await h.store.listAccounts().first { "synthetic-" + $0.id != accountName })
    _ = try await h.store.setAccountMode(id: other.id, revision: other.revision, mode: .disabled)
    let foreign = try PoolWSClient(h, key: h.bob)
    defer { foreign.close() }
    _ = try await foreign.read()
    #expect(
      try await foreign.command(["previous_response_id": .string(id)])["type"]?.string == "error")
    #expect(h.calls.count == 1 && h.state.value.withLock { $0.upgrades } == 1)
    _ = try await h.store.setAccountMode(id: other.id, revision: other.revision + 1, mode: .enabled)
    // An independent in-flight turn occupies the original identity, so the HTTP
    // request balances to the other account and creates an incompatible reference.
    _ = try await original.command(["op": .string("send"), "input": .string("hold")])
    try await awaitOAuth { h.calls.count == 2 }
    let independent = try await h.request()
    let otherID = try #require(JSONValue.decode(independent.1)["id"]?.string)
    #expect(h.calls.last?.account != accountName)
    _ = try await original.command(["op": .string("receive")])
    _ = try await original.command(["op": .string("receive")])
    #expect(
      try await original.command(["previous_response_id": .string(otherID)])["type"]?.string
        == "error")
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    #expect(h.calls.count == 3 && h.state.value.withLock { $0.upgrades } == 2)
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketAbortAndHandshakeDeadlineLeaveOneUnknownAndNoOwner() async throws {
  for handshake in ["abort", "stall", "delay"] {
    try await withOAuth(timeout: 3000) { oauth in
      let h = try await PoolHTTPHarness.open(
        oauth, transport: "websocket", executionTimeout: 1,
        handshake: handshake == "abort" ? nil : handshake)
      do {
        let client = try PoolWSClient(h)
        defer { client.close() }
        _ = try await client.read()
        let started = ContinuousClock.now
        let result = try await client.command([
          "input": .string(handshake == "abort" ? "abort" : "hold")
        ])
        #expect(result["type"]?.string == "error")
        if handshake != "abort" {
          #expect(result["error"]?["code"]?.string == "execution_deadline_exceeded")
          #expect(started.duration(to: .now) < .milliseconds(2500))
        }
        try await awaitOAuth {
          h.finalizer.outstanding == 0 && h.state.value.withLock { $0.channels.isEmpty }
        }
        #expect(h.state.value.withLock { $0.upgrades } == 1)
        #expect(h.calls.count == (handshake == "stall" ? 0 : 1))
        let unknown = try await h.store.perform {
          try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
        }
        let total = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
        #expect(unknown == 1 && total == 1)
      } catch {
        await h.close()
        throw error
      }
      await h.close()
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketDisconnectAndRuntimeCancellationCloseOwnedHandshakeAndTurn() async throws {
  for handshake in [true, false] {
    for shutdown in [true, false] {
      try await withOAuth(timeout: 3000) { oauth in
        let h = try await PoolHTTPHarness.open(
          oauth, transport: "websocket", executionTimeout: 1,
          handshake: handshake ? "stall" : nil)
        do {
          let client = try PoolWSClient(h)
          defer { client.close() }
          _ = try await client.read()
          _ = try await client.command(["op": .string("send"), "input": .string("stallbody")])
          try await awaitOAuth {
            h.state.value.withLock { $0.upgrades == 1 && (handshake || $0.calls.count == 1) }
          }
          if shutdown {
            h.owner.cancel()
            _ = await h.owner.result
          } else {
            client.close()
          }
          try await awaitOAuth {
            h.finalizer.outstanding == 0 && h.state.value.withLock { $0.channels.isEmpty }
          }
          let ledger: SQLiteExecutionStore
          if shutdown {
            // Forced parent cancellation may stop the finalizer before its write.
            // Prove the durable intent becomes unknown on a real cold reopen.
            await h.store.close()
            ledger = try await SQLiteExecutionStore.open(
              path: oauth.root.appendingPathComponent("core.sqlite").path, limits: h.store.limits)
          } else {
            ledger = h.store
          }
          let unknown = try await ledger.perform {
            try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
          }
          if shutdown { await ledger.close() }
          #expect(unknown == 1 && h.state.value.withLock { $0.upgrades } == 1)
        } catch {
          await h.close()
          throw error
        }
        await h.close()
      }
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketRefreshesPinnedIdentityWithoutOpeningAnotherSession() async throws {
  try await withPoolHTTP(transport: "websocket") { h in
    let client = try PoolWSClient(h)
    defer { client.close() }
    _ = try await client.read()
    _ = try await client.command()
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let selected = try #require(h.calls.first?.account).replacingOccurrences(
      of: "synthetic-", with: "")
    let work = try await h.oauth.app.prepareDispatch(id: selected, continuation: true)
    _ = try await h.oauth.app.reauthorizeVerified(
      id: selected, revision: work.account.revision, namespace: work.account.namespace,
      credential: AccountCredential(
        accessToken: work.credential.accessToken, refreshToken: work.credential.refreshToken,
        idToken: work.credential.idToken, expiresAtUnixSeconds: 1))
    h.oauth.server.set(
      .reply(
        try oauthTokens(
          account: "synthetic-" + selected, subject: "synthetic-user-" + selected)))
    #expect(try await client.command()["type"]?.string == "response.completed")
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    #expect(h.oauth.server.counts.calls == 3)
    #expect(h.calls.count == 2 && Set(h.calls.map(\.account)).count == 1)
    #expect(h.state.value.withLock { $0.upgrades == 1 && $0.invalid == 0 })
  }
}

@Test(.timeLimit(.minutes(1)))
func poolHTTPExplicitProviderStatusesPersistHealthAndStopNewDispatchWithoutReplaying() async throws
{
  for status in [401, 429, 503, 400] {
    try await withPoolHTTP { h in
      let response = try await h.request("http\(status)")
      // Actionable provider statuses reach the client; the gateway credential failure does not.
      #expect(response.0 == (status == 401 ? 502 : status))
      try await awaitOAuth { h.finalizer.outstanding == 0 }
      let selected = try #require(h.calls.first?.account).replacingOccurrences(
        of: "synthetic-", with: "")
      let health = try await h.store.accountHealth(id: selected)
      #expect(health.authenticationRejected == (status == 401))
      #expect(health.cooldowns.count == ([429, 503].contains(status) ? 1 : 0))
      let other = try #require(try await h.store.listAccounts().first { $0.id != selected })
      _ = try await h.store.setAccountMode(id: other.id, revision: other.revision, mode: .disabled)
      #expect(try await h.readiness().0 == (status == 400 ? 200 : 503))
      #expect(try await h.request().0 == (status == 400 ? 200 : 503))
      #expect(h.calls.count == (status == 400 ? 2 : 1))
      let unknown = try await h.store.perform {
        try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
      }
      #expect(unknown == (status >= 500 ? 1 : 0))
      for file in try FileManager.default.contentsOfDirectory(
        at: h.oauth.root, includingPropertiesForKeys: nil)
      where file.lastPathComponent.hasPrefix("core.sqlite") {
        #expect(
          try Data(contentsOf: file, options: .mappedIfSafe).range(
            of: Data("synthetic-private-status-marker".utf8)) == nil)
      }
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolWebSocketUpgradeRejectionsClassifyHealthBeforeAnyCreateAndNeverReconnect() async throws {
  for native in [false, true] {
    for status in [400, 403, 401, 429, 503] {
      try await withOAuth(timeout: 3000) { oauth in
        let h = try await PoolHTTPHarness.open(
          oauth, transport: "websocket", handshake: String(status))
        do {
          if native {
            let client = try PoolWSClient(h)
            defer { client.close() }
            _ = try await client.read()
            #expect(try await client.command()["type"]?.string == "error")
          } else {
            #expect(try await h.request().0 == (status == 429 ? 429 : 502))
          }
          try await awaitOAuth { h.finalizer.outstanding == 0 }
          let selected = try #require(h.state.value.withLock { $0.upgradeAccounts.first })
            .replacingOccurrences(of: "synthetic-", with: "")
          let health = try await h.store.accountHealth(id: selected)
          #expect(health.authenticationRejected == (status == 401))
          #expect(health.cooldowns.count == ([429, 503].contains(status) ? 1 : 0))
          let other = try #require(try await h.store.listAccounts().first { $0.id != selected })
          _ = try await h.store.setAccountMode(
            id: other.id, revision: other.revision, mode: .disabled)
          if [400, 403].contains(status) {
            #expect(try await h.readiness().0 == 200)
          } else {
            #expect(try await h.readiness().0 == 503)
            #expect(try await h.request().0 == 503)
          }
          if status < 500 { try await assertPoolRefusalSettled(h) }
          #expect(h.calls.isEmpty && h.state.value.withLock { $0.upgrades } == 1)
          let unknown = try await h.store.perform {
            try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
          }
          #expect(unknown == (status >= 500 ? 1 : 0))
        } catch {
          await h.close()
          throw error
        }
        await h.close()
      }
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolUsageAutomaticallyCollectsHTTPModesFailuresAndPreAdmissionRejectionsWithoutDoubleCounting()
  async throws
{
  try await withPoolHTTP { h in
    let reader = try await h.store.makeUsageReader()
    do {
      let first = try await h.request()
      let id = try #require(JSONValue.decode(first.1)["id"]?.string)
      #expect(first.0 == 200)
      #expect(try await h.request(stream: true).0 == 200)
      #expect(try await h.request(compact: true).0 == 200)
      #expect(try await h.request("terminal-failed").0 == 200)
      #expect(try await h.request("abort").0 == 502)
      let before = h.calls.count
      #expect(try await h.request(previous: id, key: h.bob).0 != 200)
      #expect(try await h.request(previous: "synthetic-missing").0 != 200)
      #expect(try await h.request(key: "synthetic-unauthorized-key").0 == 401)
      #expect(h.calls.count == before)
      try await awaitOAuth { h.finalizer.outstanding == 0 }
      let hour = Int64(Date().timeIntervalSince1970) / 3600 * 3600
      let report = try await reader.queryUsage(
        .init(startUnixSeconds: hour, endUnixSeconds: hour + 3600))
      #expect(report.totals.admitted == 5 && report.totals.rejected == 2)
      #expect(report.totals.complete == 4 && report.totals.unavailable == 1)
      #expect(report.totals.failed == 2 && report.totals.unknown == 1)
      #expect(report.totals.metrics.inputTokens == 8 && report.totals.metrics.outputTokens == 4)
      #expect(report.rows.filter { $0.kind == .admitted && $0.mode == .compact }.count == 1)
      #expect(report.rows.filter { $0.failure == .upstreamRejected }.count == 1)
      #expect(report.rows.filter { $0.kind == .rejected && $0.keyID == "bob" }.count == 1)
      #expect(report.rows.filter { $0.kind == .rejected && $0.keyID == "alice" }.count == 1)
      #expect(report.rows.allSatisfy { $0.requestID != nil })
      #expect(try await h.store.accountHealth(id: "a").cooldowns.isEmpty)
      #expect(try await h.store.accountHealth(id: "b").cooldowns.isEmpty)
    } catch {
      await reader.close()
      throw error
    }
    await reader.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func poolUsageCollectsNativeWarmupAndFailedTerminalAcrossNativeAndBridgedWebSockets() async throws {
  try await withPoolHTTP(transport: "websocket") { h in
    let reader = try await h.store.makeUsageReader()
    let client = try PoolWSClient(h)
    defer { client.close() }
    do {
      #expect(try await client.read()["ready"]?.bool == true)
      #expect(
        try await client.command(["generate": .bool(false)])["type"]?.string == "response.completed"
      )
      #expect(
        try await client.command(["input": .string("terminal-failed")])["type"]?.string
          == "response.failed")
      #expect(try await h.request("terminal-failed", stream: true).0 == 200)
      try await awaitOAuth { h.finalizer.outstanding == 0 }
      let hour = Int64(Date().timeIntervalSince1970) / 3600 * 3600
      let report = try await reader.queryUsage(
        .init(startUnixSeconds: hour, endUnixSeconds: hour + 3600))
      #expect(
        report.totals.admitted == 3 && report.totals.failed == 2 && report.totals.complete == 3)
      #expect(report.rows.filter { $0.mode == .warmup }.count == 1)
      #expect(report.totals.metrics.inputTokens == 6 && report.totals.rejected == 0)
      #expect(try await h.store.accountHealth(id: "a").cooldowns.isEmpty)
      #expect(try await h.store.accountHealth(id: "b").cooldowns.isEmpty)
    } catch {
      await reader.close()
      throw error
    }
    await reader.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func poolImagesUseOneIntentAndOwnedAccountAcrossHTTPBridgeAndNativeTurns() async throws {
  for transport in ["http", "websocket"] {
    try await withOAuth(timeout: 3000) { oauth in
      let h = try await PoolHTTPHarness.open(oauth, transport: transport, images: true)
      do {
        func post(_ path: String, _ body: JSONValue, key: String? = nil) async throws -> (
          Int, JSONValue
        ) {
          var request = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/v1/" + path)!)
          request.httpMethod = "POST"
          request.httpBody = try body.data()
          request.setValue("application/json", forHTTPHeaderField: "content-type")
          request.setValue("Bearer " + (key ?? h.alice), forHTTPHeaderField: "authorization")
          let session = URLSession(configuration: .ephemeral)
          defer { session.invalidateAndCancel() }
          let (data, response) = try await session.data(for: request)
          return ((response as! HTTPURLResponse).statusCode, try JSONValue.decode(data))
        }
        for prefix in ["/v1", "/backend-api/codex"] {
          for operation in ["generations", "edits"] {
            var request = URLRequest(
              url: URL(string: "http://127.0.0.1:\(h.port)" + prefix + "/images/" + operation)!)
            request.httpMethod = "POST"
            request.httpBody = Data(
              #"{ "model":"synthetic-image", "prompt":"synthetic", "future":42 }"#.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer " + h.alice, forHTTPHeaderField: "authorization")
            request.setValue("synthetic-turn", forHTTPHeaderField: "x-codex-image-turn-id")
            request.setValue("synthetic-desktop", forHTTPHeaderField: "originator")
            request.setValue("forged-downstream-account", forHTTPHeaderField: "chatgpt-account-id")
            request.setValue("synthetic-client-header", forHTTPHeaderField: "x-client-private")
            // Desktop custom-provider configs send this only to unlock the local image tool.
            request.setValue("synthetic-gate", forHTTPHeaderField: "x-openai-actor-authorization")
            let session = URLSession(configuration: .ephemeral)
            let (_, response) = try await session.data(for: request)
            session.invalidateAndCancel()
            #expect((response as! HTTPURLResponse).statusCode == 200)
            #expect(h.calls.last?.path == "/backend-api/codex/images/" + operation)
            #expect(h.calls.last?.body == request.httpBody)
            #expect(h.calls.last?.headers?.first(name: "x-codex-image-turn-id") == "synthetic-turn")
            #expect(h.calls.last?.headers?.first(name: "originator") == "codex_cli_rs")
            for name in ["x-openai-actor-authorization", "x-client-private"] {
              #expect(h.calls.last?.headers?[name].isEmpty == true)
            }
            #expect(
              h.calls.last?.headers?["chatgpt-account-id"].contains("forged-downstream-account")
                == false)
          }
        }
        let generated = try await post(
          "images/generations", .object(["prompt": .string("synthetic pool image")]))
        #expect(
          generated.0 == 200
            && generated.1["data"]?.array?.first?["b64_json"]?.string == poolImageBase64)
        try await awaitOAuth { h.finalizer.outstanding == 0 }
        let imagesOnly = try await post(
          "responses", .object(["model": .string("synthetic-text"), "input": .string("synthetic")]))
        #expect(imagesOnly.0 == 403 && h.calls.count == 5)
        let key = try #require(try await h.store.listKeys(after: nil).first { $0.id == "alice" })
        _ = try await h.store.updateKey(
          id: key.id, revision: key.revision, enabled: true,
          policy: .init(
            models: ["synthetic-text"], limits: key.policy.limits, visionInput: true,
            imageGeneration: true, imageModels: ["synthetic-image"]))
        let tool: JSONValue = .object([
          "model": .string("synthetic-text"), "input": .string("synthetic"),
          "tools": .array([.object(["type": .string("image_generation")])]),
        ])
        let first = try await post("responses", tool)
        #expect(first.0 == 200)
        let id = try #require(first.1["id"]?.string)
        var follow = tool.object!
        follow["previous_response_id"] = .string(id)
        #expect(try await post("responses", .object(follow)).0 == 200)
        #expect(
          h.calls.suffix(2).map(\.account).allSatisfy { $0 == h.calls[h.calls.count - 2].account })
        let count = h.calls.count
        #expect(try await post("responses", .object(follow), key: h.bob).0 != 200)
        #expect(h.calls.count == count)
        if transport == "websocket" {
          let client = try PoolWSClient(h)
          defer { client.close() }
          _ = try await client.read()
          let native = try await client.command(["tools": tool["tools"]!])
          #expect(native["type"]?.string == "response.completed")
          let responseID = try #require(native["response"]?["id"]?.string)
          #expect(
            try await client.command([
              "tools": tool["tools"]!, "previous_response_id": .string(responseID),
            ])["type"]?.string == "response.completed")
          #expect(
            h.calls.suffix(2).map(\.account).allSatisfy { $0 == h.calls[h.calls.count - 2].account }
          )
        }
        try await awaitOAuth { h.finalizer.outstanding == 0 }
        let total = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
        #expect(total == h.calls.count && h.state.value.withLock { $0.invalid == 0 })
        let usage = try await h.store.perform {
          try $0.scalar("SELECT SUM(json_extract(usage_json,'$.images')) FROM attempts")
        }
        #expect(usage == total)
      } catch {
        await h.close()
        throw error
      }
      await h.close()
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeRequestParametersRejectBeforeFirstAdmissionOrUpstreamHandshake() async throws {
  try await withPoolHTTP(transport: "websocket") { h in
    for fields: [String: JSONValue] in [
      ["store": .bool(true)], ["max_output_tokens": .number(128)],
      ["temperature": .number(1)], ["top_p": .number(1)],
      ["truncation": .string("disabled")], ["metadata": .object(["label": .string("synthetic")])],
      ["prompt_cache_retention": .string("24h")],
    ] {
      let client = try PoolWSClient(h)
      #expect(try await client.read()["ready"]?.bool == true)
      let rejected = try await client.command(
        fields.merging(["lane": .string("synthetic-lane")]) { a, _ in a })
      #expect(rejected["error"]?["code"]?.string == "unsupported_backend_parameter")
      #expect(rejected["stream_id"]?.string == "synthetic-lane")
      client.close()
      #expect(h.calls.isEmpty && h.state.value.withLock { $0.upgrades == 0 })
      let total = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
      #expect(total == 0 && h.finalizer.outstanding == 0)
    }
    let client = try PoolWSClient(h)
    defer { client.close() }
    _ = try await client.read()
    #expect(try await client.command()["type"]?.string == "response.completed")
    try await awaitOAuth { h.finalizer.outstanding == 0 }
    let rejected = try await client.command(["store": .bool(true)])
    #expect(rejected["error"]?["code"]?.string == "unsupported_backend_parameter")
    #expect(h.calls.count == 1 && h.state.value.withLock { $0.upgrades == 1 })
    let total = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
    #expect(total == 1 && h.finalizer.outstanding == 0)
  }
}

@Test(.timeLimit(.minutes(1)))
func nativePoolImageRateLimitCoolsSelectedAccountWithoutReplay() async throws {
  try await withOAuth(timeout: 3000) { oauth in
    let h = try await PoolHTTPHarness.open(oauth, images: true)
    do {
      func post(_ prompt: String) async throws -> Int {
        var request = URLRequest(
          url: URL(string: "http://127.0.0.1:\(h.port)/v1/images/generations")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONValue.object(["prompt": .string(prompt)]).data()
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer " + h.alice, forHTTPHeaderField: "authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as! HTTPURLResponse).statusCode
      }
      #expect(try await post("http429") == 429)
      try await awaitOAuth { h.finalizer.outstanding == 0 }
      #expect(h.calls.count == 1)
      let selected = try #require(h.calls.first?.account).replacingOccurrences(
        of: "synthetic-", with: "")
      let health = try await h.store.accountHealth(id: selected)
      #expect(health.cooldowns.count == 1)
      let other = try #require(try await h.store.listAccounts().first { $0.id != selected })
      _ = try await h.store.setAccountMode(id: other.id, revision: other.revision, mode: .disabled)
      #expect(try await post("synthetic") == 503)
      #expect(h.calls.count == 1 && h.state.value.withLock { $0.invalid == 0 })
    } catch {
      await h.close()
      throw error
    }
    await h.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func poolControlDispatchHasNoIntentAndSharesCredentialHealthWithResponses() async throws {
  for (status, truncated) in [
    (200, false), (400, false), (429, false), (401, false), (500, false), (429, true), (401, true),
  ] {
    try await withPoolHTTP { h in
      var request = URLRequest(
        url: URL(string: "http://127.0.0.1:\(h.port)/backend-api/codex/alpha/search?x=%2f&x=2")!)
      request.httpMethod = "POST"
      let body = try JSONValue.object([
        "input": .string(
          status == 200 ? "synthetic" : (truncated ? "truncated" : "http") + String(status))
      ]).data()
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "content-type")
      request.setValue("Bearer " + h.alice, forHTTPHeaderField: "authorization")
      request.setValue("synthetic-cookie", forHTTPHeaderField: "cookie")
      request.setValue("forged-account", forHTTPHeaderField: "chatgpt-account-id")
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      let (_, response) = try await session.data(for: request)
      #expect(
        (response as! HTTPURLResponse).statusCode == (status == 401 || status == 500 ? 502 : status)
      )
      #expect(h.calls.count == 1)
      let call = try #require(h.calls.first)
      #expect(call.path == "/backend-api/codex/alpha/search?x=%2f&x=2")
      #expect(call.body == body && call.headers?["cookie"].isEmpty == true)
      #expect(h.state.value.withLock { $0.invalid } == 0)
      let count = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
      #expect(count == 0 && h.finalizer.outstanding == 0)
      let selected = call.account.replacingOccurrences(of: "synthetic-", with: "")
      let health = try await h.store.accountHealth(id: selected)
      #expect(health.authenticationRejected == (status == 401))
      #expect(health.cooldowns.count == ([429, 500].contains(status) ? 1 : 0))
      let other = try #require(try await h.store.listAccounts().first { $0.id != selected })
      _ = try await h.store.setAccountMode(id: other.id, revision: other.revision, mode: .disabled)
      #expect(try await h.request().0 == ([200, 400].contains(status) ? 200 : 503))
      #expect(h.calls.count == ([200, 400].contains(status) ? 2 : 1))
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolControlFollowsResponsesSessionWithoutCreatingAnotherIntent() async throws {
  try await withPoolHTTP { h in
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("Bearer " + h.alice, forHTTPHeaderField: "authorization")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("synthetic-session-affinity", forHTTPHeaderField: "session_id")
    request.httpBody = try JSONValue.object([
      "model": .string("synthetic-text"), "input": .string("synthetic"),
    ]).data()
    let (_, first) = try await session.data(for: request)
    #expect((first as! HTTPURLResponse).statusCode == 200)
    let account = try #require(h.calls.last?.account)
    request.url = URL(string: "http://127.0.0.1:\(h.port)/backend-api/codex/alpha/search")!
    request.httpBody = Data("{}".utf8)
    let (_, second) = try await session.data(for: request)
    #expect((second as! HTTPURLResponse).statusCode == 200)
    #expect(h.calls.count == 2 && h.calls.last?.account == account)
    let count = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
    #expect(count == 1)
  }
}

private func assertPoolRefusalSettled(_ h: PoolHTTPHarness) async throws {
  try await awaitOAuth { h.finalizer.outstanding == 0 }
  let reader = try await h.store.makeUsageReader()
  do {
    let hour = Int64(Date().timeIntervalSince1970) / 3600 * 3600
    let report = try await reader.queryUsage(
      .init(startUnixSeconds: hour, endUnixSeconds: hour + 3600))
    #expect(report.totals.complete == 1 && report.totals.failed == 1 && report.totals.unknown == 0)
    #expect(report.totals.metrics.estimatedMicros == 0)
    if report.rows.first(where: { $0.kind == .admitted })?.model == "synthetic-image" {
      #expect(
        report.totals.metrics.inputTokens == nil && report.totals.metrics.imageInputTokens == 0)
    } else {
      #expect(report.totals.metrics.inputTokens == 0)
    }
    #expect(report.totals.lifetimeExposureMicros == 0 && report.totals.lifetimeInFlight == 0)
    let admitted = report.rows.first { $0.kind == .admitted }
    #expect(admitted?.state == .settled && admitted?.outcome == .failed)
    let marked = try await h.store.perform {
      try $0.scalar(
        "SELECT COUNT(*) FROM attempts WHERE json_extract(usage_json,'$.providerRejectedBeforeOutput')=1"
      )
    }
    #expect(marked == 1)
  } catch {
    await reader.close()
    throw error
  }
  await reader.close()
}

@Test(.timeLimit(.minutes(1)))
func poolExplicitRefusalSettlesAllHTTPModesIncludingUnreadableBodies() async throws {
  for path in ["responses", "responses/compact", "images/generations"] {
    for fault in ["http400", "http403", "http429", "truncated403"] {
      try await withOAuth(timeout: 3000) { oauth in
        let h = try await PoolHTTPHarness.open(oauth, images: true)
        do {
          let session = URLSession(configuration: .ephemeral)
          defer { session.invalidateAndCancel() }
          var request = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/v1/" + path)!)
          request.httpMethod = "POST"
          request.httpBody = try JSONValue.object(
            path.hasPrefix("images")
              ? ["model": .string("synthetic-image"), "prompt": .string(fault)]
              : ["model": .string("synthetic-text"), "input": .string(fault)]
          ).data()
          request.setValue("application/json", forHTTPHeaderField: "content-type")
          // Bob has text plus Images permission; Alice deliberately has Images only.
          request.setValue("Bearer " + h.bob, forHTTPHeaderField: "authorization")
          let (_, response) = try await session.data(for: request)
          #expect([400, 403, 429].contains((response as! HTTPURLResponse).statusCode))
          try await assertPoolRefusalSettled(h)
          #expect(h.calls.count == 1)
        } catch {
          await h.close()
          throw error
        }
        await h.close()
      }
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolFirstEventRefusalsSettleButOutputThenErrorRemainsUnknown() async throws {
  for transport in ["http", "websocket"] {
    for native in [false, true] where !native || transport == "websocket" {
      for fault in ["refuse-error", "refuse-failed", "output-error"] {
        try await withPoolHTTP(transport: transport) { h in
          if native {
            let client = try PoolWSClient(h)
            defer { client.close() }
            _ = try await client.read()
            _ = try await client.command(["input": .string(fault)])
          } else {
            _ = try await h.request(fault, stream: true)
          }
          if fault == "output-error" {
            try await awaitOAuth { h.finalizer.outstanding == 0 }
            let unknown = try await h.store.perform {
              try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
            }
            #expect(unknown == 1)
          } else {
            try await assertPoolRefusalSettled(h)
          }
          #expect(h.calls.count == 1)
        }
      }
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketUpstreamCloseDrainsAndRejectsQueuedCreates() async throws {
  for active in [false, true] {
    try await withPoolHTTP(transport: "websocket") { h in
      let client = try PoolWSClient(h)
      defer { client.close() }
      _ = try await client.read()
      #expect(try await client.command()["type"]?.string == "response.completed")
      try await awaitOAuth { h.finalizer.outstanding == 0 }
      if active {
        _ = try await client.command([
          "op": .string("send"), "input": .string("stallbody"), "lane": .string("busy"),
        ])
        try await awaitOAuth { h.calls.count == 2 }
        // Same-lane FIFO request is queued before EOF and must never acquire an execution.
        _ = try await client.command([
          "op": .string("send"), "lane": .string("busy"),
        ])
      }
      let channels = h.state.value.withLock { Array($0.channels.values) }
      for channel in channels { try await channel.close().get() }
      // Allow the upstream reader to observe EOF while the downstream close remains unread.
      try await Task.sleep(for: .milliseconds(100))
      let result = try await client.command(["op": .string("expect_close"), "race": .bool(true)])
      #expect(result["closed"]?.integer == 1000)
      try await awaitOAuth { h.finalizer.outstanding == 0 }
      let total = try await h.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") }
      let unknown = try await h.store.perform {
        try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='unknown'")
      }
      #expect(total == (active ? 2 : 1) && unknown == (active ? 1 : 0))
      #expect(h.calls.count == (active ? 2 : 1))
      let rejected = try await h.store.perform {
        try $0.scalar("SELECT COUNT(*) FROM request_diagnostics")
      }
      #expect(rejected == 0)
      try await awaitOAuth { h.state.value.withLock { $0.channels.isEmpty } }
      let next = try PoolWSClient(h)
      defer { next.close() }
      _ = try await next.read()
      #expect(try await next.command()["type"]?.string == "response.completed")
      #expect(h.calls.count == (active ? 3 : 2))
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func poolNativeWebSocketControlsAndUnexpectedGenerationKeepDurableOwner() async throws {
  try await withPoolHTTP(transport: "websocket") { h in
    let client = try PoolWSClient(h)
    defer { client.close() }
    #expect(try await client.read()["ready"]?.bool == true)
    #expect(try await client.command(["op": .string("compatibility")])["verified"]?.bool == true)
    try await awaitOAuth {
      h.finalizer.outstanding == 0 && h.state.value.withLock { $0.channels.isEmpty }
    }
    let rows = try await h.store.perform {
      try $0.rows("SELECT state,admission_json,usage_json FROM attempts ORDER BY rowid") {
        statement in
        (
          String(cString: sqlite3_column_text(statement, 0)),
          String(cString: sqlite3_column_text(statement, 1)),
          sqlite3_column_type(statement, 2) == SQLITE_NULL
        )
      }
    }
    #expect(rows.count == 5)
    #expect(rows.filter { $0.0 == "settled" }.count == 4)
    #expect(rows.last?.0 == "unknown" && rows.last?.2 == true)
    let owner = try JSONValue.decode(Data(rows[0].1.utf8))["owner"]
    #expect(try rows.allSatisfy { try JSONValue.decode(Data($0.1.utf8))["owner"] == owner })
    #expect(owner?["key"]?.string == "alice")
    #expect(h.calls.count == 4 && Set(h.calls.map(\.account)).count == 1)
    #expect(h.state.value.withLock { $0.upgrades == 1 && $0.invalid == 0 })
  }
}
