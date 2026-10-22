import Foundation

/// Durable progress contains identifiers only; credential context and authorization stay unchanged.
public struct CredentialReencryptionCheckpoint: Codable, Sendable, Equatable {
  public let jobID: String
  public let backupID: String
  public let targetKeyID: String
  public let startedUnixSeconds: Int64
  public var rewritten: Int
  public var complete: Bool

  public init(
    jobID: String, backupID: String, targetKeyID: String, startedUnixSeconds: Int64,
    rewritten: Int = 0, complete: Bool = false
  ) throws {
    self.jobID = jobID
    self.backupID = backupID
    self.targetKeyID = targetKeyID
    self.startedUnixSeconds = startedUnixSeconds
    self.rewritten = rewritten
    self.complete = complete
    try validate()
  }
  public func validate() throws {
    guard UUID(uuidString: jobID) != nil, UUID(uuidString: backupID) != nil,
      targetKeyID.utf8.count == 32,
      targetKeyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      (1...1_000_000_000_000).contains(startedUnixSeconds), (0...64).contains(rewritten)
    else { throw ExecutionError.invalidCommand }
  }
  public func advancing(by count: Int, complete: Bool) throws -> Self {
    guard !self.complete, (0...8).contains(count) else { throw ExecutionError.conflict }
    var next = self
    next.rewritten += count
    next.complete = complete
    try next.validate()
    return next
  }
}
