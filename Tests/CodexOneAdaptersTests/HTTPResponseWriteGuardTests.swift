import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import CodexOneAdapters

@Test func invalidHTTPResponseWriteClosesOnlyItsConnection() throws {
  let healthy = EmbeddedChannel(handlers: [
    HTTPServerProtocolErrorHandler(), HTTPResponseWriteGuard(),
  ])
  let broken = EmbeddedChannel(handlers: [
    HTTPServerProtocolErrorHandler(), HTTPResponseWriteGuard(),
  ])
  defer {
    _ = try? broken.finish()
    _ = try? healthy.finish()
  }
  let address = try SocketAddress(ipAddress: "127.0.0.1", port: 18080)
  try healthy.connect(to: address).wait()
  try broken.connect(to: address).wait()

  let body = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "example")))
  #expect(throws: ChannelError.inappropriateOperationForState) {
    try broken.writeOutbound(body)
  }
  #expect(!broken.isActive)
  #expect(try broken.readOutbound(as: HTTPServerResponsePart.self) == nil)
  #expect(healthy.isActive)

  for _ in 0..<2 {
    try healthy.writeOutbound(
      HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
    try healthy.writeOutbound(body)
    try healthy.writeOutbound(HTTPServerResponsePart.end(nil))
  }
  let output = try (0..<6).map { _ in
    try healthy.readOutbound(as: HTTPServerResponsePart.self)
  }
  guard case .head? = output[0], case .body? = output[1], case .end? = output[2],
    case .head? = output[3], case .body? = output[4], case .end? = output[5]
  else {
    Issue.record("Expected two complete responses in order")
    return
  }
  #expect(healthy.isActive)
}
