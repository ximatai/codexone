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
