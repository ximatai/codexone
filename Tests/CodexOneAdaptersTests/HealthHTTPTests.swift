import CodexOneCore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import CodexOneAdapters

@Test func statusDTOAgreesWithSharedFrontendContract() throws {
  let url = try #require(
    Bundle.module.url(forResource: "system-status", withExtension: "json", subdirectory: "Fixtures")
  )
  let fixture = try JSONDecoder().decode(SystemStatusResponse.self, from: Data(contentsOf: url))
  #expect(SystemStatusResponse(report: .unconfigured) == fixture)
}

@Test func httpPipelineDoesNotAdvertiseReadinessAndSupportsKeepAlive() throws {
  let channel = EmbeddedChannel(
    handler: HealthHTTPHandler(router: HealthRouter(report: .unconfigured)))
  defer { _ = try? channel.finish() }
  try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 18080)).wait()
  for (method, path, expected) in [
    (HTTPMethod.GET, "/health/live", 200), (.GET, "/health/ready", 503),
    (.POST, "/v1/responses", 503), (.GET, "/missing", 404),
  ] {
    try channel.writeInbound(
      HTTPServerRequestPart.head(.init(version: .http1_1, method: method, uri: path)))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
    let head = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
    guard case .head(let response) = head else {
      Issue.record("Expected HTTP response head")
      return
    }
    #expect(response.status.code == UInt(expected))
    #expect(response.headers.first(name: "cache-control") == "no-store")
    #expect(try channel.readOutbound(as: HTTPServerResponsePart.self) != nil)
    #expect(try channel.readOutbound(as: HTTPServerResponsePart.self) != nil)
    #expect(channel.isActive)
  }
}

@Test func oversizedBodyIsRejectedWithoutCollectingIt() throws {
  let channel = EmbeddedChannel(
    handler: HealthHTTPHandler(router: HealthRouter(report: .unconfigured), maximumBodyBytes: 4))
  defer { _ = try? channel.finish() }
  try channel.writeInbound(
    HTTPServerRequestPart.head(.init(version: .http1_1, method: .POST, uri: "/v1/responses")))
  try channel.writeInbound(HTTPServerRequestPart.body(channel.allocator.buffer(string: "12345")))
  let response = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
  guard case .head(let head) = response else {
    Issue.record("Expected 413 head")
    return
  }
  #expect(head.status == .payloadTooLarge)
  channel.embeddedEventLoop.run()
  #expect(!channel.isActive)
}
