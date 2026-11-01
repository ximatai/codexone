import CSQLite
import CodexOneCore
import Foundation

private struct UsagePredicate {
  var terms: [String] = []
  var values: [SQLiteConnection.Value] = []
  var sql: String { terms.isEmpty ? "1" : terms.joined(separator: " AND ") }
}
extension SQLiteUsageReader {
  private static func predicate(
    _ query: UsageQuery, diagnostic: Bool, timed: Bool = true, now: Int64
  )
    -> UsagePredicate
  {
    var result = UsagePredicate()
    func add(_ expression: String, _ value: SQLiteConnection.Value) {
      result.terms.append(expression)
      result.values.append(value)
    }
    let epoch = diagnostic ? "at_epoch" : "created_at_epoch"
    if diagnostic { add("at_epoch>=?", .number(now - 30 * 86400)) }
    if timed {
      add("\(epoch)>=?", .number(query.startUnixSeconds))
      add("\(epoch)<?", .number(query.endUnixSeconds))
    }
    if let key = query.keyID { add("key_id=?", .text(key)) }
    if let model = query.model {
      add(diagnostic ? "model=?" : "json_extract(admission_json,'$.model')=?", .text(model))
    }
    if let effort = query.reasoningEffort {
      if diagnostic {
        result.terms.append("0")
      } else {
        add("json_extract(admission_json,'$.reasoningEffort')=?", .text(effort))
      }
    }
    if let mode = query.mode {
      add(
        diagnostic ? "mode=?" : "COALESCE(json_extract(admission_json,'$.mode'),'generation')=?",
        .text(mode.rawValue))
    }
    if let failure = query.failure {
      add(
        diagnostic ? "failure=?" : "json_extract(outcome_json,'$.failure')=?",
        .text(failure.rawValue))
    }
    if query.failedOnly && !diagnostic {
      result.terms.append("json_extract(outcome_json,'$.failure') IS NOT NULL")
    }
    if let state = query.state {
      if diagnostic {
        result.terms.append("0")
      } else {
        if state == .closedUnknown {
          result.terms.append("closed_unknown_at_epoch IS NOT NULL")
        } else {
          add("state=?", .text(state.rawValue))
          if state == .settled { result.terms.append("closed_unknown_at_epoch IS NULL") }
        }
      }
    }
    return result
  }
  static func query(_ db: SQLiteConnection, _ query: UsageQuery) throws -> UsageReport {
    let now = db.clock.unixSeconds
    let attempts = predicate(query, diagnostic: false, now: now)
    let rejected = predicate(query, diagnostic: true, now: now)
    let base = predicate(query, diagnostic: false, timed: false, now: now)
    let untimed = try db.scalar(
      "SELECT COUNT(*) FROM attempts WHERE created_at_epoch IS NULL AND \(base.sql)", base.values)
    let rejectionCount = try db.scalar(
      "SELECT COUNT(*) FROM request_diagnostics WHERE \(rejected.sql)", rejected.values)
    let lifetime = try db.rows(
      "SELECT COALESCE(SUM(state='intent'),0),COALESCE(SUM(state='unknown'),0),COALESCE(SUM(CASE WHEN state!='settled' THEN MAX(reserved,estimated) ELSE 0 END),0) FROM attempts"
        + (query.keyID == nil ? "" : " WHERE key_id=?"),
      query.keyID.map { [.text($0)] } ?? []
    ) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2)) }[0]
    let timing = try db.rows(
      """
      SELECT AVG(json_extract(outcome_json,'$.firstEventMilliseconds')),
        AVG(json_extract(outcome_json,'$.totalMilliseconds')),
        COUNT(json_extract(outcome_json,'$.firstEventMilliseconds')) FROM attempts WHERE \(attempts.sql)
      """, attempts.values
    ) { row in
      (
        sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : sqlite3_column_double(row, 0),
        sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : sqlite3_column_double(row, 1),
        sqlite3_column_int64(row, 2)
      )
    }[0]
    let p95: Int64? =
      timing.2 == 0
      ? nil
      : try db.scalar(
        """
        SELECT json_extract(outcome_json,'$.firstEventMilliseconds') FROM attempts
        WHERE \(attempts.sql) AND json_extract(outcome_json,'$.firstEventMilliseconds') IS NOT NULL
        ORDER BY json_extract(outcome_json,'$.firstEventMilliseconds') LIMIT 1 OFFSET ?
        """, attempts.values + [.number((timing.2 * 95 + 99) / 100 - 1)])
    // Settled + partial evidence is an audited release, not complete metering. Retain
    // trusted metric lower bounds while projecting its completeness as unavailable.
    let unknownReasons = try db.rows(
      "SELECT COALESCE(json_extract(outcome_json,'$.failure'),'unspecified'),COUNT(*) FROM attempts WHERE \(attempts.sql) AND (state='unknown' OR closed_unknown_at_epoch IS NOT NULL) GROUP BY 1",
      attempts.values
    ) { (String(cString: sqlite3_column_text($0, 0)), sqlite3_column_int64($0, 1)) }
    let totals = try db.rows(
      """
      SELECT COUNT(*),COALESCE(SUM(state='intent'),0),COALESCE(SUM(state='unknown'),0),
        COALESCE(SUM(json_extract(usage_json,'$.completeness')='complete'),0),
        COALESCE(SUM(json_extract(usage_json,'$.completeness')='partial' AND state!='settled'),0),COALESCE(SUM(usage_json IS NULL OR (state='settled' AND json_extract(usage_json,'$.completeness')='partial')),0),
        COALESCE(SUM(json_extract(outcome_json,'$.kind')='failed'),0),
        COALESCE(SUM(json_extract(outcome_json,'$.kind')='cancelled'),0),
        COALESCE(SUM(CASE WHEN state!='settled' THEN MAX(reserved,estimated) ELSE 0 END),0),
        SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.inputTokens') END),SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.outputTokens') END),
        SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.cachedTokens') END),SUM(json_extract(usage_json,'$.images')),
        SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 AND json_extract(usage_json,'$.imageInputTokens') IS NULL AND json_extract(usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END),SUM(json_extract(usage_json,'$.imageInputTokens')),SUM(json_extract(usage_json,'$.imageOutputTokens')),SUM(json_extract(usage_json,'$.imageInputTextTokens')),SUM(json_extract(usage_json,'$.imageInputImageTokens')) FROM attempts WHERE \(attempts.sql)
      """, attempts.values
    ) { row in
      UsageTotals(
        admitted: sqlite3_column_int64(row, 0), rejected: rejectionCount,
        inFlight: sqlite3_column_int64(row, 1), unknown: sqlite3_column_int64(row, 2),
        complete: sqlite3_column_int64(row, 3), partial: sqlite3_column_int64(row, 4),
        unavailable: sqlite3_column_int64(row, 5),
        failed: sqlite3_column_int64(row, 6), cancelled: sqlite3_column_int64(row, 7),
        historicalWithoutTime: untimed, unresolvedExposureMicros: sqlite3_column_int64(row, 8),
        lifetimeInFlight: lifetime.0, lifetimeUnknown: lifetime.1,
        lifetimeExposureMicros: lifetime.2,
        metrics: try metrics(row, offset: 9), averageFirstEventMilliseconds: timing.0,
        p95FirstEventMilliseconds: p95, averageTotalMilliseconds: timing.1,
        usageUnknown: unknownReasons.reduce(0) { $0 + $1.1 },
        unknownReasons: Dictionary(uniqueKeysWithValues: unknownReasons))
    }[0]
    let grouped = try db.rows(
      "SELECT created_at_epoch/3600*3600,COUNT(*),SUM(state!='settled') FROM attempts WHERE \(attempts.sql) GROUP BY created_at_epoch/3600",
      attempts.values
    ) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2)) }
    let denied = try db.rows(
      "SELECT at_epoch/3600*3600,COUNT(*) FROM request_diagnostics WHERE \(rejected.sql) GROUP BY at_epoch/3600",
      rejected.values
    ) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) }
    guard grouped.count <= 744, denied.count <= 744 else { throw ExecutionError.capacity }
    let activity = Dictionary(uniqueKeysWithValues: grouped.map { ($0.0, ($0.1, $0.2)) })
    let refusals = Dictionary(uniqueKeysWithValues: denied)
    let buckets = stride(from: query.startUnixSeconds, to: query.endUnixSeconds, by: 3600).map {
      at in
      UsageBucket(
        atUnixSeconds: at, admitted: activity[at]?.0 ?? 0, rejected: refusals[at] ?? 0,
        unresolved: activity[at]?.1 ?? 0)
    }
    var sql = """
      SELECT history.*, (SELECT json_extract(metadata_json,'$.principal') FROM managed_keys WHERE id=history.key_id), (SELECT json_extract(metadata_json,'$.displayName') FROM managed_keys WHERE id=history.key_id) FROM (
      SELECT 'admitted' kind,'a:'||id cursor_id,id,created_at_epoch at_epoch,key_id,
        json_extract(admission_json,'$.model') model,COALESCE(json_extract(admission_json,'$.mode'),'generation') mode,
        identity,request_id,CASE WHEN closed_unknown_at_epoch IS NOT NULL THEN 'closed_unknown' ELSE state END state,json_extract(outcome_json,'$.kind') outcome,
        json_extract(outcome_json,'$.failure') failure,CASE WHEN state='settled' AND json_extract(usage_json,'$.completeness')='partial' THEN NULL ELSE json_extract(usage_json,'$.completeness') END completeness,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.inputTokens') END input_tokens,CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.outputTokens') END output_tokens,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.cachedTokens') END cached_tokens,json_extract(usage_json,'$.images') images,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 AND json_extract(usage_json,'$.imageInputTokens') IS NULL AND json_extract(usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END estimated_micros, json_extract(usage_json,'$.imageInputTokens') image_input_tokens,json_extract(usage_json,'$.imageOutputTokens') image_output_tokens,json_extract(usage_json,'$.imageInputTextTokens') image_input_text_tokens,json_extract(usage_json,'$.imageInputImageTokens') image_input_image_tokens,json_extract(outcome_json,'$.firstEventMilliseconds'),json_extract(outcome_json,'$.totalMilliseconds'),json_extract(admission_json,'$.reasoningEffort'),json_extract(admission_json,'$.serviceTier'),json_extract(outcome_json,'$.actualServiceTier'),COALESCE(json_extract(admission_json,'$.requestMetadataRecorded'),0) FROM attempts WHERE \(attempts.sql)
      UNION ALL
      SELECT 'rejected','r:'||request_id,request_id,at_epoch,key_id,model,mode,NULL,request_id,NULL,'failed',failure,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0
        FROM request_diagnostics WHERE \(rejected.sql)) history
      """
    var values = attempts.values + rejected.values
    if let cursor = query.cursor {
      sql += " WHERE at_epoch<? OR (at_epoch=? AND cursor_id<?)"
      values += [.number(cursor.atUnixSeconds), .number(cursor.atUnixSeconds), .text(cursor.id)]
    }
    sql += " ORDER BY at_epoch DESC,cursor_id DESC LIMIT ?"
    values.append(.number(Int64(query.limit + 1)))
    var rows = try db.rows(sql, values) { row -> UsageRow in
      func string(_ index: Int32) -> String? {
        sqlite3_column_type(row, index) == SQLITE_NULL
          ? nil : String(cString: sqlite3_column_text(row, index))
      }
      guard let kind = string(0).flatMap(UsageRow.Kind.init(rawValue:)),
        let id = string(2), let key = string(4),
        let mode = string(6).flatMap(ExecutionMode.init(rawValue:)),
        let cursorID = string(1)
      else { throw ExecutionError.storageUnavailable }
      let at = sqlite3_column_int64(row, 3)
      let state = string(9).flatMap(ExecutionSnapshot.State.init(rawValue:))
      let outcome = string(10).flatMap(ExecutionOutcome.Kind.init(rawValue:))
      let failure = string(11).flatMap(ExecutionFailure.init(rawValue:))
      let completeness = string(12).flatMap(UsageEvidence.Completeness.init(rawValue:))
      guard string(9) == nil || state != nil, string(10) == nil || outcome != nil,
        string(11) == nil || failure != nil, string(12) == nil || completeness != nil
      else { throw ExecutionError.storageUnavailable }
      return try UsageRow(
        kind: kind, id: id, atUnixSeconds: at, keyID: key, model: string(5), mode: mode,
        accountID: string(7), requestID: string(8), state: state, outcome: outcome,
        failure: failure,
        completeness: completeness, metrics: try metrics(row, offset: 13),
        cursor: .init(atUnixSeconds: at, id: cursorID), principal: string(28),
        displayName: string(29),
        firstEventMilliseconds: sqlite3_column_type(row, 22) == SQLITE_NULL
          ? nil : sqlite3_column_int64(row, 22),
        totalMilliseconds: sqlite3_column_type(row, 23) == SQLITE_NULL
          ? nil : sqlite3_column_int64(row, 23),
        reasoningEffort: string(24), serviceTier: string(25), actualServiceTier: string(26),
        requestMetadataRecorded: sqlite3_column_int64(row, 27) == 1)
    }
    let more = rows.count > query.limit
    if more { rows.removeLast() }
    return .init(
      totals: totals, buckets: buckets, rows: rows, nextCursor: more ? rows.last?.cursor : nil)
  }
  static func metrics(_ row: OpaquePointer, offset: Int32) throws -> UsageMetrics {
    func number(_ index: Int32) throws -> Int64? {
      if sqlite3_column_type(row, index) == SQLITE_NULL { return nil }
      guard sqlite3_column_type(row, index) == SQLITE_INTEGER, sqlite3_column_int64(row, index) >= 0
      else { throw ExecutionError.storageUnavailable }
      return sqlite3_column_int64(row, index)
    }
    return try .init(
      inputTokens: number(offset), outputTokens: number(offset + 1),
      cachedTokens: number(offset + 2), images: number(offset + 3),
      estimatedMicros: number(offset + 4), imageInputTokens: number(offset + 5),
      imageOutputTokens: number(offset + 6), imageInputTextTokens: number(offset + 7),
      imageInputImageTokens: number(offset + 8))
  }
}

