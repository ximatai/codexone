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
  private let source: ResponsesSource
  private var configuration: ResponsesConfiguration { source.configuration }
  private let store: any ExecutionStore
  private let finalizer: any FinalizationSink
  private let onBound: @Sendable (Int) -> Void

  public init(
    group: any EventLoopGroup, port: Int, configuration: SingleIdentityConfiguration,
    store: any ExecutionStore, finalizer: any FinalizationSink,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) throws {
    try configuration.validate()
    self.group = group
    self.port = port
    source = .single(configuration)
    self.store = store
    self.finalizer = finalizer
    self.onBound = onBound
  }

  public init(
    group: any EventLoopGroup, port: Int, configuration: AccountPoolConfiguration,
    store: any AccountRoutingStore, finalizer: any FinalizationSink,
    credentials: AccountCredentials, refresher: any AccountDispatchRefreshing,
    provider: SubscriptionOAuthProvider,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) throws {
    try self.init(
      group: group, port: port, configuration: configuration, store: store,
      finalizer: finalizer, credentials: credentials, refresher: refresher, provider: provider,
      target: .openAI, onBound: onBound)
  }
  init(
    group: any EventLoopGroup, port: Int, configuration: AccountPoolConfiguration,
    store: any AccountRoutingStore, finalizer: any FinalizationSink,
    credentials: AccountCredentials, refresher: any AccountDispatchRefreshing,
    provider: SubscriptionOAuthProvider, target: SubscriptionDataTarget,
    onBound: @escaping @Sendable (Int) -> Void
  ) throws {
    try configuration.validate()
    self.group = group
    self.port = port
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
        accounts = (try? await credentials.hasLocallyRoutableAccount()) == true
      } else {
        accounts = false
      }
    }
    return .init(checks: [
      .init(name: "execution_store", ready: store.isAvailable),
      .init(name: "upstream_accounts", ready: accounts),
      .init(name: "authorization", ready: finalizer.isAccepting),
    ])
  }

  public func run() async throws {
    let token = try source.tokenFile.map { try readRuntimeSecret($0) }
    var pool = HTTPClient.Configuration.ConnectionPool(
      idleTimeout: .seconds(10), concurrentHTTP1ConnectionsPerHostSoftLimit: 16)
    pool.retryConnectionEstablishment = false
    var clientConfiguration = HTTPClient.Configuration(
      redirectConfiguration: .disallow,
      timeout: .init(connect: .seconds(5), read: .seconds(30)), connectionPool: pool, proxy: nil,
      decompression: .disabled)
    clientConfiguration.httpVersion = .http1Only
    clientConfiguration.maximumUsesPerConnection = 1
    let client = HTTPClient(
      eventLoopGroupProvider: .shared(group), configuration: clientConfiguration)
    let executor = HTTPResponseExecution(
      client: client, webSocket: .init(group: group, configuration: configuration, token: token),
      configuration: configuration, token: token,
      report: { await readiness() },
      access: .init(source: source, token: token, store: store, finalizer: finalizer),
      gateway: nil, effectiveModels: [])
    let channels = ProtocolChannels(limit: 32)
    do {
      let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(
          ChannelOptions.recvAllocator,
          value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 65_536)
        )
        .bind(
          host: "127.0.0.1", port: port,
          serverBackPressureStrategy: .init(lowWatermark: 1, highWatermark: 8)
        ) {
          channel -> EventLoopFuture<EventLoopFuture<NegotiatedProtocol>> in
          guard channels.register(channel) else {
            return channel.close().flatMapThrowing { throw ExecutionError.capacity }
          }
          let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            channel.close(promise: nil)
          }
          let upgrader = NIOTypedWebSocketServerUpgrader<NegotiatedProtocol>(
            maxFrameSize: 524_288,
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
                  return HTTPHeaders()
                } catch { return nil }
              }
            },
            upgradePipelineHandler: { channel, head in
              channel.eventLoop.makeCompletedFuture {
                .webSocket(
                  try configureWebSocket(channel, client: false),
                  try executor.access.digest(head.headers["authorization"]))
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
                      case .http(let socket): try await Self.serve(socket, executor: executor)
                      case .webSocket(let socket, let digest):
                        try await Self.serveWebSocket(socket, executor: executor, digest: digest)
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
    _ socket: ProtocolWebSocket, executor: HTTPResponseExecution, digest: String?
  )
    async throws
  {
    try await WebSocketPeer.run(socket, client: false) { downstream in
      let firstData = try await withExecutionDeadline(seconds: 10) { try await downstream.next() }
      let first = try webSocketCreate(firstData)
      let authorized = try await executor.authorized(digest)
      guard authorized.effectiveModels.contains(where: { $0.id == first.model }) else {
        throw GatewayProtocolError(403, "model_not_allowed")
      }
      try await executor.webSocket.run { upstream in
        let commands = WebSocketInbox()
        defer { commands.finish(CancellationError(), discard: true) }
        try await withThrowingTaskGroup(of: Data?.self) { lanes in
          defer { lanes.cancelAll() }
          var known = Set<String>()
          lanes.addTask { firstData }
          while let result = try await lanes.next(), let data = result {
            let lane = try webSocketLane(JSONValue.decode(data))
            let fresh = !known.contains(lane)
            guard !fresh || lane.isEmpty || known.filter({ !$0.isEmpty }).count < 32 else {
              throw GatewayProtocolError(503, "websocket_lane_capacity")
            }
            try await withExecutionDeadline(seconds: 5) { [data] in
              try await commands.push(data, lane: lane)
            }
            if fresh {
              known.insert(lane)
              lanes.addTask {
                while !Task.isCancelled {
                  let data = try await commands.next(lane: lane)
                  let requestID = UUID().uuidString
                  do {
                    let request = try webSocketCreate(data)
                    let current = try await executor.authorized(digest)
                    try await current.execute(
                      request, requestID: requestID, peer: upstream, lane: lane
                    ) { event in
                      try await downstream.send(event)
                    }
                  } catch {
                    var envelope: [String: JSONValue] = [
                      "type": .string("error"),
                      "error": protocolErrorEnvelope(error, requestID: requestID)["error"]!,
                    ]
                    if !lane.isEmpty { envelope["stream_id"] = .string(lane) }
                    try? await downstream.send(.object(envelope))
                    throw error
                  }
                }
                return nil
              }
            }
            lanes.addTask {
              try await withExecutionDeadline(seconds: 120) { try await downstream.next() }
            }
          }
        }
      }
    }
  }

  private static func serve(
    _ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
    executor: HTTPResponseExecution
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask {
        try await connection.executeThenClose { inbound, outbound in
          var iterator = inbound.makeAsyncIterator()
          while !Task.isCancelled {
            let requestDeadline = connection.channel.eventLoop.scheduleTask(in: .seconds(10)) {
              connection.channel.close(promise: nil)
            }
            let received: (HTTPRequestHead, Data)?
            do {
              var head: HTTPRequestHead?
              var body = Data()
              var ended = false
              while let part = try await iterator.next() {
                switch part {
                case .head(let next):
                  guard head == nil else { throw GatewayProtocolError(400, "invalid_request") }
                  head = next
                case .body(let bytes):
                  guard head != nil, bytes.readableBytes <= 524_288 - body.count else {
                    throw GatewayProtocolError(413, "request_too_large")
                  }
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
              try? await writer.fail(error)
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
    let prefix: String
    if path.hasPrefix("/v1/") {
      prefix = "/v1"
    } else if path.hasPrefix("/backend-api/codex/") {
      prefix = "/backend-api/codex"
    } else {
      throw GatewayProtocolError(404, "not_found")
    }
    let endpoint = String(path.dropFirst(prefix.count))
    guard endpoint == "/models" || endpoint == "/responses" || endpoint == "/responses/compact"
    else {
      throw GatewayProtocolError(404, "not_found")
    }
    let executor = try await executor.authorized(
      executor.access.digest(head.headers["authorization"]))
    if endpoint == "/models", head.method == .GET {
      let codexDirectory =
        URLComponents(string: head.uri)?.queryItems?.contains {
          $0.name == "client_version"
        } == true
      try await writer.json(
        modelCatalog(executor.effectiveModels, requireCodexProfile: codexDirectory))
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
      data: body, mode: endpoint == "/responses/compact" ? .compact : .generation)
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
  case webSocket(ProtocolWebSocket, String?)
}

private actor ProtocolResponseWriter {
  let requestID = UUID().uuidString
  private let writer: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
  private let channel: any Channel
  private let keepAlive: Bool
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
    let deadline = channel.eventLoop.scheduleTask(in: .seconds(5)) {
      self.channel.close(promise: nil)
    }
    defer { deadline.cancel() }
    try await writer.write(part)
  }
  func json(_ value: JSONValue, status: Int = 200) async throws {
    guard !started else { throw GatewayProtocolError(502, "invalid_response_state") }
    let data = try value.data()
    var headers: HTTPHeaders = [
      "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
      "content-length": String(data.count),
    ]
    if !keepAlive { headers.add(name: "connection", value: "close") }
    started = true
    try await write(
      .head(.init(version: .http1_1, status: .init(statusCode: status), headers: headers)))
    try await write(.body(.byteBuffer(ByteBuffer(data: data))))
    try await write(.end(nil))
    ended = true
  }
  func event(_ value: JSONValue) async throws {
    guard !ended, let type = value["type"]?.string,
      type.utf8.count <= 128,
      type.utf8.allSatisfy({
        (46...57).contains($0) || (65...90).contains($0) || (95...122).contains($0)
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
  func fail(_ error: any Error) async throws {
    let mapped = protocolFailure(error)
    let envelope = protocolErrorEnvelope(error, requestID: requestID)
    if !started {
      try await json(envelope, status: mapped.status)
    } else if streaming && !ended {
      try await event(.object(["type": .string("error"), "error": envelope["error"]!]))
      try await write(.end(nil))
      ended = true
    } else {
      throw mapped
    }
  }
}
