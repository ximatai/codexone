import CSQLite
import CodexOneCore
import Foundation

extension SQLiteUsageReader: AttentionReading {
  public func attentionItems(now: Int64) async throws -> [AttentionItem] {
    let limits = primary.limits
    return try await read { db in
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
          var accountItems = AttentionRules.account(
            id: id, name: name, authorization: authorization,
            quota: quota, cooldownCount: cooldowns, failureAt: failureAt, now: now)
          if let index = accountItems.firstIndex(where: { $0.kind == "quota_high" }) {
            let ranking = try db.rows(
              """
              SELECT COALESCE(json_extract(k.metadata_json,'$.displayName'),json_extract(k.metadata_json,'$.principal'),a.key_id),SUM(CASE WHEN json_extract(a.usage_json,'$.nativeImages')=1 AND json_extract(a.usage_json,'$.imageInputTokens') IS NULL AND json_extract(a.usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(a.usage_json,'$.estimatedMicros') END),COUNT(*),
                COALESCE(SUM(a.usage_json IS NULL OR json_extract(a.usage_json,'$.completeness')!='complete'),0)
              FROM attempts a LEFT JOIN managed_keys k ON k.id=a.key_id WHERE a.identity=? AND a.created_at_epoch>=? AND a.created_at_epoch<=?
              GROUP BY a.key_id ORDER BY SUM(CASE WHEN json_extract(a.usage_json,'$.nativeImages')=1 AND json_extract(a.usage_json,'$.imageInputTokens') IS NULL AND json_extract(a.usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(a.usage_json,'$.estimatedMicros') END) DESC,a.key_id LIMIT 5
              """,
              [.text(id), .number(now - AttentionThresholds.rankingWindowSeconds), .number(now)]
            ) { row in
              "\(String(cString: sqlite3_column_text(row, 0)))：\(sqlite3_column_type(row, 1) == SQLITE_NULL ? "费用未知" : String(format: "$%.6f", Double(sqlite3_column_int64(row, 1)) / 1_000_000))，请求 \(sqlite3_column_int64(row, 2))，证据不完整 \(sqlite3_column_int64(row, 3))"
            }
            let old = accountItems[index]
            var detail = old.detail
            detail["keyRanking"] = .string(ranking.joined(separator: " | "))
            accountItems[index] = .init(
              old.kind, critical: old.severity == "critical", type: old.subjectType,
              id: old.subjectID, name: old.subjectName, detail: detail, since: old.sinceUnixSeconds)
          }
          let reset = try SQLiteExecutionStore.loadResetCreditState(db, id)
          if reset.intent != nil || reset.failures >= 3
            || reset.lastAutoResetAt.map({ now >= $0 && now - $0 < 86400 }) == true
          {
            accountItems.append(
              .init(
                "reset_credits", critical: reset.intent != nil, type: "account", id: id, name: name,
                detail: [
                  "code": .string(
                    reset.intent != nil
                      ? "unknown" : reset.failures >= 3 ? "repeated_failure" : "reset")
                ],
                since: reset.intent != nil
                  ? reset.lastAttemptAt
                  : reset.failures >= 3 ? reset.lastFailureAt : reset.lastAutoResetAt))
          }
          result += accountItems
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
        for key in keys where key.enabled && key.archivedAtUnixSeconds == nil {
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
        let unknown = try db.scalar(
          "SELECT COUNT(*) FROM attempts WHERE created_at_epoch>=? AND created_at_epoch<=? AND (state='unknown' OR closed_unknown_at_epoch IS NOT NULL) AND COALESCE(json_extract(outcome_json,'$.failure'),'')!='client_cancelled'",
          [.number(now - AttentionThresholds.errorWindowSeconds), .number(now)])
        return AttentionRules.executions(
          admitted: recent.0, failed: recent.1, unknown: unknown,
          since: now - AttentionThresholds.errorWindowSeconds)
      }
      try source("capacity") {
        let headroom = try Self.headroom(db, now: now, limits: limits)
        var result = headroom.capacities.flatMap { AttentionRules.capacity($0) }
        for account in headroom.accounts {
          func count(_ end: Int64) throws -> Int64 {
            try db.scalar(
              "SELECT COUNT(*) FROM attempts WHERE identity=? AND created_at_epoch>=? AND created_at_epoch<?",
              [
                .text(account.id), .number(end - AttentionThresholds.rateWindowSeconds),
                .number(end),
              ])
          }
          let baseline = try (1...7).map { try count(now - Int64($0) * 86400) }.sorted()[3]
          result += AttentionRules.accountCapacity(
            id: account.id, peak: account.peak24Hours, recent: try count(now), baseline: baseline)
        }
        return result
      }
      return items
    }
  }
}
