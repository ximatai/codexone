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
        let updated: AccountQuotaObservation
        switch result {
        case .success(let quota):
          guard current.authorization == .ready else { throw ExecutionError.conflict }
          updated = try .init(
            attemptedAtUnixSeconds: atUnixSeconds, observedAtUnixSeconds: atUnixSeconds,
            quota: quota, failure: nil)
        case .failure(let error):
          updated = try .init(
            attemptedAtUnixSeconds: atUnixSeconds, observedAtUnixSeconds: old.observedAtUnixSeconds,
            quota: old.quota, failure: error)
        }
        try db.write(
          "INSERT INTO account_quota VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET record_json=excluded.record_json",
          [.text(account.id), .text(try encode(updated))])
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
    return try .init(
      attemptedAtUnixSeconds: stored.attemptedAtUnixSeconds,
      observedAtUnixSeconds: stored.observedAtUnixSeconds, quota: stored.quota,
      failure: stored.failure)
  }
}
