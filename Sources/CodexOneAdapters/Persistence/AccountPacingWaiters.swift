import CodexOneCore
import Foundation
import Synchronization

/// Owned by the store; close cancels every timer before database shutdown.
final class AccountPacingWaiters: Sendable {
  private struct State {
    var closed = false
    var tasks: [UUID: Task<Void, any Error>] = [:]
  }
  private let state = Mutex(State())
  private let sleep: @Sendable (Double) async throws -> Void
  init(
    sleep: @escaping @Sendable (Double) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) { self.sleep = sleep }
  var count: Int { state.withLock { $0.tasks.count } }

  func wait(seconds: Double) async throws {
    try Task.checkCancellation()
    guard seconds > 0, seconds <= OverloadPacing.maximumWaitSeconds else {
      throw ExecutionError.invalidCommand
    }
    let id = UUID()
    let task = try state.withLock { value in
      guard !value.closed else { throw ExecutionError.closed }
      guard value.tasks.count < OverloadPacing.maximumWaiters else { throw ExecutionError.capacity }
      let task = Task { try await sleep(seconds) }
      value.tasks[id] = task
      return task
    }
    defer { state.withLock { $0.tasks[id] = nil } }
    try await withTaskCancellationHandler {
      try await task.value
      try Task.checkCancellation()
    } onCancel: {
      task.cancel()
    }
  }
  func close() async {
    let tasks = state.withLock { value in
      value.closed = true
      let tasks = Array(value.tasks.values)
      for task in tasks { task.cancel() }
      return tasks
    }
    for task in tasks { _ = await task.result }
  }
}
extension SQLiteExecutionStore {
  public func waitForAccountPacing(seconds: Double) async throws {
    try await pacingWaiters.wait(seconds: seconds)
  }
}
