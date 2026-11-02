import Foundation

/// Consecutive overloads survive elapsed steps, but never a process restart or success.
public struct OverloadPacing: Sendable {
  /// Maximum wait when no healthy alternative exists.
  public static let maximumWaitSeconds: Double = 15
  /// Preserve soft preference only across a short wait.
  public static let preferredWaitSeconds: Double = 3
  public static let maximumWaiters = 64
  public private(set) var consecutiveFailures = 0
  public private(set) var until: Double = 0
  public private(set) var persistedUntil: Int64 = 0

  public init(persistedUntil: Int64 = 0) {
    self.persistedUntil = persistedUntil
    until = Double(persistedUntil)
  }
  public mutating func record(now: Double, at: Int64, retryAfter: Int64?) {
    let previousUntil = until
    if let retryAfter {
      persistedUntil = at + retryAfter
      until = Double(persistedUntil)
    } else {
      consecutiveFailures = min(5, consecutiveFailures + 1)
      let step: Double = [1, 2, 4, 8, 15][consecutiveFailures - 1]
      // Recover subsecond precision only while finalizing in the outcome's second.
      // A delayed finalizer must not restart an already elapsed step.
      until = (Int64(now) == at ? now : Double(at)) + step
      // Round up only the durable representation: old binaries must not release early.
      persistedUntil = Int64(ceil(until))
    }
    // Concurrent completions cannot shorten an already observed trusted deadline.
    until = max(previousUntil, until)
    persistedUntil = Int64(ceil(until))
  }
  public func remaining(now: Double, persistedUntil: Int64) -> Double {
    max(0, (self.persistedUntil == persistedUntil ? until : Double(persistedUntil)) - now)
  }
  public static func requiresWait(seconds: Double) throws {
    if seconds > maximumWaitSeconds { throw AccountCooldownUnavailable(seconds: seconds) }
    if seconds > 0 { throw AccountPacingRequired(seconds: seconds) }
  }
}

/// No intent has been created. Reprepare and repeat normal admission after waiting.
public struct AccountPacingRequired: Error, Sendable {
  public let seconds: Double
  public init(seconds: Double) { self.seconds = seconds }
}
public struct AccountCooldownUnavailable: Error, Sendable {
  public let seconds: Double
  public var retryAfter: Int64 { Int64(ceil(seconds)) }
  public init(seconds: Double) { self.seconds = seconds }
}
