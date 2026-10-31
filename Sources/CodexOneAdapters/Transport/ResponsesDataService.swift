import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import ServiceLifecycle
import Synchronization

/// Configured data-plane lifetime. All connection tasks are children of this service.
public struct ResponsesDataService: Service {
  private let group: any EventLoopGroup
  private let port: Int
  private let proxy: UpstreamHTTPProxy?
  private let source: ResponsesSource
  private var configuration: ResponsesConfiguration { source.configuration }
  private let store: any ExecutionStore
  private let finalizer: any FinalizationSink
  private let imageCapacity: ImageCapacity
  private let controlCapacity = ControlCapacity()
  private let controlAffinity = ControlAffinity()
  private let bodyBudget = RequestBodyBudget()
  private let onBound: @Sendable (Int) -> Void

  public init(
    group: any EventLoopGroup, port: Int, configuration: SingleIdentityConfiguration,
    store: any ExecutionStore, finalizer: any FinalizationSink, proxy: UpstreamHTTPProxy? = nil,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) throws {
    try configuration.validate()
    self.group = group
    self.port = port
    self.proxy = proxy
    imageCapacity = ImageCapacity(limit: configuration.imageConcurrency ?? 2)
    source = .single(configuration)
    self.store = store
    self.finalizer = finalizer
    self.onBound = onBound
  }

  public init(
    group: any EventLoopGroup, port: Int, configuration: AccountPoolConfiguration,
    store: any AccountRoutingStore, finalizer: any FinalizationSink,
    credentials: AccountCredentials, refresher: any AccountDispatchRefreshing,
    provider: SubscriptionOAuthProvider, proxy: UpstreamHTTPProxy? = nil,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) throws {
    try self.init(
      group: group, port: port, configuration: configuration, store: store,
      finalizer: finalizer, credentials: credentials, refresher: refresher, provider: provider,
      target: .openAI, proxy: proxy, onBound: onBound)
  }
  init(
    group: any EventLoopGroup, port: Int, configuration: AccountPoolConfiguration,
    store: any AccountRoutingStore, finalizer: any FinalizationSink,
    credentials: AccountCredentials, refresher: any AccountDispatchRefreshing,
    provider: SubscriptionOAuthProvider, target: SubscriptionDataTarget,
    proxy: UpstreamHTTPProxy? = nil,
    onBound: @escaping @Sendable (Int) -> Void
  ) throws {
    try configuration.validate()
    self.group = group
    self.port = port
    self.proxy = proxy
    imageCapacity = ImageCapacity(limit: configuration.imageConcurrency ?? 2)
    source = .pool(configuration, credentials, refresher, provider, target)
    self.store = store
    self.finalizer = finalizer
    self.onBound = onBound
  }

  public func readiness() async -> ReadinessReport {
    let accounts: Bool
    switch source {
    case .single: accounts = true
    case .pool(_, let credentials, let refresher, let provider, _):
      if provider.isAccepting && refresher.isAccepting {
        accounts =
          (try? await credentials.hasLocallyRoutableAccount(
            models: Set(
              configuration.models.map(\.id)
                + (configuration.imageGeneration?.models.map(\.id) ?? [])))) == true
      } else {
        accounts = false
      }
    }
    return .init(checks: [
      .init(name: "execution_store", ready: store.isAdmissionReady),
      .init(name: "upstream_accounts", ready: accounts),
      .init(name: "authorization", ready: finalizer.isAccepting),
    ])
  }

