import Foundation
import Synchronization

/// Preserve timeout classification when an enclosing total deadline cancels transport work.
/// Nested phase deadlines inherit the outer cause; client cancellation never marks it expired.
enum ExecutionDeadlineScope {
  @TaskLocal static var cause: ExecutionDeadlineCause?
  @TaskLocal static var trace: ExecutionTimeoutTrace?
}
final class ExecutionDeadlineCause: Sendable {
  private let expired = Mutex(false)
  private let parent: ExecutionDeadlineCause?
  init(parent: ExecutionDeadlineCause?) { self.parent = parent }
  func expire() { expired.withLock { $0 = true } }
  var hasExpired: Bool { expired.withLock { $0 } || parent?.hasExpired == true }
}

enum ExecutionTimeoutReason: String, Sendable {
  case firstResponse = "execution_first_response_timeout"
  case progress = "execution_progress_timeout"
  case total = "execution_deadline_exceeded"

  var error: GatewayProtocolError { .init(504, rawValue) }
}

/// Shared by timers for one Responses request, including the two first-turn WS owners.
final class ExecutionTimeoutTrace: Sendable {
  struct Observation: Sendable {
    let reason: ExecutionTimeoutReason
    let progress: ExecutionProgress.Snapshot?
  }

  private struct State {
    var progress: ExecutionProgress?
    var previous: ExecutionProgress.Snapshot?
    var timeout: Observation?
  }
  private let state = Mutex(State())
  private let requestID: String

  init(requestID: String) { self.requestID = requestID }

  func attach(_ progress: ExecutionProgress) {
    state.withLock { $0.progress = progress }
  }

  func detach(_ progress: ExecutionProgress) {
    state.withLock { value in
      guard value.progress === progress else { return }
      let snapshot = progress.snapshot()
      if snapshot.lastEvent != nil {
        value.previous = .init(
          lastEvent: snapshot.lastEvent, lastEventAt: snapshot.lastEventAt, remaining: nil)
      }
      value.progress = nil
    }
  }

  func capture(_ reason: ExecutionTimeoutReason, snapshot: ExecutionProgress.Snapshot? = nil) {
    state.withLock { value in
      guard value.timeout == nil else { return }
      let current = snapshot ?? value.progress?.snapshot()
      let last = current?.lastEvent != nil ? current : value.previous
      let progress = ExecutionProgress.Snapshot(
        lastEvent: last?.lastEvent, lastEventAt: last?.lastEventAt, remaining: current?.remaining)
      value.timeout = .init(reason: reason, progress: progress)
    }
  }

  func takeObservation() -> Observation? {
    state.withLock { value in
      let observation = value.timeout
      value.timeout = nil
      return observation
    }
  }

  /// The request owner writes after the deadline scopes have cancelled and joined their tasks.
  func flush() {
    guard let observation = takeObservation() else { return }
    ProtocolFailureDiagnostics.recordExecutionTimeout(
      observation.reason, requestID: requestID, progress: observation.progress)
  }
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
  init(imagesWith budget: ExecutionBudget, first: Int?) throws {
    let first = first ?? min(600, budget.total)
    guard (1...budget.total).contains(first) else {
      throw GatewayProtocolError(400, "invalid_execution_budget")
    }
    total = budget.total
    self.first = first
    idle = budget.idle
  }
}

/// One bounded monitor per turn; control frames and SSE comments never call this owner.
final class ExecutionProgress: Sendable {
  struct Snapshot: Sendable {
    let lastEvent: String?
    let lastEventAt: Date?
    let remaining: Duration?
  }

  private struct State {
    var received = false
    var uploading = false
    var deadline: ContinuousClock.Instant?
    var lastProgress: (event: String, at: Date)?

    func snapshot(at now: ContinuousClock.Instant) -> Snapshot {
      .init(
        lastEvent: lastProgress?.event, lastEventAt: lastProgress?.at,
        remaining: deadline.map { now.duration(to: $0) })
    }
  }
  private let state: Mutex<State>
  private let first: Int
  private let idle: Int
  private let traceEvents: Bool
  init(_ budget: ExecutionBudget, traceEvents: Bool = false) {
    first = budget.first
    idle = budget.idle
    self.traceEvents = traceEvents
    state = Mutex(.init())
  }
  func negotiateUpload() {
    state.withLock { if !$0.received { $0.deadline = nil } }
  }
  /// Images bound upload stalls without spending the first-response allowance.
  func noteUpload() {
    state.withLock { value in
      guard !value.received else { return }
      value.uploading = true
      value.deadline = .now.advanced(by: .seconds(idle))
    }
  }
  func requestSent() {
    state.withLock { value in
      guard !value.received, value.uploading || value.deadline == nil else { return }
      value.uploading = false
      value.deadline = .now.advanced(by: .seconds(first))
    }
  }
  func note(event: JSONValue? = nil) {
    // Untyped calls are bounded byte progress on non-event HTTP/Images paths.
    note(
      progress: event.map { ProviderEventSemantics($0).progress } ?? .activity,
      eventType: event?["type"]?.string ?? "response_body_bytes")
  }
  func note(progress: ProviderEventSemantics.Progress) {
    note(progress: progress, eventType: "response_body_bytes")
  }
  private func note(progress: ProviderEventSemantics.Progress, eventType: String) {
    state.withLock { value in
      switch progress {
      case .none: return
      case .acknowledgement: if value.received { return }
      case .activity: break
      }
      value.received = true
      value.deadline = .now.advanced(by: .seconds(idle))
      if traceEvents { value.lastProgress = (eventType, .now) }
    }
  }
  func snapshot() -> Snapshot {
    state.withLock { $0.snapshot(at: .now) }
  }
  func waitForExpiry() async throws -> (ExecutionTimeoutReason, Snapshot?) {
    while true {
      // Phase changes can shorten the deadline (first response -> idle).
      // A bounded poll avoids retaining a stale longer sleep across that transition.
      try await Task.sleep(for: .milliseconds(100))
      let expired = state.withLock { value -> (ExecutionTimeoutReason, Snapshot?)? in
        let now = ContinuousClock.now
        guard let deadline = value.deadline, now >= deadline else { return nil }
        let reason: ExecutionTimeoutReason =
          value.received || value.uploading
          ? .progress : .firstResponse
        return (reason, traceEvents ? value.snapshot(at: now) : nil)
      }
      if let expired { return expired }
    }
  }
}

func withProgressDeadline<Value: Sendable>(
  budget: ExecutionBudget,
  operation: @escaping @Sendable (ExecutionProgress) async throws -> Value
) async throws -> Value {
  let trace = ExecutionDeadlineScope.trace
  let progress = ExecutionProgress(budget, traceEvents: trace != nil)
  trace?.attach(progress)
  defer { trace?.detach(progress) }
  return try await withThrowingTaskGroup(of: Value.self) { group in
    defer { group.cancelAll() }
    group.addTask { try await operation(progress) }
    group.addTask {
      let (reason, snapshot) = try await progress.waitForExpiry()
      trace?.capture(reason, snapshot: snapshot)
      throw reason.error
    }
    group.addTask {
      try await Task.sleep(for: .seconds(budget.total))
      trace?.capture(.total)
      throw ExecutionTimeoutReason.total.error
    }
    return try await group.next()!
  }
}
