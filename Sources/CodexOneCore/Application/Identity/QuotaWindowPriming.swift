import Foundation

public struct QuotaPrimingSettings: Sendable, Equatable, Codable {
  public var enabled: Bool
  public let model: String?
  public let message: String
  public init(enabled: Bool = false, model: String? = nil, message: String = "hello") throws {
    guard model.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
      (1...200).contains(message.unicodeScalars.count),
      !message.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.illegalCharacters.contains($0)
          || [.format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
      })
    else { throw ExecutionError.invalidCommand }
    self.enabled = enabled
    self.model = model
    self.message = message
  }
}
public enum QuotaWindowKind: String, Sendable, Codable, CaseIterable {
  case fiveHour = "five_hour"
  case weekly
  public var duration: Int64 { self == .fiveHour ? 18000 : 604800 }
}
public enum QuotaWindowStatus: Sendable, Equatable {
  case unknown
  case idle(reset: Int64)
  case active(reset: Int64)
}
public enum QuotaIdleDetection {
  public static func windows(_ observation: AccountQuotaObservation, now: Int64)
    -> [QuotaWindowKind: QuotaWindowStatus]
  {
    guard observation.failure == nil, observation.isFresh(at: now),
      let at = observation.observedAtUnixSeconds,
      let base = observation.quota?.limits.first(where: { $0.id == "codex" }),
      base.allowed != false, base.limitReached != true
    else { return [:] }
    var result: [QuotaWindowKind: QuotaWindowStatus] = [:]
    for kind in QuotaWindowKind.allCases {
      let matches = [base.primary, base.secondary].compactMap { $0 }.filter {
        $0.durationSeconds == kind.duration
      }
      guard matches.count == 1, let window = matches.first,
        let used = window.usedPercent, let reset = window.resetsAtUnixSeconds,
        reset > at, reset - at <= kind.duration + 5
      else { continue }
      let remaining = reset - at
      if let after = window.resetAfterSeconds, abs(after - remaining) > 5 { continue }
      if used == 0, window.resetAfterSeconds == kind.duration,
        abs(remaining - kind.duration) <= 5
      {
        result[kind] = .idle(reset: reset)
      } else if used > 0 || remaining < kind.duration - 60 {
        result[kind] = .active(reset: reset)
      }
    }
    return result
  }
}
public struct QuotaPrimingWindow: Sendable, Codable {
  public var lastAttemptAt: Int64?
  public var observedResetAt: Int64?
  public var awaitingActive = false
  public var activeResetAt: Int64?
  public init() {}
}
public struct QuotaPrimingState: Sendable, Codable {
  public var revision: Int64 = 1
  public var settings: QuotaPrimingSettings
  public var windows: [String: QuotaPrimingWindow] = [:]
  public var lastAttemptAt: Int64?
  public var lastResult: String?
  public var failures = 0
  public var attention: String?
  public init() throws { settings = try .init() }
  public mutating func observe(_ observation: AccountQuotaObservation, now: Int64) {
    guard let at = observation.observedAtUnixSeconds else { return }
    for (kind, status) in QuotaIdleDetection.windows(observation, now: now) {
      guard case .active(let reset) = status, var saved = windows[kind.rawValue],
        let attempted = saved.lastAttemptAt, at > attempted
      else { continue }
      saved.awaitingActive = false
      saved.activeResetAt = reset
      windows[kind.rawValue] = saved
    }
  }
  public func eligible(_ observation: AccountQuotaObservation, now: Int64) -> [QuotaWindowKind] {
    guard settings.enabled, failures < 3, !windows.values.contains(where: { $0.awaitingActive })
    else { return [] }
    let idle = QuotaIdleDetection.windows(observation, now: now).filter {
      if case .idle = $0.value { return true }
      return false
    }.map(\.key)
    guard !idle.isEmpty else { return [] }
    for kind in idle {
      guard let saved = windows[kind.rawValue] else { continue }
      if saved.awaitingActive { return [] }
      if let last = saved.lastAttemptAt, now < last || now - last < 3600 { return [] }
      if let reset = saved.activeResetAt, now < reset { return [] }
    }
    return idle.sorted { $0.rawValue < $1.rawValue }
  }
}
public protocol QuotaPrimingStore: AccountObservationStore, ExecutionStore {
  func quotaPrimingState(id: String) async throws -> QuotaPrimingState
  func setQuotaPrimingSettings(id: String, revision: Int64, settings: QuotaPrimingSettings)
    async throws -> QuotaPrimingState
  func disableQuotaPriming(id: String, revision: Int64) async throws
}
/// Trusted assembly only: no client credential, pool selection or public mode switch.
public protocol QuotaPrimingExecuting: Sendable {
  var models: [String] { get }
  var defaultModel: String? { get }
  func executePriming(id: String, settings: QuotaPrimingSettings) async throws
}
public enum QuotaPrimingIdentity {
  public static let principal = "internal:quota-priming"
}
public protocol QuotaPrimingScheduling: Sendable {
  func observedQuota(id: String)
}