  public func run() async throws {
    if let health = store as? any AccountHealthStore {
      try await health.configureHealthModels(
        Set(
          configuration.models.map(\.id) + (configuration.imageGeneration?.models.map(\.id) ?? [])))
    }
    let token = try source.tokenFile.map { try readRuntimeSecret($0) }
    var pool = HTTPClient.Configuration.ConnectionPool(
      idleTimeout: .seconds(10), concurrentHTTP1ConnectionsPerHostSoftLimit: 16)
    pool.retryConnectionEstablishment = true
    var clientConfiguration = HTTPClient.Configuration(
      redirectConfiguration: .disallow,
      timeout: .init(
        connect: .seconds(10),
        read: .seconds(
          Int64(max(300, max(configuration.budget.first, configuration.budget.idle)) + 5))),
      connectionPool: pool, proxy: proxy?.clientProxy,
      decompression: .disabled)
    clientConfiguration.httpVersion = .http1Only
    clientConfiguration.maximumUsesPerConnection = 1
    let client = HTTPClient(
      eventLoopGroupProvider: .shared(group), configuration: clientConfiguration)
    let executor = HTTPResponseExecution(
      imageCapacity: imageCapacity, controlCapacity: controlCapacity,
      controlAffinity: controlAffinity, client: client,
      webSocket: .init(group: group, configuration: configuration, token: token, proxy: proxy),
      configuration: configuration, token: token,
      report: { await readiness() },
      access: .init(source: source, token: token, store: store, finalizer: finalizer),
      gateway: nil, effectiveModels: [])
    // Dedicated control headroom lets saturation return HTTP 429.
    let channels = ProtocolChannels(limit: configuration.dataConnections + 16)
    let normalChannels = ProtocolChannels(limit: configuration.dataConnections)
    do {
      let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(
          ChannelOptions.recvAllocator,
          value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 65_536)
        )
        .bind(
          host: "127.0.0.1", port: port,
          serverBackPressureStrategy: .init(lowWatermark: 1, highWatermark: 16)
        ) {
          channel -> EventLoopFuture<EventLoopFuture<NegotiatedProtocol>> in
          guard channels.register(channel) else {
            return channel.close().flatMapThrowing { throw ExecutionError.capacity }
          }
          let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            channel.close(promise: nil)
          }
          let upgrader = NIOTypedWebSocketServerUpgrader<NegotiatedProtocol>(
            maxFrameSize: RequestBodyLimits.maximumBytes,
            shouldUpgrade: { channel, head in
              let path = String(head.uri.split(separator: "?", maxSplits: 1).first ?? "")
              let allowed =
                head.method == .GET
                && ["/v1/responses", "/backend-api/codex/responses"].contains(path)
                && configuration.upstreamTransport == "websocket"
                && head.headers["sec-websocket-protocol"].isEmpty
              // Decline extension offers by omitting negotiation headers; RSV remains forbidden.
              guard allowed else { return channel.eventLoop.makeSucceededFuture(nil) }
              return channel.eventLoop.makeFutureWithTask {
                do {
                  _ = try await executor.access.policy(
                    executor.access.digest(head.headers["authorization"]))
                  guard normalChannels.register(channel) else { throw ExecutionError.capacity }
                  return HTTPHeaders()
                } catch { return nil }
              }
            },
            upgradePipelineHandler: { channel, head in
              channel.eventLoop.makeCompletedFuture {
                let reservations = WebSocketBodyReservations()
                return .webSocket(
                  try configureWebSocket(
                    channel, client: false, budget: bodyBudget,
                    reservations: reservations),
                  try executor.access.digest(head.headers["authorization"]), reservations,
                  forwardedClientHeaders(head.headers, fingerprint: configuration.clientFingerprint)
                )
              }
            })
          var pipeline = NIOUpgradableHTTPServerPipelineConfiguration(
            upgradeConfiguration: .init(
              upgraders: [upgrader],
              notUpgradingCompletionHandler: { channel in
                channel.eventLoop.makeCompletedFuture {
                  .http(
                    try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                      wrappingChannelSynchronously: channel,
                      configuration: .init(
                        backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4))))
                }
              }))
          pipeline.enablePipelining = false
          return channel.pipeline.configureUpgradableHTTPServerPipeline(configuration: pipeline)
            .map { future in
              future.whenComplete { _ in timeout.cancel() }
              return future.flatMapError { error in
                channel.close().flatMapThrowing { throw error }
              }
            }
            .flatMapError { error in
              timeout.cancel()
              return channel.close().flatMapThrowing { throw error }
            }
        }
      onBound(server.channel.localAddress!.port!)
      try await cancelWhenGracefulShutdown {
        do {
          try await withTaskCancellationHandler {
            try await server.executeThenClose { inbound in
              try await withThrowingDiscardingTaskGroup { tasks in
                for try await connection in inbound {
                  tasks.addTask {
                    do {
                      switch try await connection.get() {
                      case .http(let socket):
                        try await Self.serve(
                          socket, executor: executor, budget: bodyBudget,
                          normalChannels: normalChannels)
                      case .webSocket(let socket, let digest, let reservations, let headers):
                        var executor = executor
                        executor.clientHeaders = headers
                        try await Self.serveWebSocket(
                          socket, executor: executor, digest: digest, reservations: reservations)
                      }
                    } catch {}

                  }
                }
              }
            }
          } onCancel: {
            channels.close()
          }
        } catch {
          // Closing an async listener reports its cancellation; requested shutdown is not startup failure.
          guard Task.isCancelled else { throw error }
        }
      }
    } catch {
      await channels.shutdown()
      try await client.shutdown()
      throw error
    }
    await channels.shutdown()
    try await client.shutdown()
  }

  private static func serveWebSocket(
    _ socket: ProtocolWebSocket, executor: HTTPResponseExecution, digest: String?,
    reservations: WebSocketBodyReservations
  )
    async throws
  {
    try await WebSocketPeer.run(socket, client: false, reservations: reservations) { downstream in
      let firstBody = try await withExecutionDeadline(seconds: 10) {
        try await downstream.nextBody()
      }
      let first: ResponseRequest
      do {
        first = try webSocketCreate(
          firstBody.data, imageConfiguration: executor.configuration.imageGeneration)
      } catch {
        try? await sendWebSocketError(
          error, requestID: UUID().uuidString, lane: "", to: downstream)
        throw error
      }
      let authorized = try await executor.authorized(digest)
      do {
        _ = try authorized.executionModel(first)
        _ = try first.preparedDocument(
          contract: authorized.configuration.requestContract, nativeWebSocket: true)
      } catch {
        let requestID = UUID().uuidString
        await authorized.recordRejection(first, requestID: requestID, error: error)
        try? await sendWebSocketError(
          error, requestID: requestID, lane: webSocketLane(JSONValue.decode(firstBody.data)),
          to: downstream)
        throw error
      }
      try await PoolWebSocketSession.run(
        downstream: downstream, firstBody: firstBody, first: first,
        executor: authorized, digest: digest)
    }
  }

  static func serveTurns(
    downstream: WebSocketPeer, upstream: WebSocketPeer, firstBody: WebSocketBody,
    executor: HTTPResponseExecution, digest: String?, initial: PoolWebSocketInitialTurn? = nil
  ) async throws {
    let commands = WebSocketInbox(capacity: RequestBodyLimits.budgetBytes)
    let activity = WebSocketActivity()
    defer { commands.finish(CancellationError(), discard: true) }
    try await withThrowingTaskGroup(of: WebSocketBody?.self) { lanes in
      defer { lanes.cancelAll() }
      var known = Set<String>()
      lanes.addTask { firstBody }
      while let result = try await lanes.next(), let body = result {
        let lane = try webSocketLane(JSONValue.decode(body.data))
        let fresh = !known.contains(lane)
        guard !fresh || lane.isEmpty || known.filter({ !$0.isEmpty }).count < 32 else {
          throw GatewayProtocolError(503, "websocket_lane_capacity")
        }
        activity.begin()
        do {
          try await withExecutionDeadline(seconds: 5) {
            try await commands.pushBody(body, lane: lane)
          }
        } catch {
          activity.end()
          throw error
        }
        if fresh {
          known.insert(lane)
          let firstTurn = known.count == 1 ? initial : nil
          lanes.addTask {
            var pending = firstTurn
            let tools = WebSocketToolState()
            while !Task.isCancelled {
              let body = try await commands.nextBody(lane: lane)
              defer { body.release() }
              defer { activity.end() }
              let initialTurn = pending
              pending = nil
              let requestID = initialTurn?.requestID ?? UUID().uuidString
              var requested: ResponseRequest?
              do {
                let request = try webSocketCreate(
                  body.data, imageConfiguration: executor.configuration.imageGeneration,
                  previousTools: tools.snapshot)
                requested = request
                if let initialTurn {
                  let model = try executor.executionModel(request)
                  try upstream.beginTurn(lane: lane, compaction: request.streamCompaction)
                  try await executor.exchange(
                    request, context: initialTurn.context, model: model, peer: upstream, lane: lane
                  ) { event in
                    try await downstream.send(event)
                    tools.observe(event, request: request)
                  }
                  initialTurn.start.finishTurn()
                } else {
                  let current = try await executor.authorized(digest)
                  try await current.execute(
                    request, requestID: requestID, peer: upstream, lane: lane
                  ) { event in
                    try await downstream.send(event)
                    tools.observe(event, request: request)
                  }
                }
              } catch {
                if let requested {
                  await executor.recordRejection(requested, requestID: requestID, error: error)
                }
                initialTurn?.start.close(error)
                if initialTurn == nil {
                  try? await sendWebSocketError(
                    error, requestID: requestID, lane: lane, to: downstream)
                  // A provider error event ended only this turn; the pinned socket stays usable.
                  if (error as? GatewayProtocolError)?.providerError != nil { continue }
                }
                throw error
              }
            }
            return nil
          }
        }
        lanes.addTask {
          try await activity.read { try await downstream.nextBody() }
        }
      }
    }
  }

  private static func serve(
    _ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
    executor: HTTPResponseExecution, budget: RequestBodyBudget, normalChannels: ProtocolChannels
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask {
        try await connection.executeThenClose { inbound, outbound in
          var iterator = inbound.makeAsyncIterator()
          while !Task.isCancelled {
            let requestDeadline = connection.channel.eventLoop.scheduleTask(in: .seconds(10)) {
              connection.channel.close(promise: nil)
            }
            let lease = budget.lease()
            defer { lease.release() }
            let received: (HTTPRequestHead, Data)?
            var control = false
            do {
              var head: HTTPRequestHead?
              var body = Data()
              var ended = false
              var maximumBytes = RequestBodyLimits.maximumBytes
              while let part = try await iterator.next() {
                switch part {
                case .head(let next):
                  guard head == nil else { throw GatewayProtocolError(400, "invalid_request") }
                  head = next
                  let path = String(next.uri.split(separator: "?", maxSplits: 1).first ?? "")
                  control = ControlRoute.match(method: next.method, path: path) != nil
                  if control { maximumBytes = ControlRoute.requestBytes }
                  if !["/health/live", "/health/ready"].contains(path) {
                    _ = try await executor.access.policy(
                      executor.access.digest(next.headers["authorization"]))
                  }
                  if !control, !normalChannels.register(connection.channel) {
                    throw ExecutionError.capacity
                  }
                  if control, !next.headers["content-encoding"].isEmpty {
                    throw GatewayProtocolError(415, "unsupported_content_type")
                  }
                  if let length = next.headers.first(name: "content-length"),
                    Int(length).map({ $0 < 0 || $0 > maximumBytes }) ?? true
                  {
                    throw GatewayProtocolError(413, "request_too_large")
                  }
                  if let length = next.headers.first(name: "content-length"),
                    let count = Int(length)
                  {
                    try lease.reserve(count, countAll: control)
                  }
                case .body(let bytes):
                  guard head != nil,
                    bytes.readableBytes <= maximumBytes - body.count
                  else {
                    throw GatewayProtocolError(413, "request_too_large")
                  }
                  try lease.reserve(body.count + bytes.readableBytes, countAll: control)
                  body.append(contentsOf: bytes.readableBytesView)
                case .end: ended = true
                }
                if ended { break }
              }
              received = ended ? head.map { ($0, body) } : nil
              requestDeadline.cancel()
            } catch {
              requestDeadline.cancel()
              let writer = ProtocolResponseWriter(
                writer: outbound, channel: connection.channel, keepAlive: false)
              if control { await writer.setControlRequest() }
              try? await writer.fail(error, diagnostics: !control)
              throw error
            }
            guard let (head, body) = received else { return }
            let writer = ProtocolResponseWriter(
              writer: outbound, channel: connection.channel, keepAlive: head.isKeepAlive)
            do {
              try await route(head: head, body: body, executor: executor, writer: writer)
            } catch {
              try await writer.fail(error)
            }
            if !head.isKeepAlive { return }
          }
        }
      }
      tasks.addTask {
        await withTaskCancellationHandler {
          try? await connection.channel.closeFuture.get()
        } onCancel: {
          connection.channel.close(promise: nil)
        }
      }
      defer { tasks.cancelAll() }
      _ = try await tasks.next()
      try? await connection.channel.close().get()
    }
  }

  private static func route(
    head: HTTPRequestHead, body: Data, executor: HTTPResponseExecution,
    writer: ProtocolResponseWriter
  ) async throws {
    let path = String(head.uri.split(separator: "?", maxSplits: 1).first ?? "")
    if head.method == .GET && ["/health/live", "/health/ready"].contains(path) {
      let reply = HealthRouter(report: await executor.report()).reply(method: "GET", uri: path)
      try await writer.json(
        try JSONDecoder().decode(JSONValue.self, from: reply.body), status: reply.status)
      return
    }
    if let control = ControlRoute.match(method: head.method, path: path) {
      await writer.setControlRequest()
      do {
        try await executor.executeControl(control, head: head, body: body) {
          try await writer.control($0)
        }
      } catch {
        try await writer.fail(error, diagnostics: false)
      }
      return
    }
    let prefix: String
    if path.hasPrefix("/v1/") {
      prefix = "/v1"
    } else if path.hasPrefix("/backend-api/codex/") {
      prefix = "/backend-api/codex"
    } else {
      throw GatewayProtocolError(404, "not_found")
    }
    let endpoint = String(path.dropFirst(prefix.count))
    guard
      endpoint == "/models" || endpoint == "/responses" || endpoint == "/responses/compact"
        || endpoint == "/images/generations" || endpoint == "/images/edits"
    else {
      throw GatewayProtocolError(404, "not_found")
    }
    var executor = try await executor.authorized(
      executor.access.digest(head.headers["authorization"]))
    executor.clientHeaders = forwardedClientHeaders(
      head.headers, fingerprint: executor.configuration.clientFingerprint)
    if endpoint == "/models", head.method == .GET {
      let codexDirectory =
        URLComponents(string: head.uri)?.queryItems?.contains {
          $0.name == "client_version"
        } == true
      try await writer.json(
        modelCatalog(
          executor.effectiveModels, requireCodexProfile: codexDirectory,
          images: executor.effectiveImageModels,
          runtimeBudget: executor.configuration.budgetSummary,
          upstreamTransport: executor.configuration.upstreamTransport
        ))
      return
    }
    if ["/images/generations", "/images/edits"].contains(endpoint) {
      guard head.method == .POST else { throw GatewayProtocolError(405, "method_not_allowed") }
      guard head.headers["content-type"].count == 1, head.headers["content-encoding"].isEmpty else {
        throw GatewayProtocolError(415, "unsupported_content_type")
      }
      guard
        prefix == "/v1"
          || !head.headers.first(name: "content-type")!.lowercased().hasPrefix("multipart/")
      else {
        throw GatewayProtocolError(415, "unsupported_content_type")
      }
      let request = try ImagesRequest(
        data: body, contentType: head.headers.first(name: "content-type")!,
        editing: endpoint == "/images/edits", configuration: executor.configuration.imageGeneration)
      try await executor.executeImage(
        request, requestID: writer.requestID, headers: head.headers,
        receiveHeaders: { await writer.imageHeaders($0) },
        begin: { try await writer.beginRaw($0, streaming: request.streaming) },
        emit: { try await writer.raw($0) }, finish: { try await writer.finishRaw() })
      return
    }
    guard ["/responses", "/responses/compact"].contains(endpoint), head.method == .POST else {
      throw GatewayProtocolError(405, "method_not_allowed")
    }
    guard head.headers["content-type"].count == 1,
      head.headers.first(name: "content-type")?.lowercased().hasPrefix("application/json") == true,
      head.headers["content-encoding"].isEmpty
    else { throw GatewayProtocolError(415, "unsupported_content_type") }
    let request = try ResponseRequest(
      data: body, mode: endpoint == "/responses/compact" ? .compact : .generation,
      imageConfiguration: executor.configuration.imageGeneration)
    if endpoint == "/responses/compact" {
      try await executor.compact(request, requestID: writer.requestID) { document in
        try await writer.json(document)
      }
      return
    }
    await writer.setStreaming(request.streaming)
    try await executor.execute(request, requestID: writer.requestID) { document in
      if request.streaming {
        try await writer.event(document)
      } else {
        try await writer.json(document)
      }
    }
    if request.streaming { try await writer.finishStream() }
  }
}

