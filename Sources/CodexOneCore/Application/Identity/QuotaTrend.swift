import Foundation

public struct QuotaTrendSample: Sendable, Equatable, Codable {
  public let at: Int64
  public let remaining: Double

  init(at: Int64, remaining: Double) {
    self.at = at
    self.remaining = remaining
  }

  public init(from decoder: any Decoder) throws {
    var values = try decoder.unkeyedContainer()
    at = try values.decode(Int64.self)
    remaining = try values.decode(Double.self)
    guard values.isAtEnd, (1...1_000_000_000_000).contains(at), (0...100).contains(remaining)
    else { throw ExecutionError.invalidCommand }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.unkeyedContainer()
    try values.encode(at)
    try values.encode(remaining)
  }
}

public struct QuotaWindowTrend: Sendable, Equatable, Codable {
  public let reset: Int64
  public let duration: Int64
  public private(set) var samples: [QuotaTrendSample]

  static func recording(
    _ window: SubscriptionQuotaWindow?, at: Int64, after previous: Self?
  ) -> Self? {
    guard let window, let used = window.usedPercent, let reset = window.resetsAtUnixSeconds,
      let duration = window.durationSeconds, reset > at, at >= reset - duration - 60
    else { return nil }

    let sample = QuotaTrendSample(at: at, remaining: max(0, 100 - used))
    guard var previous, let latest = previous.samples.last, latest.at <= at,
      previous.reset > at, abs(previous.reset - reset) <= 60, previous.duration == duration,
      latest.remaining >= sample.remaining
    else { return Self(reset: reset, duration: duration, samples: [sample]) }

    previous.samples.removeAll { $0.at < at - 86_400 }
    if latest.at / 300 == at / 300, !previous.samples.isEmpty {
      previous.samples.removeLast()
    }
    previous.samples.append(sample)
    return previous
  }

  mutating func discardOldestHalf() {
    samples.removeFirst(samples.count / 2)
  }
}

public struct AccountQuotaTrend: Sendable, Equatable, Codable {
  public private(set) var primary: QuotaWindowTrend?
  public private(set) var secondary: QuotaWindowTrend?

  public init() {}

  public mutating func record(_ quota: SubscriptionQuota, at: Int64) {
    let limit = quota.limits.first { $0.id == "codex" }
    primary = QuotaWindowTrend.recording(limit?.primary, at: at, after: primary)
    secondary = QuotaWindowTrend.recording(limit?.secondary, at: at, after: secondary)
  }

  public mutating func discardOldestHalf() -> Bool {
    let primaryCount = primary?.samples.count ?? 0
    let secondaryCount = secondary?.samples.count ?? 0
    guard max(primaryCount, secondaryCount) > 1 else { return false }
    if primaryCount >= secondaryCount {
      primary?.discardOldestHalf()
    } else {
      secondary?.discardOldestHalf()
    }
    return true
  }
}
