import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import Testing

@testable import CodexOneAdapters

// Bypass the public synthetic configuration's literal-IPv4 restriction only at this adapter boundary.
@Test func webSocketDirectHostnameFallsBackToIPv4() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let accepted = ProtocolChannels(limit: 4)
  let upgraded = Mutex(false)
  let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    guard accepted.register(channel) else { return channel.close() }
    let upgrader = NIOWebSocketServerUpgrader(
      shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
      upgradePipelineHandler: { channel, _ in
        upgraded.withLock { $0 = true }
        return channel.eventLoop.makeSucceededVoidFuture()
      })
    return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: ([upgrader], { _ in }))
  }.bind(host: "127.0.0.1", port: 0).get()
  do {
    let port = try #require(listener.localAddress?.port)
    let upstream = WebSocketUpstream(
      group: group,
      configuration: .init(
        models: [], upstreamBaseURL: "http://localhost:\(port)/v1",
        executionTimeoutSeconds: 15, upstreamTransport: "websocket"), token: nil)
    try await upstream.run { _ in }
    #expect(upgraded.withLock { $0 })
    try await listener.close().get()
    await accepted.shutdown()
    try await group.shutdownGracefully()
  } catch {
    try? await listener.close().get()
    await accepted.shutdown()
    try? await group.shutdownGracefully()
    throw error
  }
}

private struct CandidateResolver: Resolver, Sendable {
  let loop: any EventLoop
  var repeats = 1
  func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    loop.makeCompletedFuture {
      try Array(repeating: SocketAddress(ipAddress: "127.0.0.1", port: port), count: repeats)
    }
  }
  func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    loop.makeCompletedFuture {
      try Array(repeating: SocketAddress(ipAddress: "::1", port: port), count: repeats)
    }
  }
  func cancelQueries() {}
}

// Hold initializers before TCP connect: every candidate remains live and observable, without relying
// on an external blackhole address, packet filtering, or a machine-specific TCP timeout.
@Test(arguments: ["cancel", "timeout", "shutdown"])
func webSocketCandidateOwnershipEndsAllPendingChannels(ending: String) async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let owner = ProtocolChannels(limit: 64)
  let observed = Mutex<[any Channel]>([])
  let connecting = Task {
    do {
      try await withTaskCancellationHandler {
        let channel = try await ClientBootstrap(group: group)
          .resolver(CandidateResolver(loop: group.next(), repeats: 4))
          .connectTimeout(.milliseconds(900))
          .channelInitializer { channel in
            guard owner.register(channel) else {
              return channel.close().flatMapThrowing { throw CancellationError() }
            }
            observed.withLock { $0.append(channel) }
            let initialized = channel.eventLoop.makePromise(of: Void.self)
            channel.closeFuture.whenComplete { _ in initialized.fail(ChannelError.ioOnClosedChannel)
            }
            return initialized.futureResult
          }.connect(host: "synthetic.invalid", port: 12345).get()
        try await channel.close().get()
        Issue.record("Held initializers must never connect")
      } onCancel: {
        owner.close()
      }
    } catch {
      if ending == "timeout" {
        guard let failure = error as? ChannelError, case .connectTimeout = failure else {
          Issue.record("Expected the bootstrap connect timeout")
          await owner.shutdown()
          return
        }
      }
    }
    await owner.shutdown()
  }
  do {
    let deadline = ContinuousClock.now + .seconds(3)
    while observed.withLock({ $0.count }) < 3 {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    if ending == "cancel" { connecting.cancel() }
    if ending == "shutdown" { await owner.shutdown() }
    await connecting.value
    let candidates = observed.withLock { $0 }
    #expect(candidates.count >= 3)
    for candidate in candidates { try await candidate.closeFuture.get() }
    try await group.shutdownGracefully()
  } catch {
    connecting.cancel()
    await owner.shutdown()
    await connecting.value
    try? await group.shutdownGracefully()
    throw error
  }
}

@Test func happyEyeballsStartsFallbackBeforeFailedChannelCloseCompletes() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let accepted = ProtocolChannels(limit: 4)
  let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    _ = accepted.register(channel)
    return channel.eventLoop.makeSucceededVoidFuture()
  }.bind(host: "127.0.0.1", port: 0).get()
  do {
    let port = try #require(listener.localAddress?.port)
    for limit in [1, 64] {
      let owner = ProtocolChannels(limit: limit)
      let rejected = Mutex(0)
      let candidates = Mutex<[any Channel]>([])
      do {
        let channel = try await ClientBootstrap(group: group)
          .resolver(CandidateResolver(loop: group.next()))
          .connectTimeout(.seconds(2))
          .channelInitializer { channel in
            candidates.withLock { $0.append(channel) }
            guard owner.register(channel) else {
              rejected.withLock { $0 += 1 }
              return channel.close().flatMapThrowing { throw CancellationError() }
            }
            return channel.eventLoop.makeSucceededVoidFuture()
          }.connect(host: "synthetic.invalid", port: port).get()
        #expect(limit > 1)
        #expect(channel.remoteAddress?.ipAddress == "127.0.0.1")
      } catch {
        #expect(limit == 1)
        let failure = try #require(error as? NIOConnectionError)
        #expect(failure.connectionErrors.contains { $0.error is CancellationError })
      }
      #expect(candidates.withLock { $0.count } >= 2)
      #expect((rejected.withLock { $0 } > 0) == (limit == 1))
      // The refused IPv6 candidate must close through NIO before the owner is shut down.
      let attempted = candidates.withLock { $0 }
      try await attempted[0].closeFuture.get()
      await owner.shutdown()
      for channel in attempted { try await channel.closeFuture.get() }
    }
    try await listener.close().get()
    await accepted.shutdown()
    try await group.shutdownGracefully()
  } catch {
    try? await listener.close().get()
    await accepted.shutdown()
    try? await group.shutdownGracefully()
    throw error
  }
}
