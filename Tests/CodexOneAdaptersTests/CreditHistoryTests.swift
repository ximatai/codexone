import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func creditHistoryMigratesV14AndKeepsOnlyBoundedAccountSamples() async throws {
  let path = try temporaryExecutionPath()
  let directory = (path as NSString).deletingLastPathComponent
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let original = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let envelope =
    "v1." + String(repeating: "a", count: 32) + "."
    + Data(repeating: 7, count: 28).base64EncodedString()
  let account = try await original.createVerifiedAccount(
    id: "synthetic-account", namespace: "synthetic-account-space", envelope: envelope)
  let other = try await original.createVerifiedAccount(
    id: "synthetic-other", namespace: "synthetic-other-space", envelope: envelope)
  let now: Int64 = 1_800_000_000
  let balance = try SubscriptionQuota(limits: [], usageCredits: .balance("12345.9876543210"))
  _ = try await original.recordQuotaObservation(
    account: account, atUnixSeconds: now - 9 * 86_400, result: .success(balance))
  await original.close()
  try rawSQL(path, "DROP TABLE account_credit_samples; PRAGMA user_version=14")

  let upgraded = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, allowStartupMigration: true)
  let start = now - 604_800
  #expect(try await upgraded.creditHistory(id: account.id, from: start, through: now).isEmpty)
  #expect(
    try await upgraded.quotaObservation(id: account.id).quota?.usageCredits == balance.usageCredits)
  #expect(try await upgraded.perform { try $0.scalar("PRAGMA user_version") } == 15)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory).contains {
      $0.contains(".pre-v15-")
    })

  let coarse = now - 2 * 86_400
  for at in [start - 300, coarse, coarse + 300, coarse + 600, now - 1200, now - 900, now - 870] {
    _ = try await upgraded.recordQuotaObservation(
      account: account, atUnixSeconds: at, result: .success(balance))
  }
  _ = try await upgraded.recordQuotaObservation(
    account: account, atUnixSeconds: now - 600, result: .failure(.unavailable))
  _ = try await upgraded.recordQuotaObservation(
    account: account, atUnixSeconds: now - 300,
    result: .success(try SubscriptionQuota(limits: [], usageCredits: .unlimited)))
  _ = try await upgraded.recordQuotaObservation(
    account: account, atUnixSeconds: now,
    result: .success(try SubscriptionQuota(limits: [], usageCredits: .balance("0"))))
  _ = try await upgraded.recordQuotaObservation(
    account: other, atUnixSeconds: now, result: .success(balance))
  let segments = try await upgraded.creditHistory(id: account.id, from: start, through: now)
  #expect(
    segments.map { $0.map(\.at) } == [
      [coarse, coarse + 600], [now - 1200, now - 870], [now],
    ])
  #expect(segments[1].map(\.balance) == ["12345.9876543210", "12345.9876543210"])
  #expect(segments.last?.last?.balance == "0")
  #expect(
    try await upgraded.perform {
      try $0.scalar("SELECT COUNT(*) FROM account_credit_samples WHERE at_epoch < \(start)")
    } == 0)
  #expect(
    try await upgraded.creditHistory(id: other.id, from: start, through: now).flatMap { $0 }.map(
      \.balance)
      == ["12345.9876543210"])
  await upgraded.close()

  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await reopened.creditHistory(id: account.id, from: start, through: now) == segments)
  await reopened.close()
}
