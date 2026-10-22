import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import CodexOneAdapters

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private final class PoolHTTPState: Sendable {
  struct Call: Sendable {
    let account: String
    let path: String
    let previous: String?
  }
  struct State {
    var expected: [String: String] = [:]
    var calls: [Call] = []
    var invalid = 0
    var channels: [ObjectIdentifier: any Channel] = [:]
  }
  let value = Mutex(State())
}
private final class PoolHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let state: PoolHTTPState
  var head: HTTPRequestHead?
  var body = Data()
  init(_ state: PoolHTTPState) { self.state = state }
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
    case .head(let head): self.head = head
    case .body(let bytes): body.append(contentsOf: bytes.readableBytesView)
    case .end:
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
              account: account, path: head.uri, previous: request["previous_response_id"]?.string))
          return value.calls.count
        }
        if request["input"]?.string == "abort" {
          context.close(promise: nil)
          return
        }
        let compact = head.uri.hasSuffix("/compact")
        var document: [String: JSONValue] = [
          "id": .string("synthetic-response-\(count)"),
          "object": .string(compact ? "response.compaction" : "response"), "created_at": .number(1),
          "output": .array([]),
          "usage": .object([
            "input_tokens": .number(2), "output_tokens": .number(1), "total_tokens": .number(3),
            "input_tokens_details": .object(["cached_tokens": .number(0)]),
          ]),
        ]
        if request["input"]?.string == "partial" {
          document["usage"] = .object(["input_tokens": .number(2)])
        }
        if !compact {
          document["status"] = .string("completed")
          document["model"] = .string("synthetic-text")
        }
        if let previous = request["previous_response_id"] {
          document["previous_response_id"] = previous
        }
        let stream = request["stream"]?.bool == true && !compact
        let bytes: Data
        if stream {
          let event = JSONValue.object([
            "type": .string("response.completed"), "response": .object(document),
          ])
          bytes = Data(
            "event: response.completed\ndata: \(String(decoding: try event.data(), as: UTF8.self))\n\n"
              .utf8)
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
        if request["input"]?.string == "hold" {
          _ = context.eventLoop.scheduleTask(in: .milliseconds(400), reply)
        } else {
          reply()
        }
      } catch { context.close(promise: nil) }
    }
  }
}
private struct PoolHTTPHarness {
  let oauth: OAuthHarness
  let listener: any Channel
  let state: PoolHTTPState
  let finalizer: ExecutionFinalizer
  let owner: Task<Void, any Error>
  let port: Int
  let alice: String
  let bob: String
  var calls: [PoolHTTPState.Call] { state.value.withLock { $0.calls } }
  static func open(_ oauth: OAuthHarness) async throws -> Self {
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
        policy: KeyPolicy(models: ["synthetic-text"], limits: limits))
    }
    let listener = try await ServerBootstrap(group: oauth.group).childChannelInitializer {
      channel in
      channel.pipeline.configureHTTPServerPipeline().flatMap {
        channel.pipeline.addHandler(PoolHTTPHandler(state))
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    let configuration = try JSONDecoder().decode(
      AccountPoolConfiguration.self,
      from: Data(
        #"{"models":[{"id":"synthetic-text","inputMicrosPerMillion":1000000,"outputMicrosPerMillion":1000000}],"reservedMicros":1,"executionTimeoutSeconds":5}"#
          .utf8))
    let finalizer = try ExecutionFinalizer(store: oauth.store)
    let bound = Mutex(0)
    let service = try ResponsesDataService(
      group: oauth.group, port: 0, configuration: configuration, store: oauth.store,
      finalizer: finalizer, credentials: oauth.app, refresher: oauth.supervisor,
      provider: oauth.provider, target: .syntheticLoopback(port: listener.localAddress!.port!)
    ) { port in bound.withLock { $0 = port } }
    let owner = Task {
      try await GatewayRuntime(services: [finalizer, service]).run(handleSignals: false)
    }
    try await awaitOAuth { bound.withLock { $0 > 0 } && finalizer.isAccepting }
    return Self(
      oauth: oauth, listener: listener, state: state, finalizer: finalizer, owner: owner,
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
  func close() async {
    owner.cancel()
    _ = await owner.result
    for channel in state.value.withLock({ Array($0.channels.values) }) {
      try? await channel.close().get()
    }
    try? await listener.close().get()
  }
}
private func withPoolHTTP(_ operation: (PoolHTTPHarness) async throws -> Void) async throws {
  try await withOAuth(timeout: 3000) { oauth in
    let harness = try await PoolHTTPHarness.open(oauth)
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
    let stream = try await h.request(stream: true, previous: id)
    #expect(
      stream.0 == 200 && String(decoding: stream.1, as: UTF8.self).contains("response.completed"))
    #expect(h.calls.last?.account == firstAccount)
    let compact = try await h.request(compact: true)
    #expect(compact.0 == 200)
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
    #expect(try await h.request(previous: id).0 == 503)
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
    let continued = try await h.request(stream: true, previous: id)
    #expect(continued.0 == 200)
    #expect(h.calls.count == 2 && h.calls.last?.account == selected)
    #expect(h.oauth.server.counts.calls == 3 && h.oauth.server.counts.invalid == 0)
    #expect(h.state.value.withLock { $0.invalid } == 0)
    #expect(try await h.oauth.store.accountCredential(id: accountID).account.credentialVersion == 3)
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

@Test(.timeLimit(.minutes(1))) func poolHTTPPartialUsageRemainsUnknownWithoutDroppingObservedCosts()
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
