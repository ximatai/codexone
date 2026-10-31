import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: ExecutionMaintaining {
  /// Writer queue rechecks optional-work/storage gates; no cleanup in blocked/degraded pressure.
  public func maintainExecutions(now: Int64) async throws {
    guard now >= 0 else { throw ExecutionError.invalidCommand }
    try await perform(optional: true) { db in
      try db.transaction {
        let ids = try db.rows(
          "SELECT id FROM attempts WHERE state='unknown' AND unknown_since_epoch<=? ORDER BY unknown_since_epoch,id LIMIT ?",
          [
            .number(now - ExecutionLimits.unknownReconciliationSeconds),
            .number(Int64(ExecutionLimits.maintenanceBatch)),
          ]
        ) { String(cString: sqlite3_column_text($0, 0)) }
        if !ids.isEmpty {
          try Self.closeUnknown(
            db, ids: ids, before: now - ExecutionLimits.unknownReconciliationSeconds,
            automatic: true, now: now)
        }
        try db.write(
          "DELETE FROM bindings WHERE rowid IN (SELECT rowid FROM bindings WHERE expires_at_epoch<=? ORDER BY expires_at_epoch LIMIT ?)",
          [.number(now), .number(Int64(ExecutionLimits.maintenanceBatch))])
        try db.write(
          "DELETE FROM maintenance_events WHERE id IN (SELECT id FROM maintenance_events WHERE action='release_unknown' AND at_epoch<? ORDER BY id LIMIT 100)",
          [.number(now - ExecutionLimits.detailRetentionSeconds)])
        try db.write(
          "DELETE FROM account_concurrency WHERE rowid IN (SELECT rowid FROM account_concurrency WHERE at_epoch<? LIMIT 100)",
          [.number(now - 86400)])
        let retired = try db.rows(
          "SELECT id FROM attempts WHERE state='settled' AND created_at_epoch<? AND NOT EXISTS(SELECT 1 FROM bindings WHERE attempt=attempts.id) ORDER BY created_at_epoch,id LIMIT ?",
          [
            .number(now - ExecutionLimits.detailRetentionSeconds),
            .number(Int64(ExecutionLimits.maintenanceBatch)),
          ]
        ) { String(cString: sqlite3_column_text($0, 0)) }
        for id in retired {
          try Self.rollUp(db, attempt: id)
          try db.write("DELETE FROM evidence WHERE attempt=?", [.text(id)])
          try db.write("DELETE FROM attempts WHERE id=?", [.text(id)])
        }
      }
      // At most 32 pages, only when >=5% of pages are free. WAL checkpoint remains StorageMonitor's job.
      let free = try db.scalar("PRAGMA freelist_count")
      if free > 0, free * 20 >= (try db.scalar("PRAGMA page_count")) {
        try db.exec("PRAGMA incremental_vacuum(32)")
      }
    }
  }
  /// Both manual and timed closure use the same atomic transition and audit action.
  static func closeUnknown(
    _ db: SQLiteConnection, ids: [String], before: Int64, automatic: Bool, now: Int64
  ) throws {
    for id in ids {
      try db.write(
        "UPDATE attempts SET state='settled',closed_unknown_at_epoch=? WHERE id=? AND state='unknown'",
        [.number(now), .text(id)])
    }
    let record = JSONValue.object([
      "released": .number(Decimal(ids.count)), "beforeUnixSeconds": .number(Decimal(before)),
      "reason": .string(automatic ? "reconciliation_expired" : "manual"),
    ])
    try SQLiteSnapshotMaintenance.audit(
      db, action: "release_unknown", record: String(decoding: try record.data(), as: UTF8.self),
      at: now)
  }
  private static func rollUp(_ db: SQLiteConnection, attempt: String) throws {
    let metrics = [
      "input_tokens", "output_tokens", "cached_tokens", "images", "estimated_micros",
      "image_input_tokens", "image_output_tokens", "image_input_text_tokens",
      "image_input_image_tokens",
    ]
    let additions = metrics.map {
      "\($0)=CASE WHEN \($0) IS NULL AND excluded.\($0) IS NULL THEN NULL ELSE COALESCE(\($0),0)+COALESCE(excluded.\($0),0) END"
    }.joined(separator: ",")
    try db.write(
      """
      INSERT INTO usage_daily
      SELECT created_at_epoch/86400*86400,key_id,COALESCE(json_extract(admission_json,'$.model'),''),COALESCE(json_extract(admission_json,'$.mode'),'generation'),
        COALESCE(json_extract(outcome_json,'$.kind'),''),COALESCE(json_extract(outcome_json,'$.failure'),''),COALESCE(json_extract(usage_json,'$.completeness'),''),closed_unknown_at_epoch IS NOT NULL,
        1,created_at_epoch,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.inputTokens') END,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.outputTokens') END,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.cachedTokens') END,
        json_extract(usage_json,'$.images'),
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 AND json_extract(usage_json,'$.imageInputTokens') IS NULL AND json_extract(usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END,
        json_extract(usage_json,'$.imageInputTokens'),json_extract(usage_json,'$.imageOutputTokens'),json_extract(usage_json,'$.imageInputTextTokens'),json_extract(usage_json,'$.imageInputImageTokens')
      FROM attempts WHERE id=?
      ON CONFLICT(day_epoch,key_id,model,mode,outcome,failure,completeness,usage_unknown) DO UPDATE SET requests=requests+1,last_used_epoch=MAX(last_used_epoch,excluded.last_used_epoch),\(additions)
      """, [.text(attempt)])
  }
}
