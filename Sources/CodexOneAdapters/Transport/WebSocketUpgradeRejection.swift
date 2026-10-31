import Foundation
import NIOCore
import NIOHTTP1

/// A declined typed upgrade consumes its HTTP request; reject before handing back control.
func rejectWebSocketUpgrade(_ channel: any Channel, error: any Error) -> EventLoopFuture<Void> {
  channel.eventLoop.flatSubmit {
    do {
      let mapped = protocolFailure(error)
      let requestID = UUID().uuidString
      let data = try protocolErrorEnvelope(error, requestID: requestID).data()
      var headers: HTTPHeaders = [
        "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
        "content-length": String(data.count), "x-request-id": requestID, "connection": "close",
      ]
      if let seconds = mapped.cooldownSeconds {
        headers.add(name: "retry-after", value: String(seconds))
      }
      channel.write(
        HTTPServerResponsePart.head(
          .init(version: .http1_1, status: .init(statusCode: mapped.status), headers: headers)),
        promise: nil)
      channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(data: data))), promise: nil)
      return channel.writeAndFlush(HTTPServerResponsePart.end(nil)).flatMap {
        channel.close()
      }
    } catch {
      return channel.close().flatMapThrowing { throw error }
    }
  }
}
