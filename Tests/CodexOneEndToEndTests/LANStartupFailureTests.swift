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
  let occupied = try await ServerBootstrap(group: group)
    .bind(host: secondAddress, port: 0).get()
  let port = occupied.localAddress!.port!
  let listeners = try ListenerConfiguration(
    testLoopbackAddress: secondAddress, allowedNetworks: "127.0.0.0/8,::1/128")
  do {
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
    let rebound = try await ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .bind(host: "127.0.0.1", port: port).get()
    try await rebound.close().get()
  } catch {
    try await occupied.close().get()
    try await group.shutdownGracefully()
    throw error
  }
  try await occupied.close().get()
  try await group.shutdownGracefully()
}
