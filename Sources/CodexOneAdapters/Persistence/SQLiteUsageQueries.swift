import CSQLite
import CodexOneCore
import Foundation

private struct UsagePredicate {
  var terms: [String] = []
  var values: [SQLiteConnection.Value] = []
  var sql: String { terms.isEmpty ? "1" : terms.joined(separator: " AND ") }
}
extension SQLiteUsageReader {
  private static func predicate(_ query: UsageQuery, diagnostic: Bool, timed: Bool = true)
    -> UsagePredicate
  {
    var result = UsagePredicate()
    func add(_ expression: String, _ value: SQLiteConnection.Value) {
      result.terms.append(expression)
      result.values.append(value)
    }
    let epoch = diagnostic ? "at_epoch" : "created_at_epoch"
    if diagnostic { add("at_epoch>=?", .number(Int64(Date().timeIntervalSince1970) - 30 * 86400)) }
    if timed {
      add("\(epoch)>=?", .number(query.startUnixSeconds))
      add("\(epoch)<?", .number(query.endUnixSeconds))
    }
    if let key = query.keyID { add("key_id=?", .text(key)) }
    if let model = query.model {
      add(diagnostic ? "model=?" : "json_extract(admission_json,'$.model')=?", .text(model))
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
      if diagnostic { result.terms.append("0") } else { add("state=?", .text(state.rawValue)) }
    }
    return result
  }
  static func query(_ db: SQLiteConnection, _ query: UsageQuery) throws -> UsageReport {
    let attempts = predicate(query, diagnostic: false)
    let rejected = predicate(query, diagnostic: true)
    let base = predicate(query, diagnostic: false, timed: false)
    let untimed = try db.scalar(
      "SELECT COUNT(*) FROM attempts WHERE created_at_epoch IS NULL AND \(base.sql)", base.values)
    let rejectionCount = try db.scalar(
      "SELECT COUNT(*) FROM request_diagnostics WHERE \(rejected.sql)", rejected.values)
    let lifetime = try db.rows(
      "SELECT COALESCE(SUM(state='intent'),0),COALESCE(SUM(state='unknown'),0),COALESCE(SUM(CASE WHEN state!='settled' THEN MAX(reserved,estimated) ELSE 0 END),0) FROM attempts"
        + (query.keyID == nil ? "" : " WHERE key_id=?"),
      query.keyID.map { [.text($0)] } ?? []
    ) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2)) }[0]
    let totals = try db.rows(
      """
      SELECT COUNT(*),COALESCE(SUM(state='intent'),0),COALESCE(SUM(state='unknown'),0),
        COALESCE(SUM(json_extract(usage_json,'$.completeness')='complete'),0),
        COALESCE(SUM(json_extract(usage_json,'$.completeness')='partial'),0),COALESCE(SUM(usage_json IS NULL),0),
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
        metrics: try metrics(row, offset: 9))
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
      SELECT history.*, (SELECT json_extract(metadata_json,'$.principal') FROM managed_keys WHERE id=history.key_id) FROM (
      SELECT 'admitted' kind,'a:'||id cursor_id,id,created_at_epoch at_epoch,key_id,
        json_extract(admission_json,'$.model') model,COALESCE(json_extract(admission_json,'$.mode'),'generation') mode,
        identity,request_id,state,json_extract(outcome_json,'$.kind') outcome,
        json_extract(outcome_json,'$.failure') failure,json_extract(usage_json,'$.completeness') completeness,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.inputTokens') END input_tokens,CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.outputTokens') END output_tokens,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.cachedTokens') END cached_tokens,json_extract(usage_json,'$.images') images,
        CASE WHEN json_extract(usage_json,'$.nativeImages')=1 AND json_extract(usage_json,'$.imageInputTokens') IS NULL AND json_extract(usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END estimated_micros, json_extract(usage_json,'$.imageInputTokens') image_input_tokens,json_extract(usage_json,'$.imageOutputTokens') image_output_tokens,json_extract(usage_json,'$.imageInputTextTokens') image_input_text_tokens,json_extract(usage_json,'$.imageInputImageTokens') image_input_image_tokens,json_extract(outcome_json,'$.firstEventMilliseconds'),json_extract(outcome_json,'$.totalMilliseconds') FROM attempts WHERE \(attempts.sql)
      UNION ALL
      SELECT 'rejected','r:'||request_id,request_id,at_epoch,key_id,model,mode,NULL,request_id,NULL,'failed',failure,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
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
        cursor: .init(atUnixSeconds: at, id: cursorID), principal: string(24),
        firstEventMilliseconds: sqlite3_column_type(row, 22) == SQLITE_NULL
          ? nil : sqlite3_column_int64(row, 22),
        totalMilliseconds: sqlite3_column_type(row, 23) == SQLITE_NULL
          ? nil : sqlite3_column_int64(row, 23))
    }
    let more = rows.count > query.limit
    if more { rows.removeLast() }
    return .init(
      totals: totals, buckets: buckets, rows: rows, nextCursor: more ? rows.last?.cursor : nil)
  }
  private static func metrics(_ row: OpaquePointer, offset: Int32) throws -> UsageMetrics {
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
