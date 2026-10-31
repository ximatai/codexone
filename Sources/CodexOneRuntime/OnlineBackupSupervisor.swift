import CodexOneCore
import ServiceLifecycle
import Synchronization

/// One sequential timer/worker, awaited before the primary store is closed.
public final class OnlineBackupSupervisor: Service, Sendable {
  public static let initialDelaySeconds = 600
  public static let intervalSeconds = 86400
  private let backup: any BackupMaintaining
  private let initialDelay: Int
  private let interval: Int
  private let state = Mutex((started: false, stopping: false))
  public init(backup: any BackupMaintaining) {
    self.backup = backup
    initialDelay = Self.initialDelaySeconds
    interval = Self.intervalSeconds
  }
  init(backup: any BackupMaintaining, initialDelay: Int, interval: Int) {
    self.backup = backup
    self.initialDelay = initialDelay
    self.interval = interval
  }
  public func run() async throws {
    try state.withLock {
      guard !$0.started else { throw ExecutionError.conflict }
      $0.started = true
    }
    try await withGracefulShutdownHandler {
      var remaining = self.initialDelay
      while !self.state.withLock({ $0.stopping }) && !Task.isCancelled {
        if remaining <= 0 {
          await self.backup.performBackup()
          remaining = self.interval
        }
        do { try await Task.sleep(for: .seconds(1)) } catch is CancellationError { return }
        remaining -= 1
      }
    } onGracefulShutdown: {
      self.state.withLock { $0.stopping = true }
      self.backup.cancelBackup()
    }
  }
}
