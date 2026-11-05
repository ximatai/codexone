import Foundation
import Synchronization

/// The data service owns one budget; request/turn owners retain leases through completion or discard.
enum RequestBodyLimits {
  static let maximumBytes = 32 * 1024 * 1024
  static let unreservedBytes = 8 * 1024 * 1024
  static let webSocketQueueBytes = 48 * 1024 * 1024
  static let budgetBytes = 64 * 1024 * 1024
}

final class RequestBodyBudget: Sendable {
  private struct State {
    var used = 0
    var waiters: [UUID] = []
  }
  private let state = Mutex(State())
  static let maximumWaiters = 4
  static let waitSeconds = 5
  let capacity: Int
  init(capacity: Int = RequestBodyLimits.budgetBytes) { self.capacity = capacity }
  var occupiedBytes: Int { state.withLock { $0.used } }
  var waitingCount: Int { state.withLock { $0.waiters.count } }
  fileprivate func acquire(_ bytes: Int) throws {
    try state.withLock {
      guard bytes <= capacity - $0.used else {
        throw GatewayProtocolError(503, "capacity_exhausted", cooldownSeconds: 1)
      }
      $0.used += bytes
    }
  }
  fileprivate func release(_ bytes: Int) { state.withLock { $0.used -= bytes } }
  fileprivate func begin(_ bytes: Int) throws -> UUID? {
    try state.withLock {
      guard bytes <= capacity else {
        throw GatewayProtocolError(503, "capacity_exhausted", cooldownSeconds: 1)
      }
      if $0.waiters.isEmpty, bytes <= capacity - $0.used {
        $0.used += bytes
        return nil
      }
      guard $0.waiters.count < Self.maximumWaiters else {
        throw GatewayProtocolError(503, "capacity_exhausted", cooldownSeconds: 1)
      }
      let ticket = UUID()
      $0.waiters.append(ticket)
      return ticket
    }
  }
  fileprivate func acquire(_ bytes: Int, ticket: UUID) -> Bool {
    state.withLock {
      guard $0.waiters.first == ticket, bytes <= capacity - $0.used else { return false }
      $0.waiters.removeFirst()
      $0.used += bytes
      return true
    }
  }
  func cancelWait(_ ticket: UUID) { state.withLock { $0.waiters.removeAll { $0 == ticket } } }
  func lease() -> RequestBodyLease { .init(budget: self) }
}

final class RequestBodyLease: Sendable {
  private let budget: RequestBodyBudget
  private let bytes = Mutex(0)
  fileprivate init(budget: RequestBodyBudget) { self.budget = budget }
  /// Only an empty lease may wait: partial uploads must never hold capacity while waiting.
  func beginWaiting(_ size: Int) throws -> UUID? {
    guard size > RequestBodyLimits.unreservedBytes else { return nil }
    return try bytes.withLock {
      precondition($0 == 0)
      do {
        let ticket = try budget.begin(size)
        if ticket == nil { $0 = size }
        return ticket
      } catch {
        ProtocolFailureDiagnostics.recordBodyLimit(bytes: size, path: "reject_budget")
        throw error
      }
    }
  }
  func reserveIfReady(_ size: Int, ticket: UUID) -> Bool {
    bytes.withLock {
      precondition($0 == 0)
      guard budget.acquire(size, ticket: ticket) else { return false }
      $0 = size
      return true
    }
  }
  func reserveWaiting(_ size: Int, timeout: Duration = .seconds(RequestBodyBudget.waitSeconds))
    async throws
  {
    try Task.checkCancellation()
    guard let ticket = try beginWaiting(size) else { return }
    defer { budget.cancelWait(ticket) }
    let deadline = ContinuousClock.now + timeout
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        ProtocolFailureDiagnostics.recordBodyLimit(bytes: size, path: "reject_budget")
        throw GatewayProtocolError(503, "capacity_exhausted", cooldownSeconds: 1)
      }
      if reserveIfReady(size, ticket: ticket) { return }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
  func reserve(_ size: Int, countAll: Bool = false) throws {
    guard countAll || size > RequestBodyLimits.unreservedBytes else { return }
    try bytes.withLock {
      if size > $0 {
        do { try budget.acquire(size - $0) } catch {
          ProtocolFailureDiagnostics.recordBodyLimit(bytes: size, path: "reject_budget")
          throw error
        }
        $0 = size
      }
    }
  }
  func release() {
    bytes.withLock {
      budget.release($0)
      $0 = 0
    }
  }
  deinit { release() }
}

final class WebSocketBody: Sendable {
  private let storage: Mutex<Data>
  var data: Data { storage.withLock { $0 } }
  let lease: RequestBodyLease?
  init(_ data: Data, lease: RequestBodyLease? = nil) {
    storage = Mutex(data)
    self.lease = lease
  }
  /// Drop raw bytes after the last parser without returning the turn's budget.
  func discardData() { storage.withLock { $0 = Data() } }
  func release() {
    discardData()
    lease?.release()
  }
}
