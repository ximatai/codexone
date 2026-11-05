import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import ServiceLifecycle
import Vapor

/// Bounded NIO ingress feeds only complete bodies to Vapor's application routes.
struct AdminHTTPIngress: Sendable {
  let group: any EventLoopGroup
  let listeners: ListenerConfiguration
  let port: Int
  let app: Application
  let overview: OverviewLive?
  let sessions: AdminSessions?
  let onBound: @Sendable (Int) -> Void

  func run() async throws {
    let channels = ProtocolChannels(limit: 32)
    func bind(host: String, port: Int) async throws -> NIOAsyncChannel<
      EventLoopFuture<AdminConnection>, Never
    > {
      try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(
          ChannelOptions.recvAllocator,
          value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 16_384)
        )
        .bind(
          host: host, port: port,
          serverBackPressureStrategy: .init(lowWatermark: 1, highWatermark: 8)
        ) { channel -> EventLoopFuture<EventLoopFuture<AdminConnection>> in
          guard host == "127.0.0.1" || listeners.allows(peer: channel.remoteAddress?.ipAddress)
          else {
            return channel.close().flatMapThrowing { throw ExecutionError.unauthorized }
          }
          guard channels.register(channel) else {
            return channel.close().flatMapThrowing { throw ExecutionError.capacity }
          }
          let deadline = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            channel.close(promise: nil)
          }
          let id = UUID()
          channel.closeFuture.whenComplete { _ in sessions?.releaseLive(id) }
          let upgrader = NIOTypedWebSocketServerUpgrader<AdminConnection>(
            maxFrameSize: 125,
            shouldUpgrade: { channel, head in
              do {
                guard let overview, let sessions, head.method == .GET,
                  head.uri == "/api/overview/live", head.headers["sec-websocket-protocol"].isEmpty,
                  head.headers["content-length"].allSatisfy({ $0 == "0" }),
                  head.headers["transfer-encoding"].isEmpty
                else { throw ExecutionError.denied }
                _ = overview
                try sessions.bindLive(head.headers, id: id) { code in
                  AdminLiveTransport.close(channel, code: code)
                }
                return channel.eventLoop.makeSucceededFuture(
                  HTTPHeaders([("cache-control", "no-store")]))
              } catch {
                // NIO does not replay a rejected upgrade to the ordinary HTTP handler.
                return rejectWebSocketUpgrade(channel, error: error).map { nil }
              }
            },
            upgradePipelineHandler: { channel, _ in
              channel.eventLoop.makeCompletedFuture {
                guard let overview, let sessions else { throw ExecutionError.denied }
                try channel.pipeline.syncOperations.addHandler(AdminLiveWireGuard())
                let socket = try ProtocolWebSocket(
                  wrappingChannelSynchronously: channel,
                  configuration: .init(
                    backPressureStrategy: .init(lowWatermark: 1, highWatermark: 2)))
                return .live(.init(socket: socket, id: id, sessions: sessions, overview: overview))
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
                        backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4))), deadline)
                }
              }))
          pipeline.enablePipelining = false
          return channel.pipeline.configureUpgradableHTTPServerPipeline(configuration: pipeline).map
          { future in
            future.whenSuccess { if case .live = $0 { deadline.cancel() } }
            return future
          }.flatMapError { error in
            deadline.cancel()
            return channel.close().flatMapThrowing { throw error }
          }
        }
    }
    var servers: [NIOAsyncChannel<EventLoopFuture<AdminConnection>, Never>] = []
    do {
      let loopback = try await bind(host: "127.0.0.1", port: port)
      servers.append(loopback)
      if let address = listeners.additionalAddress {
        servers.append(try await bind(host: address, port: loopback.channel.localAddress!.port!))
      }
      onBound(loopback.channel.localAddress!.port!)
      let activeServers = servers
      try await cancelWhenGracefulShutdown {
        do {
          try await withTaskCancellationHandler {
            try await withThrowingDiscardingTaskGroup { listeners in
              for server in activeServers {
                listeners.addTask {
                  try await server.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { tasks in
                      for try await connection in inbound {
                        tasks.addTask {
                          do {
                            switch try await connection.get() {
                            case .http(let socket, let deadline):
                              try await serve(socket, deadline: deadline)
                            case .live(let live): try await live.run()
                            }
                          } catch {}
                        }
                      }
                    }
                  }
                }
              }
            }
          } onCancel: {
            channels.close()
          }
        } catch { guard Task.isCancelled else { throw error } }
      }
    } catch {
      for server in servers { try? await server.channel.close().get() }
      await channels.shutdown()
      throw error
    }
    await channels.shutdown()
  }
  private func serve(
    _ socket: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
    deadline: Scheduled<Void>
  ) async throws {
    defer { deadline.cancel() }
    try await socket.executeThenClose { inbound, _ in
      var head: HTTPRequestHead?
      var body = ByteBuffer()
      for try await part in inbound {
        switch part {
        case .head(let value):
          guard head == nil else { throw ExecutionError.invalidCommand }
          head = value
        case .body(var value):
          guard value.readableBytes <= 8192 - body.readableBytes else {
            try await write(
              status: .payloadTooLarge, headers: [:],
              body: Data(#"{"error":{"code":"request_too_large"}}"#.utf8),
              channel: socket.channel)
            return
          }
          body.writeBuffer(&value)
        case .end:
          guard let head else { throw ExecutionError.invalidCommand }
          deadline.cancel()
          let request = Request(
            application: app, method: head.method, url: URI(path: head.uri), version: head.version,
            headers: head.headers, collectedBody: body, on: socket.channel.eventLoop)
          let response = try await app.responder.respond(to: request).get()
          guard let data = response.body.data, data.count <= 1_048_576 else {
            throw ExecutionError.capacity
          }
          try await write(
            status: response.status, headers: response.headers, body: data,
            channel: socket.channel)
          return
        }
      }
    }
  }
  private func write(
    status: HTTPResponseStatus, headers: HTTPHeaders, body: Data,
    channel: any Channel
  ) async throws {
    let deadline = channel.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
    defer { deadline.cancel() }
    var headers = headers
    headers.replaceOrAdd(name: "content-length", value: String(body.count))
    headers.replaceOrAdd(name: "connection", value: "close")
    headers.replaceOrAdd(name: "cache-control", value: "no-store")
    if headers.first(name: "content-type") == nil {
      headers.add(name: "content-type", value: "application/json; charset=utf-8")
    }
    let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    // Async writer yield only queues writes. Await the final socket write before executeThenClose
    // may close this connection; otherwise a large static asset can be truncated under pressure.
    try await channel.eventLoop.flatSubmit {
      channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
      channel.write(
        NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(data: body)))), promise: nil)
      return channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
    }.get()
  }
}
private enum AdminConnection: Sendable {
  case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Scheduled<Void>)
  case live(AdminLiveTransport)
}
