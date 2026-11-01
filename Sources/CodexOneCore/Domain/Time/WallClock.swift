import Foundation

/// Wall time for persisted timestamps and calendar boundaries; elapsed deadlines use ContinuousClock.
public struct WallClock: Sendable {
  private let read: @Sendable () -> TimeInterval

  public init(unixTime: @escaping @Sendable () -> TimeInterval) {
    read = unixTime
  }

  public static let system = WallClock { Date().timeIntervalSince1970 }

  /// Preserve truncation toward zero, including subsecond timestamps before the Unix epoch.
  public var unixSeconds: Int64 { Int64(read()) }
  public var unixMicroseconds: Int64 { Int64(read() * 1_000_000) }
  public var utcDay: Int64 { Int64(read() / 86_400) }
}
