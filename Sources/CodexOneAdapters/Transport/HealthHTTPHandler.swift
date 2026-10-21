import Foundation
import NIOCore
import NIOHTTP1

// All mutable state is owned by this channel's event loop.
final class HealthHTTPHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let router: HealthRouter
  private var head: HTTPRequestHead?
  private var bodyBytes = 0
  private var rejected = false
  private let maximumBodyBytes: Int

  init(router: HealthRouter, maximumBodyBytes: Int = 4096) {
    self.router = router
    self.maximumBodyBytes = maximumBodyBytes
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      self.head = head
      bodyBytes = 0
      rejected = false
    case .body(let body):
      guard !rejected else { return }
      // No request body is collected by a health-only bootstrap.
      if body.readableBytes > maximumBodyBytes - bodyBytes {
        rejected = true
        send(
          HTTPReply(status: 413, body: Data(#"{"error":{"code":"request_too_large"}}"#.utf8)),
          keepAlive: false, context: context)
      } else {
        bodyBytes += body.readableBytes
      }
    case .end:
      guard !rejected, let head else { return }
      send(
        router.reply(method: head.method.rawValue, uri: head.uri),
        keepAlive: head.isKeepAlive, context: context)
      self.head = nil
    }
  }

  private func send(_ reply: HTTPReply, keepAlive: Bool, context: ChannelHandlerContext) {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "application/json; charset=utf-8")
    headers.add(name: "content-length", value: String(reply.body.count))
    headers.add(name: "cache-control", value: "no-store")
    if !keepAlive { headers.add(name: "connection", value: "close") }
    context.write(
      wrapOutboundOut(
        .head(
          HTTPResponseHead(
            version: .http1_1, status: HTTPResponseStatus(statusCode: reply.status),
            headers: headers))), promise: nil)
    context.write(
      wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: reply.body)))),
      promise: nil)
    let end = context.writeAndFlush(wrapOutboundOut(.end(nil)))
    if !keepAlive {
      let channel = context.channel
      end.whenComplete { _ in channel.close(promise: nil) }
    }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is ChannelShouldQuiesceEvent || event is IdleStateHandler.IdleStateEvent {
      context.close(promise: nil)
    } else {
      context.fireUserInboundEventTriggered(event)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}
