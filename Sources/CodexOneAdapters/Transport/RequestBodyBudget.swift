import Foundation
import Synchronization

/// The data service owns one budget; request/turn owners retain leases through completion or discard.
enum RequestBodyLimits {
  static let maximumBytes = 32 * 1024 * 1024
  static let smallRequestBytes = 8 * 1024 * 1024
  static let webSocketQueueBytes = 48 * 1024 * 1024
  static let budgetBytes = 64 * 1024 * 1024
}

final class RequestBodyBudget: Sendable {
  fileprivate enum Pool: Sendable { case shared, headroom }
  fileprivate struct Reservation: Sendable {
    var bytes = 0
    var pool = Pool.shared
  }
  private struct Waiter {
    let id: UUID
    let bytes: Int
    var small: Bool { bytes <= RequestBodyLimits.smallRequestBytes }
  }
  private struct State {
    var shared = 0
    var headroom = 0
    var waiters: [Waiter] = []
    mutating func replace(_ old: Reservation, with next: Reservation) {
      if old.pool == .shared { shared -= old.bytes } else { headroom -= old.bytes }
      if next.pool == .shared { shared += next.bytes } else { headroom += next.bytes }
    }
  }
  private let state = Mutex(State())
  static let maximumWaiters = 4
  static let waitSeconds = 5
  let capacity: Int
  let headroomCapacity: Int
  init(
    capacity: Int = RequestBodyLimits.budgetBytes,
    headroomCapacity: Int = RequestBodyLimits.smallRequestBytes
  ) {
    precondition(capacity >= 0 && headroomCapacity >= 0)
    self.capacity = capacity
    self.headroomCapacity = headroomCapacity
  }
  var occupiedBytes: Int { state.withLock { $0.shared + $0.headroom } }
  var sharedOccupiedBytes: Int { state.withLock { $0.shared } }
  var headroomOccupiedBytes: Int { state.withLock { $0.headroom } }
  var waitingCount: Int { state.withLock { $0.waiters.count } }
  private static func exhausted() -> GatewayProtocolError {
    GatewayProtocolError(503, "capacity_exhausted", cooldownSeconds: 1)
  }
  fileprivate func resize(_ old: Reservation, to bytes: Int, control: Bool) throws -> Reservation {
    try state.withLock { value in
      // Existing partial uploads cannot wait. Their resize is atomic, including
      // a pool migration: failure leaves the entire previous reservation intact.
      let sharedAvailable = capacity - value.shared + (old.pool == .shared ? old.bytes : 0)
      let sharedTurn = control || old.bytes > 0 || value.waiters.isEmpty
      let next: Reservation
      if !control && bytes <= RequestBodyLimits.smallRequestBytes,
        old.bytes > 0 || !value.waiters.contains(where: { $0.small }),
        bytes <= headroomCapacity - value.headroom + (old.pool == .headroom ? old.bytes : 0)
      {
        next = Reservation(bytes: bytes, pool: .headroom)
      } else if sharedTurn && bytes <= sharedAvailable {
        next = Reservation(bytes: bytes, pool: .shared)
      } else {
        throw Self.exhausted()
      }
      value.replace(old, with: next)
      return next
    }
  }
  fileprivate func release(_ reservation: Reservation) {
    state.withLock { $0.replace(reservation, with: Reservation()) }
  }
  fileprivate func begin(_ bytes: Int) throws -> (UUID?, Reservation?) {
    try state.withLock { value in
      let small = bytes <= RequestBodyLimits.smallRequestBytes
      guard bytes <= capacity || (small && bytes <= headroomCapacity) else {
        throw Self.exhausted()
      }
      // Prefer the small reserve for eligible bodies so arrival order does not
      // prevent two maximum-sized requests from using the shared pool.
      // Large waiters do not block the small reserve; its own waiters stay FIFO.
      if small && !value.waiters.contains(where: { $0.small }),
        bytes <= headroomCapacity - value.headroom
      {
        value.headroom += bytes
        return (nil, Reservation(bytes: bytes, pool: .headroom))
      }
      if value.waiters.isEmpty && bytes <= capacity - value.shared {
        value.shared += bytes
        return (nil, Reservation(bytes: bytes, pool: .shared))
      }
      guard value.waiters.count < Self.maximumWaiters else { throw Self.exhausted() }
      let ticket = UUID()
      value.waiters.append(Waiter(id: ticket, bytes: bytes))
      return (ticket, nil)
    }
  }
  fileprivate func acquire(_ bytes: Int, ticket: UUID) -> Reservation? {
    state.withLock { value in
      guard let waiter = value.waiters.first(where: { $0.id == ticket }), waiter.bytes == bytes
      else { return nil }
      let reservation: Reservation
      if waiter.small && value.waiters.first(where: { $0.small })?.id == ticket,
        bytes <= headroomCapacity - value.headroom
      {
        reservation = Reservation(bytes: bytes, pool: .headroom)
      } else if value.waiters.first?.id == ticket && bytes <= capacity - value.shared {
        reservation = Reservation(bytes: bytes, pool: .shared)
      } else {
        return nil
      }
      value.waiters.removeAll { $0.id == ticket }
      value.replace(Reservation(), with: reservation)
      return reservation
    }
  }
  func cancelWait(_ ticket: UUID) { state.withLock { $0.waiters.removeAll { $0.id == ticket } } }
  func lease() -> RequestBodyLease { .init(budget: self) }
}

final class RequestBodyLease: Sendable {
  private let budget: RequestBodyBudget
  private let reservation = Mutex(RequestBodyBudget.Reservation())
  fileprivate init(budget: RequestBodyBudget) { self.budget = budget }
  /// Only an empty lease may wait: partial uploads must never hold capacity while waiting.
  func beginWaiting(_ size: Int) throws -> UUID? {
    precondition(size >= 0)
    guard size > 0 else { return nil }
    return try reservation.withLock { value in
      precondition(value.bytes == 0)
      do {
        let (ticket, acquired) = try budget.begin(size)
        if let acquired { value = acquired }
        return ticket
      } catch {
        ProtocolFailureDiagnostics.recordBodyLimit(bytes: size, path: "reject_budget")
        throw error
      }
    }
  }
  func reserveIfReady(_ size: Int, ticket: UUID) -> Bool {
    reservation.withLock { value in
      precondition(value.bytes == 0)
      guard let acquired = budget.acquire(size, ticket: ticket) else { return false }
      value = acquired
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
  /// Control requests share the main pool and cannot consume small-request headroom.
  func reserve(_ size: Int, control: Bool = false) throws {
    precondition(size >= 0)
    try reservation.withLock { value in
      guard size > value.bytes else { return }
      do { value = try budget.resize(value, to: size, control: control) } catch {
        ProtocolFailureDiagnostics.recordBodyLimit(bytes: size, path: "reject_budget")
        throw error
      }
    }
  }
  func release() {
    reservation.withLock { value in
      budget.release(value)
      value = RequestBodyBudget.Reservation()
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
