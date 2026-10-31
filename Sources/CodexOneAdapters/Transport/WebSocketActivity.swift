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