extension SQLiteUsageReader {
  static func daily(_ db: SQLiteConnection, _ query: UsageQuery) throws -> [DailyUsageBucket] {
    var terms = ["created_at_epoch>=?", "created_at_epoch<?"]
    var values: [SQLiteConnection.Value] = [
      .number(query.startUnixSeconds), .number(query.endUnixSeconds),
    ]
    if let key = query.keyID {
      terms.append("key_id=?")
      values.append(.text(key))
    }
    if let model = query.model {
      terms.append("json_extract(admission_json,'$.model')=?")
      values.append(.text(model))
    }
    let source = """
      (SELECT created_at_epoch,key_id,admission_json,outcome_json,usage_json,1 record_count,
        state='unknown' OR closed_unknown_at_epoch IS NOT NULL usage_unknown FROM attempts
      UNION ALL SELECT day_epoch,key_id,json_object('model',NULLIF(model,''),'mode',mode),json_object('kind',NULLIF(outcome,''),'failure',NULLIF(failure,'')),
        json_object('inputTokens',input_tokens,'outputTokens',output_tokens,'cachedTokens',cached_tokens,'images',images,'estimatedMicros',estimated_micros,
          'imageInputTokens',image_input_tokens,'imageOutputTokens',image_output_tokens,'imageInputTextTokens',image_input_text_tokens,'imageInputImageTokens',image_input_image_tokens),requests,usage_unknown FROM usage_daily)
      """
    let predicate = terms.joined(separator: " AND ")
    let rows = try db.rows(
      """
      SELECT created_at_epoch/86400*86400,SUM(record_count),
        COALESCE(SUM(CASE WHEN json_extract(outcome_json,'$.kind')='succeeded' THEN record_count ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN json_extract(outcome_json,'$.kind')='failed' THEN record_count ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN json_extract(outcome_json,'$.kind')='cancelled' THEN record_count ELSE 0 END),0),
        SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.inputTokens') END),SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.outputTokens') END),
        SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.cachedTokens') END),SUM(json_extract(usage_json,'$.images')),
        SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 AND json_extract(usage_json,'$.imageInputTokens') IS NULL AND json_extract(usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END),SUM(json_extract(usage_json,'$.imageInputTokens')),SUM(json_extract(usage_json,'$.imageOutputTokens')),SUM(json_extract(usage_json,'$.imageInputTextTokens')),SUM(json_extract(usage_json,'$.imageInputImageTokens')) FROM \(source) WHERE \(predicate) GROUP BY created_at_epoch/86400
      """, values
    ) { row in
      (
        sqlite3_column_int64(row, 0), sqlite3_column_int64(row, 1), sqlite3_column_int64(row, 2),
        sqlite3_column_int64(row, 3), sqlite3_column_int64(row, 4), try metrics(row, offset: 5)
      )
    }
    let failures = try db.rows(
      """
      SELECT created_at_epoch/86400*86400,json_extract(outcome_json,'$.failure'),SUM(record_count) FROM \(source)
      WHERE \(predicate) AND json_extract(outcome_json,'$.failure') IS NOT NULL
      GROUP BY created_at_epoch/86400,json_extract(outcome_json,'$.failure')
      """, values
    ) {
      (
        sqlite3_column_int64($0, 0), String(cString: sqlite3_column_text($0, 1)),
        sqlite3_column_int64($0, 2)
      )
    }
    let unknown = try db.rows(
      "SELECT created_at_epoch/86400*86400,COALESCE(json_extract(outcome_json,'$.failure'),'unspecified'),SUM(record_count) FROM \(source) WHERE \(predicate) AND usage_unknown GROUP BY 1,2",
      values
    ) {
      (
        sqlite3_column_int64($0, 0), String(cString: sqlite3_column_text($0, 1)),
        sqlite3_column_int64($0, 2)
      )
    }
    let indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, $0) })
    let empty = UsageMetrics(
      inputTokens: nil, outputTokens: nil, cachedTokens: nil, images: nil, estimatedMicros: nil)
    return stride(from: query.startUnixSeconds, to: query.endUnixSeconds, by: 86400).map { at in
      let row = indexed[at]
      return DailyUsageBucket(
        atUnixSeconds: at, requests: row?.1 ?? 0, succeeded: row?.2 ?? 0,
        failed: row?.3 ?? 0, cancelled: row?.4 ?? 0,
        failures: Dictionary(
          uniqueKeysWithValues: failures.filter { $0.0 == at }.map { ($0.1, $0.2) }),
        metrics: row?.5 ?? empty,
        usageUnknown: unknown.filter { $0.0 == at }.reduce(0) { $0 + $1.2 },
        unknownReasons: Dictionary(
          uniqueKeysWithValues: unknown.filter { $0.0 == at }.map { ($0.1, $0.2) }))
    }
  }
}
