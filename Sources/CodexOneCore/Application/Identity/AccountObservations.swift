import Foundation

public struct SubscriptionQuotaWindow: Sendable, Equatable, Codable {
  public let resetAfterSeconds: Int64?
  public let usedPercent: Double?
  public let durationSeconds: Int64?
  public let resetsAtUnixSeconds: Int64?
  public init(
    usedPercent: Double?, durationSeconds: Int64?, resetsAtUnixSeconds: Int64?,
    resetAfterSeconds: Int64? = nil
  ) throws {
    guard resetAfterSeconds.map({ (0...31_536_000).contains($0) }) ?? true else {
      throw ExecutionError.invalidCommand
    }
    self.resetAfterSeconds = resetAfterSeconds
    guard usedPercent.map({ $0.isFinite && (0...10_000).contains($0) }) ?? true,
      durationSeconds.map({ (1...31_536_000).contains($0) }) ?? true,
      resetsAtUnixSeconds.map({ (1...1_000_000_000_000).contains($0) }) ?? true
    else { throw ExecutionError.invalidCommand }
    self.usedPercent = usedPercent
    self.durationSeconds = durationSeconds
    self.resetsAtUnixSeconds = resetsAtUnixSeconds
  }
}
public struct SubscriptionQuotaLimit: Sendable, Equatable, Codable {
  public let id: String
  public let allowed: Bool?
  public let limitReached: Bool?
  public let primary: SubscriptionQuotaWindow?
  public let secondary: SubscriptionQuotaWindow?
  public init(
    id: String, allowed: Bool?, limitReached: Bool?,
    primary: SubscriptionQuotaWindow?, secondary: SubscriptionQuotaWindow?
  ) throws {
    guard !id.isEmpty, id.utf8.count <= 128,
      id.utf8.allSatisfy({ (33...126).contains($0) })
    else { throw ExecutionError.invalidCommand }
    self.id = id
    self.allowed = allowed
    self.limitReached = limitReached
    self.primary = primary
    self.secondary = secondary
  }
}
/// Normalized quota only. No provider account identifiers or raw response.
public struct SubscriptionQuota: Sendable, Equatable, Codable {
  public let limits: [SubscriptionQuotaLimit]
  public let availableResetCredits: Int?
  public init(limits: [SubscriptionQuotaLimit], availableResetCredits: Int? = nil) throws {
    guard limits.count <= 17, limits.filter({ $0.id != "codex" }).count <= 16,
      Set(limits.map(\.id)).count == limits.count
    else {
      throw ExecutionError.invalidCommand
    }
    guard availableResetCredits.map({ (0...128).contains($0) }) ?? true else {
      throw ExecutionError.invalidCommand
    }
    self.availableResetCredits = availableResetCredits
    self.limits = limits
  }
  public func validate() throws {
    for limit in limits {
      for window in [limit.primary, limit.secondary].compactMap({ $0 }) {
        _ = try SubscriptionQuotaWindow(
          usedPercent: window.usedPercent, durationSeconds: window.durationSeconds,
          resetsAtUnixSeconds: window.resetsAtUnixSeconds,
          resetAfterSeconds: window.resetAfterSeconds)
      }
      _ = try SubscriptionQuotaLimit(
        id: limit.id, allowed: limit.allowed, limitReached: limit.limitReached,
        primary: limit.primary, secondary: limit.secondary)
    }
    _ = try Self(limits: limits, availableResetCredits: availableResetCredits)
  }
}
public enum QuotaObservationFailure: String, Error, Sendable, Codable {
  case unavailable
  case authorizationRejected = "authorization_rejected"
  case rateLimited = "rate_limited"
  case invalidResponse = "invalid_response"
  case refreshRequired = "refresh_required"
  case capacity, closed
}
public struct AccountObservationWork: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let account: ManagedAccount
  public let credential: AccountCredential
  public var description: String { "AccountObservationWork(redacted)" }
  public var debugDescription: String { description }
  init(account: ManagedAccount, credential: AccountCredential) {
    self.account = account
    self.credential = credential
  }
}
public struct AccountQuotaObservation: Sendable, Equatable, Codable {
  public let attemptedAtUnixSeconds: Int64?
  public let observedAtUnixSeconds: Int64?
  public let quota: SubscriptionQuota?
  public let failure: QuotaObservationFailure?
  public init(
    attemptedAtUnixSeconds: Int64?, observedAtUnixSeconds: Int64?,
    quota: SubscriptionQuota?, failure: QuotaObservationFailure?
  ) throws {
    guard attemptedAtUnixSeconds.map({ (1...1_000_000_000_000).contains($0) }) ?? true,
      observedAtUnixSeconds.map({ (1...1_000_000_000_000).contains($0) }) ?? true,
      (observedAtUnixSeconds == nil) == (quota == nil),
      failure == nil || attemptedAtUnixSeconds != nil
    else { throw ExecutionError.invalidCommand }
    self.attemptedAtUnixSeconds = attemptedAtUnixSeconds
    self.observedAtUnixSeconds = observedAtUnixSeconds
    self.quota = quota
    self.failure = failure
  }
  /// Failure never erases the last successful snapshot. A backwards clock is not fresh evidence.
  public func isFresh(at now: Int64) -> Bool {
    guard let observedAtUnixSeconds else { return false }
    return now >= observedAtUnixSeconds && now - observedAtUnixSeconds < 300
  }
}
public protocol AccountQuotaProvider: Sendable {
  func observe(_ work: AccountObservationWork) async throws -> SubscriptionQuota
}
public protocol AccountQuotaObserving: Sendable {
  var isAccepting: Bool { get }
  func observeAccount(id: String) async throws -> AccountQuotaObservation
}
public protocol AccountObservationStore: AccountGovernanceStore {
  var allowsOptionalStorageWork: Bool { get }
  func quotaObservation(id: String) async throws -> AccountQuotaObservation
  func recordQuotaObservation(
    account: ManagedAccount, atUnixSeconds: Int64,
    result: Result<SubscriptionQuota, QuotaObservationFailure>
  ) async throws -> AccountQuotaObservation
}

extension AccountObservationStore { public var allowsOptionalStorageWork: Bool { true } }
