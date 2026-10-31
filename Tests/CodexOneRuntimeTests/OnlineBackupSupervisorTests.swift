import CodexOneCore
import Synchronization
import Testing

@testable import CodexOneRuntime

private final class BackupProbe: BackupMaintaining {
  let calls = Mutex(0)
  var backupObservation: BackupObservation { .init() }
  func performBackup() async { calls.withLock { $0 += 1 } }
  func cancelBackup() {}
}
@Test func backupSupervisorWaitsInitiallyRunsSequentiallyAndStopsOnCancellation() async throws {
  #expect(OnlineBackupSupervisor.initialDelaySeconds == 600)
  #expect(OnlineBackupSupervisor.intervalSeconds == 86400)
  let delayed = BackupProbe()
  let first = Task { try await OnlineBackupSupervisor(backup: delayed).run() }
  await Task.yield()
  first.cancel()
  try await first.value
  #expect(delayed.calls.withLock { $0 } == 0)
  let immediate = BackupProbe()
  let supervisor = OnlineBackupSupervisor(backup: immediate, initialDelay: 0, interval: 86400)
  let task = Task { try await supervisor.run() }
  while immediate.calls.withLock({ $0 }) == 0 { await Task.yield() }
  task.cancel()
  try await task.value
  #expect(immediate.calls.withLock { $0 } == 1)
  await #expect(throws: ExecutionError.conflict) { try await supervisor.run() }
}
