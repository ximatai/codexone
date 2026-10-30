import Foundation
import Synchronization

/// Data-service owner. Admission never waits; a permit owns exactly one release.
final class ControlCapacity: Sendable {
  private let counts = Mutex<[String: Int]>([:])
  func acquire(key: String) throws -> Permit {
    try counts.withLock { counts in
      guard counts.values.reduce(0, +) < 8, counts[key, default: 0] < 4 else {
        throw GatewayProtocolError(429, "control_capacity_exhausted", cooldownSeconds: 1)
      }
      counts[key, default: 0] += 1
    }
    return Permit(owner: self, key: key)
  }
  private func release(key: String) {
    counts.withLock {
      let count = $0[key, default: 0] - 1
      if count == 0 { $0.removeValue(forKey: key) } else { $0[key] = count }
    }
  }
  final class Permit: Sendable {
    let owner: ControlCapacity
    let key: String
    private let released = Mutex(false)
    init(owner: ControlCapacity, key: String) {
      self.owner = owner
      self.key = key
    }
    func release() {
      if released.withLock({ value in
        guard !value else { return false }
        value = true
        return true
      }) {
        owner.release(key: key)
      }
    }
    deinit { release() }
  }
}
