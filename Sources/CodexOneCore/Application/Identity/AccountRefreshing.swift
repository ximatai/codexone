public struct VerifiedAccountRefresh: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let namespace: String
  public let credential: AccountCredential
  public var description: String { "VerifiedAccountRefresh(redacted)" }
  public var debugDescription: String { description }
  public init(namespace: String, credential: AccountCredential) {
    self.namespace = namespace
    self.credential = credential
  }
}
/// A trusted provider adapter must bound I/O, honor cancellation, and never replay a token POST.
public protocol AccountRefreshProvider: Sendable {
  func refresh(credential: AccountCredential, namespace: String) async throws
    -> VerifiedAccountRefresh
}
public enum AccountRefreshError: Error, Sendable, Equatable {
  case invalidCommand, capacity, closed, conflict, unavailable, storageUnavailable
}
public protocol AccountRefreshing: Sendable {
  func refreshAccount(id: String, revision: Int64) async throws -> ManagedAccount
}
