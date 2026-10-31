import CodexOneCore
import Foundation
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Synchronization

struct WebSocketUpstream: Sendable {
  let group: any EventLoopGroup
  let configuration: ResponsesConfiguration
  let token: String?
  var clientHeaders = HTTPHeaders()
  var proxy: UpstreamHTTPProxy? = nil
  var authorization: SubscriptionDataAccess? = nil
  func authorized(_ authorization: SubscriptionDataAccess?, headers: HTTPHeaders) -> Self {
    Self(
      group: group, configuration: configuration, token: token, clientHeaders: headers,
      proxy: proxy,
      authorization: authorization)
  }

  private func establishProxy(channel: Channel, targetHost: String, targetPort: Int)
    -> EventLoopFuture<Void>
  {
    guard proxy != nil else { return channel.eventLoop.makeSucceededVoidFuture() }
    let promise = channel.eventLoop.makePromise(of: Void.self)
    let observed = UpstreamProxyStatus()
    let encoder = HTTPRequestEncoder()
    let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
    do {
      try channel.pipeline.syncOperations.addHandler(encoder, name: "upstream-proxy-encoder")
      try channel.pipeline.syncOperations.addHandler(decoder, name: "upstream-proxy-decoder")
      try channel.pipeline.syncOperations.addHandler(observed)
      try channel.pipeline.syncOperations.addHandler(
        NIOHTTP1ProxyConnectHandler(
          targetHost: targetHost, targetPort: targetPort, headers: [:],
          deadline: .now() + .seconds(10), promise: promise))
    } catch { promise.fail(error) }
    return promise.futureResult.flatMap {
      channel.pipeline.removeHandler(name: "upstream-proxy-decoder").flatMap {
        channel.pipeline.removeHandler(name: "upstream-proxy-encoder")
      }.flatMap { channel.pipeline.removeHandler(observed) }
    }.flatMapErrorThrowing { _ in
      throw GatewayProtocolError(
        502,
        observed.status == 407 ? "upstream_proxy_authentication_required" : "upstream_proxy_failed",
        upstreamStatus: observed.status)
    }
  }

  func run(operation: @escaping @Sendable (WebSocketPeer) async throws -> Void) async throws {
    let url = URLComponents(string: authorization?.baseURL ?? configuration.upstreamBaseURL)!
    let host = url.host!
    let tls = url.scheme == "https"
    let tlsContext = try tls ? NIOSSLContext(configuration: .makeClientConfiguration()) : nil
    let channels = ProtocolChannels(limit: 1)
    do {
      try await withTaskCancellationHandler {
        let negotiated = try await ClientBootstrap(group: group).connectTimeout(.seconds(10))
          .channelOption(
            ChannelOptions.recvAllocator,
            value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 65_536)
          )
          .connect(host: proxy?.host ?? host, port: proxy?.port ?? url.port ?? (tls ? 443 : 80)) {
            channel -> EventLoopFuture<EventLoopFuture<ProtocolWebSocket>> in
            guard channels.register(channel) else {
              return channel.close().flatMapThrowing { throw CancellationError() }
            }
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) {
              channel.close(promise: nil)
            }
            let ready = establishProxy(
              channel: channel, targetHost: host, targetPort: url.port ?? (tls ? 443 : 80))
            let upgraded = ready.flatMap {
              channel.eventLoop.makeCompletedFuture {
                () throws -> EventLoopFuture<ProtocolWebSocket> in
                if let tlsContext {
                  try channel.pipeline.syncOperations.addHandler(
                    NIOSSLClientHandler(context: tlsContext, serverHostname: host))
                }
                var headers = clientHeaders
                headers.replaceOrAdd(
                  name: "host", value: url.port.map { host + ":" + String($0) } ?? host)
                if let authorization {
                  for header in authorization.headers {
                    headers.add(name: header.name, value: header.value)
                  }
                } else if let token {
                  headers.add(name: "authorization", value: "Bearer " + token)
                }
                let observed = UpstreamUpgradeStatus()
                let upgrader = NIOTypedWebSocketClientUpgrader<ProtocolWebSocket>(
                  maxFrameSize: ImageLimits.eventBytes,
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
                      version: .http1_1, method: .GET, uri: url.path + "/responses",
                      headers: headers),
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
              }.flatMap { $0 }
            }.flatMapError { error in
              channel.close().flatMapError { _ in channel.eventLoop.makeSucceededVoidFuture() }
                .flatMapThrowing { throw error }
            }
            upgraded.whenComplete { _ in timeout.cancel() }
            return channel.eventLoop.makeSucceededFuture(upgraded)
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
        $0 =
          mapped.code == "upstream_rejected"
          ? .init(
            502, "upstream_upgrade_rejected", upstreamStatus: Int(head.status.code),
            explicitProviderRejection: (400...499).contains(Int(head.status.code))) : mapped
      }
    }
    context.fireChannelRead(data)
  }
}

private final class UpstreamProxyStatus: ChannelInboundHandler, RemovableChannelHandler, Sendable {
  typealias InboundIn = HTTPClientResponsePart
  private let value = Mutex<Int?>(nil)
  var status: Int? { value.withLock { $0 } }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if case .head(let head) = unwrapInboundIn(data) {
      value.withLock { $0 = Int(head.status.code) }
    }
    context.fireChannelRead(data)
  }
}
