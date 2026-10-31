import Foundation
import Synchronization

/// Entry-point owned, process-local diagnostics. Never accepts header values or message bodies.
public final class ClientProtocolExtensionRegistry: Sendable {
  public static let maximumNames = 32
  public static let maximumNameBytes = 128
  public struct Entry: Sendable, Equatable {
    public let name: String
    public let firstSeenUnixSeconds: Int64
  }
  public struct Snapshot: Sendable {
    public let entries: [Entry]
    public let overflow: Bool
  }
  private struct State {
    var entries: [String: Int64] = [:]
    var overflow = false
  }
  private let state = Mutex(State())
  public init() {}

  public func record(name: String, atUnixSeconds: Int64 = Int64(Date().timeIntervalSince1970)) {
    guard (1...Self.maximumNameBytes).contains(name.utf8.count),
      name.utf8.allSatisfy({ (32...126).contains($0) })
    else { return }
    state.withLock {
      guard $0.entries[name] == nil else { return }
      guard $0.entries.count < Self.maximumNames else {
        $0.overflow = true
        return
      }
      $0.entries[name] = atUnixSeconds
    }
  }

  public func snapshot() -> Snapshot {
    state.withLock {
      Snapshot(
        entries: $0.entries.map { Entry(name: $0.key, firstSeenUnixSeconds: $0.value) }
          .sorted { $0.name < $1.name }, overflow: $0.overflow)
    }
  }
}