private enum NegotiatedProtocol: Sendable {
  case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>)
  case webSocket(ProtocolWebSocket, String?, WebSocketBodyReservations, HTTPHeaders)
}

private actor ProtocolResponseWriter {
  let requestID = UUID().uuidString
  private let writer: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
  private let channel: any Channel
  private let keepAlive: Bool
  private var extraHeaders = HTTPHeaders()
  func imageHeaders(_ headers: HTTPHeaders) {
    if let value = headers.first(name: "x-codex-imagegen-request-id") {
      extraHeaders.replaceOrAdd(name: "x-codex-imagegen-request-id", value: value)
    }
  }
  private var controlRequest = false
  func setControlRequest() { controlRequest = true }
  private var started = false
  private var streaming = false
  private var ended = false
  init(
    writer: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, channel: any Channel,
    keepAlive: Bool
  ) {
    self.writer = writer
    self.channel = channel
    self.keepAlive = keepAlive
  }
  func setStreaming(_ value: Bool) { streaming = value }
  private func write(_ part: HTTPServerResponsePart) async throws {
    try await writeBatch([part])
  }
  private func writeBatch(_ parts: [HTTPServerResponsePart]) async throws {
    let deadline = channel.eventLoop.scheduleTask(in: .seconds(5)) {
      self.channel.close(promise: nil)
    }
    defer { deadline.cancel() }
    try await writer.write(contentsOf: parts)
  }
  func json(_ value: JSONValue, status: Int = 200, retryAfter: Int64? = nil) async throws {
    guard !started else { throw GatewayProtocolError(502, "invalid_response_state") }
    let data = try value.data()
    var headers: HTTPHeaders = [
      "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
      "content-length": String(data.count), "x-request-id": requestID,
    ]
    for header in extraHeaders { headers.add(name: header.name, value: header.value) }
    if let retryAfter { headers.add(name: "retry-after", value: String(retryAfter)) }
    if !keepAlive { headers.add(name: "connection", value: "close") }
    started = true
    do {
      // A Content-Length client may close as soon as it consumes the body. Do not yield
      // between that body and end: submit one complete bounded response to the writer.
      try await writeBatch([
        .head(.init(version: .http1_1, status: .init(statusCode: status), headers: headers)),
        .body(.byteBuffer(ByteBuffer(data: data))), .end(nil),
      ])
    } catch {
      if !controlRequest {
        ProtocolFailureDiagnostics.record(
          .init(502, "execution_indeterminate", detail: .downstreamJSONWrite), requestID: requestID)
      }
      throw error
    }
    ended = true
  }
  func control(_ reply: ControlReply) async throws {
    guard !started else { throw GatewayProtocolError(502, "invalid_response_state") }
    var headers = reply.headers
    headers.replaceOrAdd(name: "content-length", value: String(reply.body.count))
    headers.replaceOrAdd(name: "x-request-id", value: requestID)
    if !keepAlive { headers.replaceOrAdd(name: "connection", value: "close") }
    started = true
    try await writeBatch([
      .head(.init(version: .http1_1, status: .init(statusCode: reply.status), headers: headers)),
      .body(.byteBuffer(ByteBuffer(data: reply.body))), .end(nil),
    ])
    ended = true
  }
  func beginRaw(_ headers: HTTPHeaders, streaming: Bool) async throws {
    guard !started else { throw GatewayProtocolError(502, "invalid_response_state") }
    self.streaming = streaming
    var headers = headers
    headers.add(name: "x-request-id", value: requestID)
    headers.add(name: "cache-control", value: "no-store")
    if !keepAlive { headers.add(name: "connection", value: "close") }
    started = true
    try await write(.head(.init(version: .http1_1, status: .ok, headers: headers)))
  }
  func raw(_ data: Data) async throws {
    try await write(.body(.byteBuffer(ByteBuffer(data: data))))
  }
  func finishRaw() async throws {
    try await write(.end(nil))
    ended = true
  }
  func event(_ value: JSONValue) async throws {
    guard !ended, let type = value["type"]?.string,
      type.utf8.count <= 128,
      type.utf8.allSatisfy({
        (45...57).contains($0) || (65...90).contains($0) || (95...122).contains($0)
      })
    else {
      throw GatewayProtocolError(502, "invalid_upstream_event")
    }
    if !started {
      var headers: HTTPHeaders = [
        "content-type": "text/event-stream", "cache-control": "no-store", "x-accel-buffering": "no",
        "x-request-id": requestID,
      ]
      if !keepAlive { headers.add(name: "connection", value: "close") }
      started = true
      try await write(.head(.init(version: .http1_1, status: .ok, headers: headers)))
    }
    var data = Data(("event: " + type + "\ndata: ").utf8)
    data.append(try value.data())
    data.append(Data("\n\n".utf8))
    try await write(.body(.byteBuffer(ByteBuffer(data: data))))
  }
  func finishStream() async throws {
    guard started, !ended else { throw GatewayProtocolError(502, "execution_indeterminate") }
    try await write(.body(.byteBuffer(ByteBuffer(string: "data: [DONE]\n\n"))))
    try await write(.end(nil))
    ended = true
  }
  func fail(_ error: any Error, diagnostics: Bool = true) async throws {
    let mapped = protocolFailure(error)
    let envelope = protocolErrorEnvelope(error, requestID: requestID, diagnostics: diagnostics)
    if !started {
      try await json(envelope, status: mapped.status, retryAfter: mapped.cooldownSeconds)
    } else if streaming && !ended {
      if mapped.providerError != nil {
        // Clients interpret provider failures from the terminal response, as on a direct stream.
        try await event(
          .object([
            "type": .string("response.failed"),
            "response": .object(["status": .string("failed"), "error": envelope["error"]!]),
          ]))
      } else {
        try await event(.object(["type": .string("error"), "error": envelope["error"]!]))
      }
      try await write(.end(nil))
      ended = true
    } else {
      throw mapped
    }
  }
}
