public struct GovernanceCapacity: Sendable {
  public let name: String
  public let current: Int64?
  public let limit: Int64
  public let blocking: Bool
  public init(name: String, current: Int64?, limit: Int64, blocking: Bool) {
    self.name = name
    self.current = current
    self.limit = limit
    self.blocking = blocking
  }
}
public struct AccountCapacity: Sendable {
  public let id: String
  public let current: Int64
  public let peak24Hours: Int64
  public init(id: String, current: Int64, peak24Hours: Int64) {
    self.id = id
    self.current = current
    self.peak24Hours = peak24Hours
  }
}
public struct GovernanceHeadroom: Sendable {
  public let unknownCount: Int64
  public let beforeUnixSeconds: Int64
  public let capacities: [GovernanceCapacity]
  public let accounts: [AccountCapacity]
  public init(
    capacities: [GovernanceCapacity], accounts: [AccountCapacity], unknownCount: Int64 = 0,
    beforeUnixSeconds: Int64 = 0
  ) {
    self.unknownCount = unknownCount
    self.beforeUnixSeconds = beforeUnixSeconds
    self.capacities = capacities
    self.accounts = accounts
  }
}
public protocol GovernanceReading: Sendable {
  func governanceHeadroom(now: Int64) async throws -> GovernanceHeadroom
  var governanceStorage: StorageObservation { get }
  var governanceStoragePolicy: StorageSpacePolicy { get }
}
