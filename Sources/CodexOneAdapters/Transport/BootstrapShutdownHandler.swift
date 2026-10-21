import NIOCore

// This guard precedes the HTTP pipeline: the pipelining handler can defer
// quiescing while it waits for an incomplete request body. Health-only
// connections have no admitted execution to drain and must close directly.
final class BootstrapShutdownHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is ChannelShouldQuiesceEvent {
      context.close(promise: nil)
    } else {
      context.fireUserInboundEventTriggered(event)
    }
  }
}
