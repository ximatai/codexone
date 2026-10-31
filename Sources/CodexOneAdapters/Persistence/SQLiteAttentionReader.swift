import CSQLite
import CodexOneCore
import Foundation

extension SQLiteUsageReader: AttentionReading {
  public func attentionItems(now: Int64) async throws -> [AttentionItem] {
    try await read { db in
      var items: [AttentionItem] = []
      // Independent sources fail visibly. All scans share the reader's single snapshot,
      // one-second SQL budget, storage gate, and cancellation handler.
      func source(_ name: String, _ operation: () throws -> [AttentionItem]) throws {
        do { items += try operation() } catch is CancellationError {
          throw CancellationError()
        } catch { items.append(.unavailable(name)) }
      }
      try source("accounts") {
        let accounts = try db.rows(
          "SELECT id,display_name,authorization FROM accounts ORDER BY id LIMIT 65"
        ) { row in
          (
            String(cString: sqlite3_column_text(row, 0)),
            sqlite3_column_type(row, 1) == SQLITE_NULL
              ? nil : String(cString: sqlite3_column_text(row, 1)),
            String(cString: sqlite3_column_text(row, 2))
          )
        }
        guard accounts.count <= 64 else { throw ExecutionError.storageUnavailable }
        var result: [AttentionItem] = []
        for (id, name, rawAuthorization) in accounts {
          guard let authorization = AccountAuthorization(rawValue: rawAuthorization) else {
            throw ExecutionError.storageUnavailable
          }
          let records = try db.rows(
            "SELECT record_json FROM account_quota WHERE account_id=?", [.text(id)]
          ) {
            String(cString: sqlite3_column_text($0, 0))
          }
          let quota: AccountQuotaObservation
          if let record = records.first {
            quota = try JSONDecoder().decode(AccountQuotaObservation.self, from: Data(record.utf8))
            try quota.quota?.validate()
          } else {
            quota = try .init(
              attemptedAtUnixSeconds: nil, observedAtUnixSeconds: nil, quota: nil, failure: nil)
          }
          let cooldowns = try db.scalar(
            "SELECT COUNT(*) FROM account_model_health WHERE account_id=? AND until_epoch>?",
            [.text(id), .number(now)])
          let failureAt = try db.rows(
            "SELECT at_epoch FROM account_health WHERE account_id=?", [.text(id)]
          ) {
            sqlite3_column_int64($0, 0)
          }.first
          result += AttentionRules.account(
            id: id, name: name, authorization: authorization,
            quota: quota, cooldownCount: cooldowns, failureAt: failureAt, now: now)
        }
        return result
      }
      try source("keys") {
        let keys = try db.rows("SELECT metadata_json FROM managed_keys ORDER BY id LIMIT 257") {
          try JSONDecoder().decode(
            ManagedKey.self, from: Data(String(cString: sqlite3_column_text($0, 0)).utf8))
        }
        guard keys.count <= 256 else { throw ExecutionError.storageUnavailable }
        var result: [AttentionItem] = []
        for key in keys where key.enabled {
          try key.policy.validate()
          let values: [SQLiteConnection.Value] = [.text(key.id), .text("utc-day-\(now / 86400)")]
          let requests = try db.scalar(
            "SELECT COUNT(*) FROM attempts WHERE key_id=? AND window_id=?", values)
          let budget = try db.scalar(
            "SELECT COALESCE(SUM(estimated + CASE WHEN state!='settled' THEN MAX(reserved-estimated,0) ELSE 0 END),0) FROM attempts WHERE key_id=? AND window_id=?",
            values)
          result += AttentionRules.key(key, requests: requests, budget: budget, now: now)
        }
        return result
      }
      try source("executions") {
        let recent = try db.rows(
          "SELECT COUNT(*),COALESCE(SUM(json_extract(outcome_json,'$.kind')='failed' AND COALESCE(json_extract(outcome_json,'$.failure'),'')!='client_cancelled'),0) FROM attempts WHERE created_at_epoch>=? AND created_at_epoch<=?",
          [.number(now - AttentionThresholds.errorWindowSeconds), .number(now)]
        ) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) }[0]
        let unresolved = try db.rows(
          "SELECT COUNT(*),MIN(created_at_epoch) FROM attempts WHERE state='unknown'"
        ) {
          (
            sqlite3_column_int64($0, 0),
            sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 1)
          )
        }[0]
        return AttentionRules.executions(
          admitted: recent.0, failed: recent.1, unknown: unresolved.0, since: unresolved.1)
      }
      return items
    }
  }
}
