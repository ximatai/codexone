import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ServiceLifecycle
import Vapor

/// Bounded NIO ingress feeds only complete bodies to Vapor's application routes.
struct AdminHTTPIngress: Sendable {
  let group: any EventLoopGroup
  let port: Int
  let app: Application
  let onBound: @Sendable (Int) -> Void

  func run() async throws {
    let channels = ProtocolChannels(limit: 32)
    do {
      let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(
          ChannelOptions.recvAllocator,
          value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 16_384)
        )
        .bind(
          host: "127.0.0.1", port: port,
          serverBackPressureStrategy: .init(lowWatermark: 1, highWatermark: 8)
        ) { channel -> EventLoopFuture<AdminConnection> in
          guard channels.register(channel) else {
            return channel.close().flatMapThrowing { throw ExecutionError.capacity }
          }
          let deadline = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            channel.close(promise: nil)
          }
          return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false)
            .flatMapThrowing {
              AdminConnection(
                socket: try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                  wrappingChannelSynchronously: channel,
                  configuration: .init(
                    backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4))),
                deadline: deadline)
            }.flatMapError { error in
              deadline.cancel()
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
                  tasks.addTask { do { try await serve(connection) } catch {} }
                }
              }
            }
          } onCancel: {
            channels.close()
          }
        } catch { guard Task.isCancelled else { throw error } }
      }
    } catch {
      await channels.shutdown()
      throw error
    }
    await channels.shutdown()
  }
  private func serve(_ connection: AdminConnection) async throws {
    defer { connection.deadline.cancel() }
    try await connection.socket.executeThenClose { inbound, _ in
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
              channel: connection.socket.channel)
            return
          }
          body.writeBuffer(&value)
        case .end:
          guard let head else { throw ExecutionError.invalidCommand }
          connection.deadline.cancel()
          let request = Request(
            application: app, method: head.method, url: URI(path: head.uri), version: head.version,
            headers: head.headers, collectedBody: body, on: connection.socket.channel.eventLoop)
          let response = try await app.responder.respond(to: request).get()
          guard let data = response.body.data, data.count <= 1_048_576 else {
            throw ExecutionError.capacity
          }
          try await write(
            status: response.status, headers: response.headers, body: data,
            channel: connection.socket.channel)
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
private struct AdminConnection: Sendable {
  let socket: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
  let deadline: Scheduled<Void>
}
