import Foundation

// Compile the production Codable types without the rest of the application.
public struct ManagedAccount: Sendable {}
public struct AccountCredential: Sendable {}
public protocol AccountGovernanceStore {}
enum ExecutionError: Error { case invalidCommand }

@main
enum QuotaOracle {
  static func main() throws {
    let now: Int64 = 1_700_000_000
    let main = try SubscriptionQuotaLimit(
      id: "codex", allowed: nil, limitReached: nil,
      primary: SubscriptionQuotaWindow(
        usedPercent: 26.25, durationSeconds: 3600, resetsAtUnixSeconds: now + 1800,
        resetAfterSeconds: 1800),
      secondary: nil)
    let quota = try SubscriptionQuota(limits: [main], usageCredits: .balance("20.25"))
    var expected = try AccountQuotaObservation(
      attemptedAtUnixSeconds: now, observedAtUnixSeconds: now, quota: quota, failure: nil)
    var trend = AccountQuotaTrend()
    trend.record(quota, at: now)
    expected.trend = trend
    if CommandLine.arguments.count == 1 {
      FileHandle.standardOutput.write(try JSONEncoder().encode(expected))
    } else {
      let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
      let observed = try JSONDecoder().decode(AccountQuotaObservation.self, from: data)
      precondition(observed == expected && observed.isFresh(at: now))
    }
  }
}
