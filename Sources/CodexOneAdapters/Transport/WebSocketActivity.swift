import Foundation
import Synchronization

/// The downstream request-idle clock is suspended while any admitted/queued turn is owned.
final class WebSocketActivity: Sendable {
  private struct State {
    var count = 0
    var last = ContinuousClock.now
  }
  private let state = Mutex(State())
  func waitUntilIdle() async throws {
    while state.withLock({ $0.count != 0 }) {
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  func begin() { state.withLock { $0.count += 1 } }
  func end() {
    state.withLock {
      $0.count -= 1
      $0.last = .now
    }
  }
  func read<Value: Sendable>(
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { tasks in
      defer { tasks.cancelAll() }
      tasks.addTask { try await operation() }
      tasks.addTask {
        while true {
          try await Task.sleep(for: .seconds(1))
          if self.state.withLock({ $0.count == 0 && $0.last.duration(to: .now) >= .seconds(120) }) {
            throw GatewayProtocolError(504, "websocket_request_idle_timeout")
          }
        }
      }
      return try await tasks.next()!
    }
  }
}

/// The connection owner stops intake and waits for its owned turns before cancelling idle workers.
func readWebSocketCommand(
  _ downstream: WebSocketPeer, activity: WebSocketActivity, commands: WebSocketInbox
) async throws -> WebSocketBody {
  do {
    return try await activity.read { try await downstream.nextBody() }
  } catch {
    guard downstream.isClosed, !Task.isCancelled else { throw error }
    commands.finish(CancellationError())
    try await withExecutionDeadline(seconds: 10) { try await activity.waitUntilIdle() }
    throw CancellationError()
  }
}

/// Structured child tasks retain the existing execution deadline and runtime cancellation path.
func withWebSocketSettlement(
  downstream: WebSocketPeer, upstream: WebSocketPeer, lane: String,
  operation: @escaping @Sendable () async throws -> Void
) async throws {
  try await withThrowingTaskGroup(of: Void.self) { tasks in
    defer { tasks.cancelAll() }
    tasks.addTask { try await operation() }
    tasks.addTask {
      await downstream.waitForClose()
      try Task.checkCancellation()
      try await withThrowingTaskGroup(of: Void.self) { settlement in
        defer { settlement.cancelAll() }
        settlement.addTask {
          try await upstream.interruptForSettlement(lane: lane)
          try await Task.sleep(for: .seconds(10))
        }
        settlement.addTask { try await Task.sleep(for: .seconds(10)) }
        try await settlement.next()
      }
      throw CancellationError()
    }
    try await tasks.next()
  }
}
