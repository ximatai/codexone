import Foundation
import Synchronization

/// Owned by one data service, shared across its authorized executors. Waiting tasks remain
/// children of the connection, bounded by the service's connection limit.
final class ImageCapacity: Sendable {
  private let available: Mutex<Int>
  init(limit: Int) { available = Mutex(limit) }
  func acquire(timeout: Duration = .seconds(30)) async throws -> Permit {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      try Task.checkCancellation()
      if available.withLock({ count in
        guard count > 0 else { return false }
        count -= 1
        return true
      }) {
        return Permit(owner: self)
      }
      guard ContinuousClock.now < deadline else {
        throw GatewayProtocolError(429, "image_capacity_exhausted", cooldownSeconds: 1)
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
  private func release() { available.withLock { $0 += 1 } }
  final class Permit: Sendable {
    private let owner: ImageCapacity
    private let released = Mutex(false)
    fileprivate init(owner: ImageCapacity) { self.owner = owner }
    func release() {
      if released.withLock({ value in
        guard !value else { return false }
        value = true
        return true
      }) {
        owner.release()
      }
    }
    deinit { release() }
  }
}
