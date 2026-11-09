import CodexOneAdapters
import CodexOneRuntime
import NIOCore
import NIOPosix
import Testing

@testable import CodexOneCore

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func occupiedSecondListenerRollsBackLoopbackBinding(admin: Bool) async throws {
  #if os(Linux)
    let secondAddress = "127.0.0.2"
  #else
    let secondAddress = "::1"
  #endif
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
  var reservations: [any Channel] = []
  do {
    // Allocate on the primary address first. An ephemeral port on the other
    // address may already be in use on 127.0.0.1.
    let primary = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    reservations.append(primary)
    let port = try #require(primary.localAddress?.port)
    let occupied = try await bootstrap.bind(host: secondAddress, port: port).get()
    reservations.append(occupied)
    let listeners = try ListenerConfiguration(
      testLoopbackAddress: secondAddress, allowedNetworks: "127.0.0.0/8,::1/128")
    try await primary.close().get()
    if admin {
      await #expect(throws: (any Error).self) {
        try await AdminService(
          group: group, port: port, report: .unconfigured, listeners: listeners
        )
        .run()
      }
    } else {
      await #expect(throws: (any Error).self) {
        try await DataPlaneService(
          group: group, port: port, report: .unconfigured, listeners: listeners
        )
        .run()
      }
    }
    let rebound = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
    try await rebound.close().get()
    try await occupied.close().get()
  } catch {
    for channel in reservations {
      try? await channel.close().get()
    }
    try? await group.shutdownGracefully()
    throw error
  }
  try await group.shutdownGracefully()
}
