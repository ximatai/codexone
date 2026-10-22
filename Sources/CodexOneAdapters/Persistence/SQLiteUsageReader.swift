import CSQLite
import CodexOneCore
import Dispatch
import Foundation
import Synchronization

extension SQLiteExecutionStore {
  public func makeUsageReader() async throws -> SQLiteUsageReader {
    guard
      usageReaderGate.withLock({ value in
        if value { return false }
        value = true
        return true
      })
    else {
      throw ExecutionError.conflict
    }
    do { return try await SQLiteUsageReader.open(primary: self, path: path) } catch {
      usageReaderGate.withLock { $0 = false }
      throw error
    }
  }
}
/// One read-only snapshot at a time, on its own queue. Statistical scans never enter the core writer queue.
public final class SQLiteUsageReader: UsageQuerying, Sendable {
  private let queue: DispatchQueue
  private let connection: SQLiteConnection
  private let primary: SQLiteExecutionStore
  private let gate = Mutex((accepting: true, active: false))
  private init(primary: SQLiteExecutionStore, connection: SQLiteConnection, queue: DispatchQueue) {
    self.primary = primary
    self.connection = connection
    self.queue = queue
  }
  fileprivate static func open(primary: SQLiteExecutionStore, path: String) async throws
    -> SQLiteUsageReader
  {
    let queue = DispatchQueue(label: "codexone.usage-reader")
    return try await withCheckedThrowingContinuation { result in
      queue.async {
        do {
          guard primary.isAvailable else { throw ExecutionError.closed }
          result.resume(
            returning: SQLiteUsageReader(
              primary: primary, connection: try SQLiteConnection(readOnlyPath: path), queue: queue))
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
  public func usageOptions() async throws -> (keys: [String], models: [String]) {
    try await read { db in
      let keys = try db.rows("SELECT id FROM managed_keys ORDER BY id LIMIT 257") {
        String(cString: sqlite3_column_text($0, 0))
      }
      let models = try db.rows("SELECT model FROM health_models ORDER BY model LIMIT 49") {
        String(cString: sqlite3_column_text($0, 0))
      }
      guard keys.count <= 256, models.count <= 48 else { throw ExecutionError.capacity }
      return (keys, models)
    }
  }
  private func read<T: Sendable>(_ operation: @escaping @Sendable (SQLiteConnection) throws -> T)
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
      gate.withLock { $0.active = false }
      primary.usageActivity.withLock { $0 = false }
    }
    let budget = UsageReadBudget(optionalAllowed: { self.primary.allowsOptionalStorageWork })
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
  private let deadline = ContinuousClock.now.advanced(by: .seconds(1))
  private let optionalAllowed: @Sendable () -> Bool
  init(optionalAllowed: @escaping @Sendable () -> Bool) { self.optionalAllowed = optionalAllowed }
  var shouldStop: Bool {
    cancelled.withLock { $0 } || !optionalAllowed() || ContinuousClock.now >= deadline
  }
}
