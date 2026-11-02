import CodexOneCore
import Testing

@testable import CodexOneAdapters

@Test(.timeLimit(.minutes(1))) func overloadWaitersBoundCapacityCancelAndClose() async throws {
  let entered = AsyncStream<Void>.makeStream()
  let waiters = AccountPacingWaiters { _ in
    entered.continuation.yield(())
    try await Task.sleep(for: .seconds(3600))
  }
  let tasks = (0..<OverloadPacing.maximumWaiters).map { _ in
    Task { try await waiters.wait(seconds: 1) }
  }
  var arrivals = entered.stream.makeAsyncIterator()
  for _ in tasks { _ = await arrivals.next() }
  #expect(waiters.count == OverloadPacing.maximumWaiters)
  await #expect(throws: ExecutionError.capacity) { try await waiters.wait(seconds: 1) }
  tasks[0].cancel()
  await #expect(throws: CancellationError.self) { try await tasks[0].value }
  #expect(waiters.count == OverloadPacing.maximumWaiters - 1)
  await waiters.close()
  for task in tasks { _ = await task.result }
  #expect(waiters.count == 0)
  await #expect(throws: ExecutionError.closed) { try await waiters.wait(seconds: 1) }
}

@Test func overloadDeadlineCancellationPreservesNestedCauseAndClientCancellation() async throws {
  let outer = ExecutionDeadlineCause(parent: nil)
  let inner = ExecutionDeadlineCause(parent: outer)
  #expect(executionFailure(CancellationError()) == .clientCancelled)
  ExecutionDeadlineScope.$cause.withValue(inner) {
    #expect(executionFailure(CancellationError()) == .clientCancelled)
    outer.expire()
    #expect(executionFailure(CancellationError()) == .deadlineExceeded)
  }
}
