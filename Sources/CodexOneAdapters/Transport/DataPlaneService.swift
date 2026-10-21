import CodexOneCore
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOPosix
import ServiceLifecycle
import Synchronization

public struct DataPlaneService: Service {
  private let group: any EventLoopGroup
  private let port: Int
  private let report: ReadinessReport
  private let onBound: @Sendable (Int) -> Void

  public init(
    group: any EventLoopGroup, port: Int, report: ReadinessReport,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.group = group
    self.port = port
    self.report = report
    self.onBound = onBound
  }

  public func run() async throws {
    let quiescing = ServerQuiescingHelper(group: group)
    let capacity = ConnectionCapacity(limit: 128)
    let router = HealthRouter(report: report)
    let server = try await ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .serverChannelInitializer { channel in
        do {
          try channel.pipeline.syncOperations.addHandler(
            quiescing.makeServerChannelHandler(channel: channel))
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .childChannelInitializer { channel in
        guard capacity.acquire() else { return channel.close() }
        channel.closeFuture.whenComplete { _ in capacity.release() }
        do {
          try channel.pipeline.syncOperations.addHandler(BootstrapShutdownHandler())
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
        return channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
          try channel.pipeline.syncOperations.addHandlers([
            IdleStateHandler(readTimeout: .seconds(10)), HealthHTTPHandler(router: router),
          ])
        }
      }
      .bind(host: "127.0.0.1", port: port).get()
    onBound(server.localAddress!.port!)
    let closed = AsyncStream<Void> { continuation in
      server.closeFuture.whenComplete { _ in continuation.finish() }
    }
    // Stream cancellation wakes a silent listener without an unowned Task.
    await cancelWhenGracefulShutdown {
      for await _ in closed {}
    }
    let stopped = group.next().makePromise(of: Void.self)
    quiescing.initiateShutdown(promise: stopped)
    try await stopped.futureResult.get()
  }
}

private final class ConnectionCapacity: Sendable {
  private let used = Mutex(0)
  private let limit: Int
  init(limit: Int) { self.limit = limit }
  func acquire() -> Bool {
    used.withLock { count in
      guard count < limit else { return false }
      count += 1
      return true
    }
  }
  func release() { used.withLock { $0 -= 1 } }
}
