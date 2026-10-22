import CodexOneCore
import ServiceLifecycle
import Synchronization

/// One sequential poll, no growing timer/worker queue. Queue pressure yields; core failure propagates.
public final class StorageMonitor: Service, Sendable {
  private let storage: any StorageMonitoring
  private let state = Mutex((started: false, stopping: false))
  public init(storage: any StorageMonitoring) { self.storage = storage }
  public func run() async throws {
    try state.withLock { value in
      guard !value.started else { throw ExecutionError.conflict }
      value.started = true
    }
    defer { state.withLock { $0.stopping = true } }
    try await withGracefulShutdownHandler {
      while !self.state.withLock({ $0.stopping }) && !Task.isCancelled {
        do { try await self.storage.maintainStorage() } catch ExecutionError.capacity {}
        do { try await Task.sleep(for: .seconds(1)) } catch is CancellationError { return }
      }
    } onGracefulShutdown: {
      self.state.withLock { $0.stopping = true }
    }
  }
}
