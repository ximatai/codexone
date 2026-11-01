import Foundation

public struct ResetCredit: Sendable, Equatable, Codable {
  public let id: String
  public let type: String
  public let status: String
  public let grantedAt: String
  public let expiresAt: String?
  public let title: String?
  public let description: String?
  public init(
    id: String, type: String, status: String, grantedAt: String, expiresAt: String?, title: String?,
    description: String?
  ) throws {
    guard Self.validIdentifier(id), Self.validIdentifier(type, maximum: 64),
      Self.validIdentifier(status, maximum: 64), Self.timestamp(grantedAt) != nil,
      expiresAt.map({ Self.timestamp($0) != nil }) ?? true,
      Self.validText(title, maximum: 512), Self.validText(description, maximum: 2048)
    else { throw ExecutionError.invalidCommand }
    self.id = id
    self.type = type
    self.status = status
    self.grantedAt = grantedAt
    self.expiresAt = expiresAt
    self.title = title
    self.description = description
  }
  public static func validIdentifier(_ value: String, maximum: Int = 256) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum
      && value.utf8.allSatisfy { (33...126).contains($0) }
  }
  private static func validText(_ value: String?, maximum: Int) -> Bool {
    value.map {
      $0.utf8.count <= maximum
        && !$0.unicodeScalars.contains {
          CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
        }
    } ?? true
  }
  public static func timestamp(_ value: String) -> TimeInterval? {
    guard value.utf8.count <= 64 else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fractional = parser.date(from: value)
    parser.formatOptions = [.withInternetDateTime]
    guard let date = fractional ?? parser.date(from: value), date.timeIntervalSince1970 > 0 else {
      return nil
    }
    return date.timeIntervalSince1970
  }
}
public struct ResetCreditList: Sendable, Equatable, Codable {
  public let credits: [ResetCredit]
  public let availableCount: Int
  public init(credits: [ResetCredit], availableCount: Int) throws {
    guard credits.count <= 128, (0...128).contains(availableCount),
      Set(credits.map(\.id)).count == credits.count
    else { throw ExecutionError.invalidCommand }
    self.credits = credits
    self.availableCount = availableCount
  }
  public func expiringCredit(now: Int64, leadHours: Int) -> ResetCredit? {
    credits.filter {
      guard $0.status == "available", let raw = $0.expiresAt,
        let expires = ResetCredit.timestamp(raw)
      else { return false }
      return expires > Double(now) && expires <= Double(now + Int64(leadHours) * 3600)
    }.sorted {
      let a = ResetCredit.timestamp($0.expiresAt!)!
      let b = ResetCredit.timestamp($1.expiresAt!)!
      return a == b ? $0.id < $1.id : a < b
    }.first
  }
}
public struct ResetCreditSettings: Sendable, Equatable, Codable {
  public let autoUseBeforeExpiry: Bool
  public let leadHours: Int
  public init(autoUseBeforeExpiry: Bool = false, leadHours: Int = 24) throws {
    guard (1...168).contains(leadHours) else { throw ExecutionError.invalidCommand }
    self.autoUseBeforeExpiry = autoUseBeforeExpiry
    self.leadHours = leadHours
  }
}
public enum ResetCreditCode: String, Sendable, Codable {
  case reset
  case nothingToReset = "nothing_to_reset"
  case noCredit = "no_credit"
  case alreadyRedeemed = "already_redeemed"
  case unknown
}
public struct ResetCreditResult: Sendable, Equatable, Codable {
  public let code: ResetCreditCode
  public let windowsReset: Int
  public init(code: ResetCreditCode, windowsReset: Int = 0) throws {
    guard (0...128).contains(windowsReset) else { throw ExecutionError.invalidCommand }
    self.code = code
    self.windowsReset = windowsReset
  }
}
public struct ResetCreditIntent: Sendable, Equatable, Codable {
  public let requestID: String
  public let creditID: String?
  public let automatic: Bool
  public init(requestID: String, creditID: String?, automatic: Bool) {
    self.requestID = requestID
    self.creditID = creditID
    self.automatic = automatic
  }
}
public struct ResetCreditState: Sendable, Codable {
  public var settings: ResetCreditSettings
  public var intent: ResetCreditIntent?
  public var lastCode: ResetCreditCode?
  public var failures: Int
  public var lastAttemptAt: Int64?
  public var lastAutoResetAt: Int64?
  public init() throws {
    settings = try .init()
    intent = nil
    lastCode = nil
    failures = 0
    lastAttemptAt = nil
    lastAutoResetAt = nil
  }
}
public struct ResetCreditAttempt: Sendable {
  public let intent: ResetCreditIntent
  public let auditID: String
  public init(intent: ResetCreditIntent, auditID: String) {
    self.intent = intent
    self.auditID = auditID
  }
}
public protocol AccountResetCreditProvider: Sendable {
  func resetCredits(_ work: AccountObservationWork) async throws -> ResetCreditList
  func consumeResetCredit(_ work: AccountObservationWork, intent: ResetCreditIntent) async throws
    -> ResetCreditResult
}
public protocol AccountResetCreditStore: AccountObservationStore {
  func resetCreditState(id: String) async throws -> ResetCreditState
  func setResetCreditSettings(id: String, revision: Int64, settings: ResetCreditSettings)
    async throws -> ResetCreditState
  func beginResetCreditAttempt(account: ManagedAccount, creditID: String?, automatic: Bool)
    async throws -> ResetCreditAttempt
  func finishResetCreditAttempt(id: String, attempt: ResetCreditAttempt, result: ResetCreditResult)
    async throws
  func recordResetCreditPollFailure(id: String) async throws
}
public protocol AccountResetCreditManaging: Sendable {
  func listResetCredits(id: String) async throws -> ResetCreditList
  func consumeResetCredit(id: String, creditID: String?) async throws -> ResetCreditResult
}
/// Observation is only a scheduling hint and never grants permission to consume.
public protocol AccountResetCreditScheduling: Sendable {
  func observedResetCredits(id: String)
}
