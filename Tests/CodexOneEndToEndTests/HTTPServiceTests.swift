import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOCore
import NIOPosix
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct BoundListener: Sendable {
  let name: String
  let port: Int
}

@Test(.timeLimit(.minutes(1))) func actualListenersServeContractsAndReleasePortsOnCancellation()
  async throws
{
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let events = AsyncStream<BoundListener>.makeStream(bufferingPolicy: .bufferingNewest(2))
  let runtime = GatewayRuntime(services: [
    DataPlaneService(group: group, port: 0, report: .unconfigured) {
      events.continuation.yield(.init(name: "data", port: $0))
    },
    AdminService(group: group, port: 0, report: .unconfigured) {
      events.continuation.yield(.init(name: "admin", port: $0))
    },
  ])
  let task = Task { try await runtime.run(handleSignals: false) }
  do {
    var iterator = events.stream.makeAsyncIterator()
    var ports: [String: Int] = [:]
    for _ in 0..<2 {
      let event = try #require(await iterator.next())
      ports[event.name] = event.port
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    for name in ["data", "admin"] {
      let port = try #require(ports[name])
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health/ready")!)
      request.timeoutInterval = 3
      let (body, response) = try await session.data(for: request)
      #expect((response as? HTTPURLResponse)?.statusCode == 503)
      #expect(try JSONDecoder().decode(SystemStatusResponse.self, from: body).ready == false)
    }
    let admin = try #require(ports["admin"])
    let (body, response) = try await session.data(
      from: URL(string: "http://127.0.0.1:\(admin)/api/system")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(try JSONDecoder().decode(SystemStatusResponse.self, from: body).service == "codexone")
    task.cancel()
    _ = await task.result
    // Rebinding proves both listeners released their resources, not just a flag.
    for port in ports.values {
      let socket = try await ServerBootstrap(group: group).serverChannelOption(
        ChannelOptions.socketOption(.so_reuseaddr), value: 1
      ).bind(host: "127.0.0.1", port: port).get()
      try await socket.close().get()
    }
    try await group.shutdownGracefully()
  } catch {
    task.cancel()
    _ = await task.result
    try await group.shutdownGracefully()
    throw error
  }
}
