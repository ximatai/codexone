import Foundation
import Synchronization

/// The data service owns one budget; request/turn owners retain leases through completion or discard.
enum RequestBodyLimits {
  static let maximumBytes = 32 * 1024 * 1024
  static let unreservedBytes = 8 * 1024 * 1024
  static let budgetBytes = 48 * 1024 * 1024
}

final class RequestBodyBudget: Sendable {
  private let used = Mutex(0)
  let capacity: Int
  init(capacity: Int = RequestBodyLimits.budgetBytes) { self.capacity = capacity }
  var occupiedBytes: Int { used.withLock { $0 } }
  fileprivate func acquire(_ bytes: Int) throws {
    try used.withLock {
      guard bytes <= capacity - $0 else {
        throw GatewayProtocolError(503, "capacity_exhausted", cooldownSeconds: 1)
      }
      $0 += bytes
    }
  }
  fileprivate func release(_ bytes: Int) { used.withLock { $0 -= bytes } }
  func lease() -> RequestBodyLease { .init(budget: self) }
}

final class RequestBodyLease: Sendable {
  private let budget: RequestBodyBudget
  private let bytes = Mutex(0)
  fileprivate init(budget: RequestBodyBudget) { self.budget = budget }
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
