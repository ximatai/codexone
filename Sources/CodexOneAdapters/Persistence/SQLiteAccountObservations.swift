import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: AccountObservationStore {
  public func quotaObservation(id: String) async throws -> AccountQuotaObservation {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    return try await perform { db in
      _ = try Self.loadAccount(db, id)
      return try Self.loadQuota(db, id)
    }
  }
  public func creditHistory(id: String, from: Int64, through: Int64) async throws
    -> [[AccountCreditSample]]
  {
    guard ManagedAccount.validID(id), from > 0, through >= from,
      through - from <= 604_800
    else { throw ExecutionError.invalidCommand }
    return try await perform { db in
      _ = try Self.loadAccount(db, id)
      let samples = try db.rows(
        """
        SELECT at_epoch, balance FROM account_credit_samples
        WHERE account_id=? AND bucket_epoch BETWEEN ? AND ? AND at_epoch BETWEEN ? AND ?
        ORDER BY bucket_epoch
        """,
        [.text(id), .number(from / 300), .number(through / 300), .number(from), .number(through)]
      ) { row in
        AccountCreditSample(
          at: sqlite3_column_int64(row, 0),
          balance: String(cString: sqlite3_column_text(row, 1)))
      }
      var segments: [[AccountCreditSample]] = []
      var previousBucket: Int64?
      let fineSince = through - 86_400
      for sample in samples {
        guard SubscriptionUsageCredits.parseBalance(sample.balance) != nil else {
          throw ExecutionError.storageUnavailable
        }
        let bucket = sample.at / 300
        if let previousBucket, bucket == previousBucket + 1 {
          let index = segments.count - 1
          // Keep the endpoints of a continuous run, including a flat run within an hour.
          if sample.at < fineSince, segments[index].count > 1,
            let latest = segments[index].last, latest.at / 3600 == sample.at / 3600
          {
            segments[index].removeLast()
          }
          segments[index].append(sample)
        } else {
          segments.append([sample])
        }
        previousBucket = bucket
      }
      return segments
    }
  }
  public func recordQuotaObservation(
    account: ManagedAccount, atUnixSeconds: Int64,
    result: Result<SubscriptionQuota, QuotaObservationFailure>
  ) async throws -> AccountQuotaObservation {
    guard (1...1_000_000_000_000).contains(atUnixSeconds) else {
      throw ExecutionError.invalidCommand
    }
    if case .success(let quota) = result { try quota.validate() }
    return try await perform(optional: true) { db in
      try db.transaction {
        let current = try Self.loadAccount(db, account.id).account
        guard current.namespace == account.namespace,
          current.credentialVersion == account.credentialVersion
        else { throw ExecutionError.conflict }
        let old = try Self.loadQuota(db, account.id)
        var updated: AccountQuotaObservation
        var trend = old.trend ?? AccountQuotaTrend()
        switch result {
        case .success(let quota):
          guard current.authorization == .ready else { throw ExecutionError.conflict }
          updated = try .init(
            attemptedAtUnixSeconds: atUnixSeconds, observedAtUnixSeconds: atUnixSeconds,
            quota: quota, failure: nil)
          trend.record(quota, at: atUnixSeconds)
          if atUnixSeconds >= (old.attemptedAtUnixSeconds ?? 0) {
            if case .balance(let balance) = quota.usageCredits {
              try db.write(
                """
                INSERT INTO account_credit_samples
                SELECT ?,?,?,?
                WHERE NOT EXISTS (
                  SELECT 1 FROM account_credit_samples WHERE account_id=? AND bucket_epoch>?
                )
                ON CONFLICT(account_id,bucket_epoch) DO UPDATE
                SET at_epoch=excluded.at_epoch,balance=excluded.balance
                WHERE excluded.at_epoch >= account_credit_samples.at_epoch
                """,
                [
                  .text(account.id), .number(atUnixSeconds / 300), .number(atUnixSeconds),
                  .text(balance), .text(account.id), .number(atUnixSeconds / 300),
                ])
            }
            try db.write(
              "DELETE FROM account_credit_samples WHERE at_epoch<?",
              [.number(atUnixSeconds - 604_800)])
          }
        case .failure(let error):
          updated = try .init(
            attemptedAtUnixSeconds: atUnixSeconds, observedAtUnixSeconds: old.observedAtUnixSeconds,
            quota: old.quota, failure: error)
        }
        updated.trend = trend
        var record = try encode(updated)
        while record.utf8.count > 16_384 {
          updated.trend = trend.discardOldestHalf() ? trend : nil
          record = try encode(updated)
          if updated.trend == nil { break }
        }
        try db.write(
          "INSERT INTO account_quota VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET record_json=excluded.record_json",
          [.text(account.id), .text(record)])
        var priming = try Self.loadQuotaPriming(db, account.id)
        if !priming.windows.isEmpty {
          let enabled = priming.settings.enabled
          priming.observe(updated, now: db.clock.unixSeconds)
          if enabled && !priming.settings.enabled {
            try Self.bumpPrimingRevision(db, account.id)
          }
          try Self.saveQuotaPriming(db, account.id, priming)
        }
        return updated
      }
    }
  }
  private static func loadQuota(_ db: SQLiteConnection, _ id: String) throws
    -> AccountQuotaObservation
  {
    let records = try db.rows(
      "SELECT record_json FROM account_quota WHERE account_id=?", [.text(id)]
    ) {
      String(cString: sqlite3_column_text($0, 0))
    }
    guard let record = records.first else {
      return try .init(
        attemptedAtUnixSeconds: nil, observedAtUnixSeconds: nil, quota: nil, failure: nil)
    }
    let stored = try decode(AccountQuotaObservation.self, record)
    try stored.quota?.validate()
    var validated = try AccountQuotaObservation(
      attemptedAtUnixSeconds: stored.attemptedAtUnixSeconds,
      observedAtUnixSeconds: stored.observedAtUnixSeconds, quota: stored.quota,
      failure: stored.failure)
    validated.trend = stored.trend
    return validated
  }
}
