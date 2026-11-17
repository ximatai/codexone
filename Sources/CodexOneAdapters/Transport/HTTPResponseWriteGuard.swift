import NIOCore
import NIOHTTP1

/// Check application writes before they reach the HTTP/1 protocol handler.
final class HTTPResponseWriteGuard: ChannelOutboundHandler {
  typealias OutboundIn = HTTPServerResponsePart

  private var responseOpen = false
  private var rejected = false
  private var lastResponseID: String?

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    guard !rejected else {
      promise?.fail(ChannelError.ioOnClosedChannel)
      return
    }
    let invalidPart: String?
    switch unwrapOutboundIn(data) {
    case .head(let head):
      invalidPart = responseOpen ? "head" : nil
      let status = head.status.code
      if invalidPart == nil && (!(100..<200).contains(status) || status == 101) {
        responseOpen = true
        lastResponseID = head.headers.first(name: "x-request-id")
      }
    case .body:
      invalidPart = responseOpen ? nil : "body"
    case .end:
      invalidPart = responseOpen ? nil : "end"
      responseOpen = false
    }
    if let invalidPart {
      rejected = true
      ProtocolFailureDiagnostics.recordHTTPResponseWriteViolation(
        part: invalidPart, lastResponseID: lastResponseID)
      promise?.fail(ChannelError.inappropriateOperationForState)
      context.close(promise: nil)
      return
    }
    context.write(data, promise: promise)
  }
}
