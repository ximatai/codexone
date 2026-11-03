import Foundation
import Synchronization

/// Preserve timeout classification when an enclosing total deadline cancels transport work.
/// Nested phase deadlines inherit the outer cause; client cancellation never marks it expired.
enum ExecutionDeadlineScope {
  @TaskLocal static var cause: ExecutionDeadlineCause?
}
final class ExecutionDeadlineCause: Sendable {
  private let expired = Mutex(false)
  private let parent: ExecutionDeadlineCause?
  init(parent: ExecutionDeadlineCause?) { self.parent = parent }
  func expire() { expired.withLock { $0 = true } }
  var hasExpired: Bool { expired.withLock { $0 } || parent?.hasExpired == true }
}

struct ExecutionBudget: Sendable {
  let total: Int
  let first: Int
  let idle: Int
  init(total: Int? = nil, first: Int? = nil, idle: Int? = nil) throws {
    let total = total ?? 600
    guard (1...1800).contains(total),
      (1...min(total, 120)).contains(first ?? min(total, 30)),
      (1...min(total, 300)).contains(idle ?? min(total, 60))
    else { throw GatewayProtocolError(400, "invalid_execution_budget") }
    self.total = total
    self.first = first ?? min(total, 30)
    self.idle = idle ?? min(total, 60)
  }
}

/// One bounded monitor per turn; control frames and SSE comments never call this owner.
final class ExecutionProgress: Sendable {
  private struct State {
    var received = false
    var deadline: ContinuousClock.Instant?
  }
  private let state: Mutex<State>
  private let first: Int
  private let idle: Int
  init(_ budget: ExecutionBudget) {
    first = budget.first
    idle = budget.idle
    state = Mutex(.init())
  }
  func negotiateUpload() {
    state.withLock { if !$0.received { $0.deadline = nil } }
  }
  func requestSent() {
    state.withLock { value in
      guard !value.received, value.deadline == nil else { return }
      value.deadline = .now.advanced(by: .seconds(first))
    }
  }
  func note(event: JSONValue? = nil) {
    state.withLock { value in
      let type = event?["type"]?.string
      if type?.hasSuffix(".delta") == true && event?["delta"]?.string?.isEmpty != false { return }
      if value.received && ["response.created", "response.in_progress"].contains(type ?? "") {
        return
      }
      value.received = true
      value.deadline = .now.advanced(by: .seconds(idle))
    }
  }
  func waitForExpiry<Value: Sendable>() async throws -> Value {
    while true {
      // Phase changes can shorten the deadline (first response -> idle).
      // A bounded poll avoids retaining a stale longer sleep across that transition.
      try await Task.sleep(for: .milliseconds(100))
      let expired = state.withLock { value -> Bool? in
        guard let deadline = value.deadline else { return nil }
        return ContinuousClock.now >= deadline ? value.received : nil
      }
      if let received = expired {
        throw GatewayProtocolError(
          504, received ? "execution_progress_timeout" : "execution_first_response_timeout")
      }
    }
  }
}

func withProgressDeadline<Value: Sendable>(
  budget: ExecutionBudget,
  operation: @escaping @Sendable (ExecutionProgress) async throws -> Value
) async throws -> Value {
  let progress = ExecutionProgress(budget)
  return try await withThrowingTaskGroup(of: Value.self) { group in
    defer { group.cancelAll() }
    group.addTask { try await operation(progress) }
    group.addTask {
      try await progress.waitForExpiry()
    }
    group.addTask {
      try await Task.sleep(for: .seconds(budget.total))
      throw GatewayProtocolError(504, "execution_deadline_exceeded")
    }
    return try await group.next()!
  }
}
