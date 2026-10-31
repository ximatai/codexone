import CodexOneCore
import Synchronization
import Testing

@testable import CodexOneRuntime

private final class MonitoredStorage: StorageMonitoring {
  let calls = Mutex(0)
  let fail: Bool
  init(fail: Bool) { self.fail = fail }
  var storageObservation: StorageObservation { .init() }
  func maintainStorage() async throws {
    calls.withLock { $0 += 1 }
    if fail { throw ExecutionError.storageUnavailable }
    throw ExecutionError.capacity
  }
}
@Test func storageMonitorYieldsToCapacityStopsOnCancellationAndPropagatesCoreFailure() async throws
{
  let capacity = MonitoredStorage(fail: false)
  let task = Task { try await StorageMonitor(storage: capacity).run() }
  while capacity.calls.withLock({ $0 }) == 0 { await Task.yield() }
  task.cancel()
  try await task.value
  #expect(capacity.calls.withLock({ $0 }) == 1)
  let failure = MonitoredStorage(fail: true)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await StorageMonitor(storage: failure).run()
  }
  #expect(failure.calls.withLock({ $0 }) == 1)
}

private final class MaintainedExecutions: ExecutionMaintaining {
  let calls = Mutex(0)
  let failure: ExecutionError
  init(_ failure: ExecutionError) { self.failure = failure }
  func maintainExecutions(now: Int64) async throws {
    calls.withLock { $0 += 1 }
    throw failure
  }
}
@Test func executionMaintenanceYieldsToPressureAndStopsOnCancellation() async throws {
  let pressure = MaintainedExecutions(.storagePressure)
  let task = Task { try await ExecutionMaintenanceSupervisor(maintenance: pressure).run() }
  while pressure.calls.withLock({ $0 }) == 0 { await Task.yield() }
  task.cancel()
  try await task.value
  #expect(pressure.calls.withLock({ $0 }) == 1)
  let failed = MaintainedExecutions(.storageUnavailable)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await ExecutionMaintenanceSupervisor(maintenance: failed).run()
  }
}
