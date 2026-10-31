import CSQLite
import CodexOneCore
import Foundation

extension SQLiteUsageReader: GovernanceReading {
  public var governanceStoragePolicy: StorageSpacePolicy { primary.storage.policy }
  public var governanceStorage: StorageObservation { primary.storageObservation }
  public func governanceHeadroom(now: Int64) async throws -> GovernanceHeadroom {
    let limits = primary.limits
    return try await read { db in
      try Self.headroom(db, now: now, limits: limits)
    }
  }
  static func headroom(_ db: SQLiteConnection, now: Int64, limits: ExecutionLimits) throws
    -> GovernanceHeadroom
  {
    let start = now / 86400 * 86400
    let today = try db.rows(
      "SELECT COUNT(*),SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1 AND json_extract(usage_json,'$.imageInputTokens') IS NULL AND json_extract(usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END) FROM attempts WHERE created_at_epoch>=? AND created_at_epoch<?",
      [.number(start), .number(start + 86400)]
    ) {
      (
        sqlite3_column_int64($0, 0),
        sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 1)
      )
    }[0]
    let accounts = try db.rows(
      """
      SELECT ids.id,
        (SELECT COUNT(*) FROM attempts a WHERE a.identity=ids.id AND a.namespace=ids.namespace AND a.state='intent'),
        (SELECT COALESCE(MAX(peak),0) FROM account_concurrency c WHERE c.identity=ids.id AND c.namespace=ids.namespace AND c.at_epoch>=? AND c.at_epoch<=?)
      FROM (SELECT id,namespace FROM accounts UNION SELECT DISTINCT identity,namespace FROM attempts) ids ORDER BY ids.id LIMIT 65
      """, [.number(now - 86400), .number(now)]
    ) {
      AccountCapacity(
        id: String(cString: sqlite3_column_text($0, 0)), current: sqlite3_column_int64($0, 1),
        peak24Hours: max(sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2)))
    }
    guard accounts.count <= 64 else { throw ExecutionError.capacity }
    var capacities: [GovernanceCapacity] = []
    if let requests = limits.requests {
      capacities.append(
        .init(name: "daily_requests", current: today.0, limit: requests, blocking: false))
    }
    if let budget = limits.budgetMicros {
      capacities.append(
        .init(name: "daily_estimated_micros", current: today.1, limit: budget, blocking: false))
    }
    capacities.append(
      .init(
        name: "detail_rows", current: try db.scalar("SELECT COUNT(*) FROM attempts"),
        limit: ExecutionLimits.detailReferenceRows, blocking: false))
    return GovernanceHeadroom(
      capacities: capacities, accounts: accounts,
      unknownCount: try db.scalar(
        "SELECT COUNT(*) FROM attempts WHERE state='unknown' AND created_at_epoch<?", [.number(now)]
      ), beforeUnixSeconds: now)
  }
}
