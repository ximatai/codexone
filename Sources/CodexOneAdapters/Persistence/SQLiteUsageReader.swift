import CSQLite
import CodexOneCore
import Dispatch
import Foundation
import Synchronization

extension SQLiteExecutionStore {
  public func makeUsageReader(readTimeout: Duration = .seconds(1)) async throws -> SQLiteUsageReader
  {
    guard
      usageReaderGate.withLock({ value in
        if value { return false }
        value = true
        return true
      })
    else {
      throw ExecutionError.conflict
    }
    do {
      return try await SQLiteUsageReader.open(primary: self, path: path, readTimeout: readTimeout)
    } catch {
      usageReaderGate.withLock { $0 = false }
      throw error
    }
  }
}
/// One read-only snapshot at a time, on its own queue. Statistical scans never enter the core writer queue.
public final class SQLiteUsageReader: UsageQuerying, Sendable {
  private let queue: DispatchQueue
  private let connection: SQLiteConnection
  let primary: SQLiteExecutionStore
  private let gate = Mutex((accepting: true, active: false))
  private let readTimeout: Duration
  private init(
    primary: SQLiteExecutionStore, connection: SQLiteConnection, queue: DispatchQueue,
    readTimeout: Duration
  ) {
    self.readTimeout = readTimeout
    self.primary = primary
    self.connection = connection
    self.queue = queue
  }
  fileprivate static func open(primary: SQLiteExecutionStore, path: String, readTimeout: Duration)
    async throws
    -> SQLiteUsageReader
  {
    let queue = DispatchQueue(label: "codexone.usage-reader")
    return try await withCheckedThrowingContinuation { result in
      queue.async {
        do {
          guard primary.isAvailable else { throw ExecutionError.closed }
          result.resume(
            returning: SQLiteUsageReader(
              primary: primary,
              connection: try SQLiteConnection(readOnlyPath: path, clock: primary.clock),
              queue: queue,
              readTimeout: readTimeout))
        } catch { result.resume(throwing: error) }
      }
    }
  }
  public func close() async {
    gate.withLock { $0.accepting = false }
    await withCheckedContinuation { result in
      queue.async {
        self.connection.shutdown()
        result.resume()
      }
    }
  }
  public func queryUsage(_ query: UsageQuery) async throws -> UsageReport {
    try await read { try Self.query($0, query) }
  }
  public func usageOptions() async throws -> (
    keys: [String], models: [String], keyOptions: [UsageKeyOption]
  ) {
    try await read { db in
      let keys = try db.rows(
        "SELECT ids.id,json_extract(k.metadata_json,'$.principal'),json_extract(k.metadata_json,'$.displayName'),json_extract(k.metadata_json,'$.archivedAtUnixSeconds') IS NOT NULL FROM (SELECT id FROM managed_keys UNION SELECT key_id FROM attempts UNION SELECT key_id FROM usage_daily UNION SELECT key_id FROM request_diagnostics) ids LEFT JOIN managed_keys k ON k.id=ids.id ORDER BY ids.id LIMIT 257"
      ) {
        UsageKeyOption(
          id: String(cString: sqlite3_column_text($0, 0)),
          principal: sqlite3_column_type($0, 1) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text($0, 1)),
          displayName: sqlite3_column_type($0, 2) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text($0, 2)),
          archived: sqlite3_column_int($0, 3) != 0)
      }
      let models = try db.rows("SELECT model FROM health_models ORDER BY model LIMIT 49") {
        String(cString: sqlite3_column_text($0, 0))
      }
      guard keys.count <= 256, models.count <= 48 else { throw ExecutionError.capacity }
      return (keys.map(\.id), models, keys)
    }
  }
  public func keyUsage() async throws -> (startUnixSeconds: Int64, keys: [KeyUsageSummary]) {
    try await read { db in
      let start = db.clock.unixSeconds / 86400 * 86400
      let rows = try db.rows(
        """
        SELECT k.id,json_extract(k.metadata_json,'$.principal'),
          COUNT(CASE WHEN a.created_at_epoch>=? AND a.created_at_epoch<? THEN 1 END),
          COALESCE(SUM(CASE WHEN a.created_at_epoch>=? AND a.created_at_epoch<? THEN json_extract(a.outcome_json,'$.kind')='failed' ELSE 0 END),0),
          COALESCE(SUM(CASE WHEN a.created_at_epoch>=? AND a.created_at_epoch<? THEN a.state!='settled' ELSE 0 END),0),
          SUM(CASE WHEN a.created_at_epoch>=? AND a.created_at_epoch<? THEN
            CASE WHEN json_extract(a.usage_json,'$.nativeImages')=1 AND json_extract(a.usage_json,'$.imageInputTokens') IS NULL AND json_extract(a.usage_json,'$.imageOutputTokens') IS NULL THEN NULL ELSE json_extract(a.usage_json,'$.estimatedMicros') END END),
          CASE WHEN MAX(a.created_at_epoch) IS NULL THEN (SELECT MAX(last_used_epoch) FROM usage_daily d WHERE d.key_id=k.id)
            WHEN (SELECT MAX(last_used_epoch) FROM usage_daily d WHERE d.key_id=k.id) IS NULL THEN MAX(a.created_at_epoch)
            ELSE MAX(MAX(a.created_at_epoch),(SELECT MAX(last_used_epoch) FROM usage_daily d WHERE d.key_id=k.id)) END,json_extract(k.metadata_json,'$.displayName')
        FROM managed_keys k LEFT JOIN attempts a ON a.key_id=k.id
        GROUP BY k.id ORDER BY k.id LIMIT 257
        """, (0..<4).flatMap { _ in [.number(start), .number(start + 86400)] }
      ) { row in
        KeyUsageSummary(
          key: .init(
            id: String(cString: sqlite3_column_text(row, 0)),
            principal: String(cString: sqlite3_column_text(row, 1)),
            displayName: sqlite3_column_type(row, 7) == SQLITE_NULL
              ? nil : String(cString: sqlite3_column_text(row, 7))),
          admitted: sqlite3_column_int64(row, 2), failed: sqlite3_column_int64(row, 3),
          pending: sqlite3_column_int64(row, 4),
          estimatedMicros: sqlite3_column_type(row, 5) == SQLITE_NULL
            ? nil : sqlite3_column_int64(row, 5),
          lastUsedAtUnixSeconds: sqlite3_column_type(row, 6) == SQLITE_NULL
            ? nil : sqlite3_column_int64(row, 6))
      }
      guard rows.count <= 256 else { throw ExecutionError.capacity }
      return (start, rows)
    }
  }
  public func inFlightUsage(limit: Int) async throws -> [InFlightUsageRow] {
    guard (1...200).contains(limit) else { throw ExecutionError.invalidCommand }
    return try await read { [primary] db in
      let events = primary.liveFirstEvents.withLock { $0 }
      let now = db.clock.unixSeconds
      return try db.rows(
        """
        SELECT a.id,a.key_id,COALESCE(json_extract(k.metadata_json,'$.principal'),CASE WHEN json_extract(a.admission_json,'$.mode')='priming' THEN a.principal END),json_extract(a.admission_json,'$.model'),
          COALESCE(json_extract(a.admission_json,'$.mode'),'generation'),a.identity,c.display_name,a.created_at_epoch,json_extract(k.metadata_json,'$.displayName')
        FROM attempts a LEFT JOIN managed_keys k ON k.id=a.key_id LEFT JOIN accounts c ON c.id=a.identity
        WHERE a.state='intent' ORDER BY a.created_at_epoch DESC,a.id DESC LIMIT ?
        """, [.number(Int64(limit))]
      ) { row in
        func text(_ i: Int32) -> String? {
          sqlite3_column_type(row, i) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(row, i))
        }
        guard let id = text(0), let key = text(1), let account = text(5),
          let mode = text(4).flatMap(ExecutionMode.init(rawValue:))
        else { throw ExecutionError.storageUnavailable }
        let start: Int64? =
          sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 7)
        return InFlightUsageRow(
          id: id, keyID: key, principal: text(2), model: text(3), mode: mode,
          accountID: account, accountDisplayName: text(6), startedAtUnixSeconds: start,
          elapsedSeconds: start.map { max(0, now - $0) }, hasFirstEvent: events[id],
          displayName: text(8))
      }
    }
  }
  public func dailyUsage(days: Int, keyID: String?, model: String?) async throws
    -> [DailyUsageBucket]
  {
    try await dailyUsage(days: days, keyID: keyID, model: model, endUnixSeconds: nil)
  }
  public func dailyUsage(days: Int, keyID: String?, model: String?, endUnixSeconds: Int64?)
    async throws -> [DailyUsageBucket]
  {
    guard (1...31).contains(days) else { throw ExecutionError.invalidCommand }
    let end = endUnixSeconds ?? (primary.clock.unixSeconds / 86400 * 86400 + 86400)
    guard end >= Int64(days) * 86400, end % 86400 == 0 else { throw ExecutionError.invalidCommand }
    let query = try UsageQuery(
      startUnixSeconds: end - Int64(days) * 86400, endUnixSeconds: end, keyID: keyID, model: model)
    return try await read { db in try Self.daily(db, query) }
  }
  func read<T: Sendable>(_ operation: @escaping @Sendable (SQLiteConnection) throws -> T)
    async throws -> T
  {
    try Task.checkCancellation()
    guard
      gate.withLock({ value in
        guard value.accepting && !value.active && primary.allowsOptionalStorageWork else {
          return false
        }
        value.active = true
        return true
      })
    else { throw ExecutionError.capacity }
    primary.usageActivity.withLock { $0 = true }
    defer {
      gate.withLock {
        $0.active = false
        primary.usageActivity.withLock { $0 = false }
      }
    }
    let budget = UsageReadBudget(
      timeout: readTimeout, optionalAllowed: { self.primary.allowsOptionalStorageWork })
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { result in
        queue.async { [connection] in
          do {
            guard !budget.cancelled.withLock({ $0 }) else { throw CancellationError() }
            sqlite3_progress_handler(
              connection.handle, 1000,
              { opaque in
                guard let opaque else { return 1 }
                let budget = Unmanaged<UsageReadBudget>.fromOpaque(opaque).takeUnretainedValue()
                return budget.shouldStop ? 1 : 0
              }, Unmanaged.passUnretained(budget).toOpaque())
            defer { sqlite3_progress_handler(connection.handle, 0, nil, nil) }
            try connection.exec("BEGIN")
            let value: T
            do {
              value = try operation(connection)
              sqlite3_progress_handler(connection.handle, 0, nil, nil)
              try connection.exec("COMMIT")
            } catch {
              sqlite3_progress_handler(connection.handle, 0, nil, nil)
              try? connection.exec("ROLLBACK")
              throw error
            }
            if budget.cancelled.withLock({ $0 }) { throw CancellationError() }
            result.resume(returning: value)
          } catch {
            result.resume(throwing: budget.cancelled.withLock({ $0 }) ? CancellationError() : error)
          }
        }
      }
    } onCancel: {
      budget.cancelled.withLock { $0 = true }
    }
  }
}
private final class UsageReadBudget: Sendable {
  let cancelled = Mutex(false)
  private let deadline: ContinuousClock.Instant
  private let optionalAllowed: @Sendable () -> Bool
  init(timeout: Duration, optionalAllowed: @escaping @Sendable () -> Bool) {
    deadline = ContinuousClock.now.advanced(by: timeout)
    self.optionalAllowed = optionalAllowed
  }
  var shouldStop: Bool {
    cancelled.withLock { $0 } || !optionalAllowed() || ContinuousClock.now >= deadline
  }
}
