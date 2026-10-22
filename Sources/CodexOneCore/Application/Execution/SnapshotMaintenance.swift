import Foundation

/// An operator attestation about executions absent from a historical snapshot.
/// These lifetime reservations never expire just because a daily window changes.
public struct RestoreBaseline: Codable, Sendable, Equatable {
  public let expectedRevision: Int64
  public let restoreID: String
  public let auditReference: String
  public let missingUnresolvedRequests: Int64
  public let missingUnresolvedMicros: Int64
  public let freezeUntilUnixSeconds: Int64

  public init(
    restoreID: String, auditReference: String, missingUnresolvedRequests: Int64,
    missingUnresolvedMicros: Int64, freezeUntilUnixSeconds: Int64, expectedRevision: Int64 = 0
  ) throws {
    self.expectedRevision = expectedRevision
    self.restoreID = restoreID
    self.auditReference = auditReference
    self.missingUnresolvedRequests = missingUnresolvedRequests
    self.missingUnresolvedMicros = missingUnresolvedMicros
    self.freezeUntilUnixSeconds = freezeUntilUnixSeconds
    try validate()
  }
  public func validate() throws {
    guard (0..<1_000_000).contains(expectedRevision), UUID(uuidString: restoreID) != nil,
      (1...128).contains(auditReference.utf8.count),
      auditReference.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      }),
      (0...1_000_000).contains(missingUnresolvedRequests),
      (0...1_000_000_000_000).contains(missingUnresolvedMicros),
      missingUnresolvedRequests > 0 || missingUnresolvedMicros == 0,
      (1...1_000_000_000_000).contains(freezeUntilUnixSeconds)
    else { throw ExecutionError.invalidCommand }
  }
}

public struct RestoreRecord: Codable, Sendable, Equatable {
  public let id: String
  public let backupID: String
  public let snapshotUnixSeconds: Int64
  public let restoredUnixSeconds: Int64
  public let inheritedUnresolvedRequests: Int64
  public let inheritedUnresolvedMicros: Int64
  public let inheritedFreezeUntilUnixSeconds: Int64
  public var minimumFreezeUntilUnixSeconds: Int64 {
    max(inheritedFreezeUntilUnixSeconds, (restoredUnixSeconds / 86400 + 1) * 86400)
  }
  public var baselineRevision: Int64 = 0
  public var baseline: RestoreBaseline?
  public var reconciledUnixSeconds: Int64?
  public var unresolvedRequests: Int64 {
    baseline?.missingUnresolvedRequests ?? inheritedUnresolvedRequests
  }
  public var unresolvedMicros: Int64 {
    baseline?.missingUnresolvedMicros ?? inheritedUnresolvedMicros
  }
  public func allowsAdmission(at now: Int64) -> Bool {
    guard let baseline else { return false }
    return now >= baseline.freezeUntilUnixSeconds
  }
  public func validate() throws {
    guard UUID(uuidString: id) != nil, UUID(uuidString: backupID) != nil,
      snapshotUnixSeconds > 0, restoredUnixSeconds >= snapshotUnixSeconds,
      restoredUnixSeconds <= 1_000_000_000_000,
      (0...1_000_000).contains(baselineRevision),
      (0...1_000_000_000_000).contains(inheritedFreezeUntilUnixSeconds),
      (0...1_000_000).contains(inheritedUnresolvedRequests),
      (0...1_000_000_000_000).contains(inheritedUnresolvedMicros)
    else { throw ExecutionError.invalidCommand }
    if let baseline {
      try baseline.validate()
      guard baseline.restoreID == id,
        baseline.freezeUntilUnixSeconds >= minimumFreezeUntilUnixSeconds,
        baselineRevision == baseline.expectedRevision + 1,
        reconciledUnixSeconds.map({ $0 >= restoredUnixSeconds && $0 <= 1_000_000_000_000 }) == true
      else { throw ExecutionError.invalidCommand }
    } else {
      guard baselineRevision == 0, reconciledUnixSeconds == nil else {
        throw ExecutionError.invalidCommand
      }
    }
  }
  /// Application transition; persistence must apply it under its transaction/instance lock.
  public func reconciling(_ proposed: RestoreBaseline, at now: Int64) throws -> Self {
    try validate()
    try proposed.validate()
    guard proposed.restoreID == id else { throw ExecutionError.conflict }
    if baseline == proposed { return self }
    guard proposed.expectedRevision == baselineRevision,
      proposed.freezeUntilUnixSeconds
        >= max(minimumFreezeUntilUnixSeconds, baseline?.freezeUntilUnixSeconds ?? 0),
      baselineRevision > 0
        || (proposed.missingUnresolvedRequests >= inheritedUnresolvedRequests
          && proposed.missingUnresolvedMicros >= inheritedUnresolvedMicros)
    else { throw ExecutionError.conflict }
    guard now >= restoredUnixSeconds, now <= 1_000_000_000_000 else {
      throw ExecutionError.invalidCommand
    }
    var next = self
    next.baseline = proposed
    next.baselineRevision += 1
    next.reconciledUnixSeconds = now
    return next
  }
  public init(
    id: String, backupID: String, snapshotUnixSeconds: Int64, restoredUnixSeconds: Int64,
    inheritedUnresolvedRequests: Int64, inheritedUnresolvedMicros: Int64,
    inheritedFreezeUntilUnixSeconds: Int64 = 0
  ) {
    self.id = id
    self.backupID = backupID
    self.snapshotUnixSeconds = snapshotUnixSeconds
    self.restoredUnixSeconds = restoredUnixSeconds
    self.inheritedUnresolvedRequests = inheritedUnresolvedRequests
    self.inheritedUnresolvedMicros = inheritedUnresolvedMicros
    self.inheritedFreezeUntilUnixSeconds = inheritedFreezeUntilUnixSeconds
  }
}
