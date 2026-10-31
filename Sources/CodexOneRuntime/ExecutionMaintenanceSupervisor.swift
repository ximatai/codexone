import CodexOneCore
import Foundation
import ServiceLifecycle
import Synchronization

/// One awaited worker; graceful shutdown cancels its timer and awaits any accepted transaction.
public final class ExecutionMaintenanceSupervisor: Service, Sendable {
  public static let intervalSeconds = 60
  private let maintenance: any ExecutionMaintaining
  private let started = Mutex(false)
  public init(maintenance: any ExecutionMaintaining) { self.maintenance = maintenance }
  public func run() async throws {
    try started.withLock {
      guard !$0 else { throw ExecutionError.conflict }
      $0 = true
    }
    try await cancelWhenGracefulShutdown {
      while !Task.isCancelled {
        do {
          try await self.maintenance.maintainExecutions(now: Int64(Date().timeIntervalSince1970))
        } catch ExecutionError.capacity {} catch ExecutionError.storagePressure {}
        do { try await Task.sleep(for: .seconds(Self.intervalSeconds)) } catch is CancellationError
        { return }
      }
    }
  }
}
