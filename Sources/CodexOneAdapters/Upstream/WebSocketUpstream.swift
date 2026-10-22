import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Synchronization

struct WebSocketUpstream: Sendable {
  let group: any EventLoopGroup
  let configuration: ResponsesConfiguration
  let token: String?
  var authorization: SubscriptionDataAccess? = nil
  func authorized(_ authorization: SubscriptionDataAccess?) -> Self {
    Self(group: group, configuration: configuration, token: token, authorization: authorization)
  }

  func run(operation: @escaping @Sendable (WebSocketPeer) async throws -> Void) async throws {
    let url = URLComponents(string: authorization?.baseURL ?? configuration.upstreamBaseURL)!
    let host = url.host!
    let tls = url.scheme == "https"
    let tlsContext = try tls ? NIOSSLContext(configuration: .makeClientConfiguration()) : nil
    let channels = ProtocolChannels(limit: 1)
    do {
      try await withTaskCancellationHandler {
        let negotiated = try await ClientBootstrap(group: group).connectTimeout(.seconds(5))
          .channelOption(
            ChannelOptions.recvAllocator,
            value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 65_536)
          )
          .connect(host: host, port: url.port ?? (tls ? 443 : 80)) {
            channel -> EventLoopFuture<EventLoopFuture<ProtocolWebSocket>> in
            guard channels.register(channel) else {
              return channel.close().flatMapThrowing { throw CancellationError() }
            }
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
              channel.close(promise: nil)
            }
            return channel.eventLoop.makeCompletedFuture {
              () throws -> EventLoopFuture<ProtocolWebSocket> in
              if let tlsContext {
                try channel.pipeline.syncOperations.addHandler(
                  NIOSSLClientHandler(context: tlsContext, serverHostname: host))
              }
              var headers: HTTPHeaders = ["host": url.port.map { host + ":" + String($0) } ?? host]
              if let authorization {
                for header in authorization.headers {
                  headers.add(name: header.name, value: header.value)
                }
              } else if let token {
                headers.add(name: "authorization", value: "Bearer " + token)
              }
              let observed = UpstreamUpgradeStatus()
              let upgrader = NIOTypedWebSocketClientUpgrader<ProtocolWebSocket>(
                maxFrameSize: 524_288,
                upgradePipelineHandler: { channel, _ in
                  channel.pipeline.removeHandler(observed).flatMap {
                    channel.eventLoop.makeCompletedFuture {
                      try configureWebSocket(channel, client: true)
                    }
                  }
                })
              var pipeline = NIOUpgradableHTTPClientPipelineConfiguration(
                upgradeConfiguration: .init(
                  upgradeRequestHead: .init(
                    version: .http1_1, method: .GET, uri: url.path + "/responses", headers: headers),
                  upgraders: [upgrader],
                  notUpgradingCompletionHandler: { channel in
                    let failure = observed.rejection
                    return channel.close().flatMapThrowing {
                      throw failure
                    }
                  }))
              pipeline.leftOverBytesStrategy = .forwardBytes
              let result = try channel.pipeline.syncOperations
                .configureUpgradableHTTPClientPipeline(
                  configuration: pipeline)
              let handler = try channel.pipeline.syncOperations.handler(
                type: NIOTypedHTTPClientUpgradeHandler<ProtocolWebSocket>.self)
              try channel.pipeline.syncOperations.addHandler(observed, position: .before(handler))
              return result
            }.map { future in
              future.whenComplete { _ in timeout.cancel() }
              return future
            }.flatMapError { error in
              channel.close().flatMapThrowing { throw error }
            }
          }
        let socket = try await negotiated.get()
        try await WebSocketPeer.run(socket, client: true, operation: operation)
      } onCancel: {
        channels.close()
      }
    } catch {
      await channels.shutdown()
      throw error
    }
    await channels.shutdown()
  }
}

/// Observe only normalized rejection metadata before the typed upgrader consumes the head.
private final class UpstreamUpgradeStatus: ChannelInboundHandler, RemovableChannelHandler, Sendable
{
  typealias InboundIn = HTTPClientResponsePart
  private let failure = Mutex<GatewayProtocolError?>(nil)
  var rejection: GatewayProtocolError {
    failure.withLock { $0 ?? .init(502, "upstream_upgrade_rejected") }
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if case .head(let head) = unwrapInboundIn(data), head.status.code >= 200 {
      let mapped = upstreamRejection(status: head.status, headers: head.headers)
      failure.withLock {
        $0 = mapped.code == "upstream_rejected" ? .init(502, "upstream_upgrade_rejected") : mapped
      }
    }
    context.fireChannelRead(data)
  }
}
