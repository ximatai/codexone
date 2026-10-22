import CSQLite
import CodexOneCore
import Dispatch
import Foundation
import Synchronization

public final class SQLiteExecutionStore: ExecutionStore, Sendable {
  private let queue = DispatchQueue(label: "codexone.core-database")
  private let connection: SQLiteConnection
  let limits: ExecutionLimits
  private let gate = Mutex((regular: 0, critical: 0, closing: false, failed: false))

  public var isAvailable: Bool { gate.withLock { !$0.closing && !$0.failed } }

  init(connection: SQLiteConnection, limits: ExecutionLimits) {
    self.connection = connection
    self.limits = limits
  }
  /// Call before publishing any admission path. Initialization never blocks a network event loop.
  public static func open(path: String, limits: ExecutionLimits) async throws
    -> SQLiteExecutionStore
  {
    guard
      [
        limits.requests, limits.active, limits.unresolved, limits.budgetMicros,
        limits.unresolvedMicros,
      ].allSatisfy({
        $0 > 0 && $0 <= 1_000_000_000_000
      })
    else {
      throw ExecutionError.invalidCommand
    }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try SQLiteConnection(path: path)
          try connection.transaction {
            let json = try encode(limits)
            let existing = try connection.rows("SELECT limits_json FROM metadata WHERE id=1") {
              String(cString: sqlite3_column_text($0, 0))
            }
            if let existing = existing.first {
              guard try decode(ExecutionLimits.self, existing) == limits else {
                throw ExecutionError.conflict
              }
            } else {
              try connection.write("INSERT INTO metadata VALUES(1,?)", [.text(json)])
            }
            // All intents belonged to the previous owner, whose instance lock is now ours.
            try connection.write("UPDATE attempts SET state='unknown' WHERE state='intent'")
            try Self.recoverAccountRefreshes(connection)
          }
          continuation.resume(
            returning: SQLiteExecutionStore(connection: connection, limits: limits))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// Offline, instance-locked upgrade; a consistent private backup precedes any schema change.
  public static func migrate(path: String) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try SQLiteConnection(path: path, migrating: true)
          connection.shutdown()
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// Queue capacity is acquired before dispatch; finalization has its own reserved slots.
  func perform<T: Sendable>(
    critical: Bool = false, admission: Bool = false,
    _ body: @escaping @Sendable (SQLiteConnection) throws -> T
  ) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
      let accepted = gate.withLock { state in
        guard !state.closing else { return false }
        if critical {
          guard state.critical < 16 else { return false }
          state.critical += 1
        } else {
          guard state.regular < 16 else { return false }
          state.regular += 1
        }
        // Enqueue under the gate so close cannot overtake an already accepted command.
        queue.async { [self] in
          let result = Result {
            if admission && gate.withLock({ $0.failed }) { throw ExecutionError.storageUnavailable }
            return try body(connection)
          }
          gate.withLock { state in
            if case .failure(let error) = result, error as? ExecutionError == .storageUnavailable {
              state.failed = true
            }
            if critical { state.critical -= 1 } else { state.regular -= 1 }
          }
          continuation.resume(with: result)
        }
        return true
      }
      if !accepted { continuation.resume(throwing: ExecutionError.capacity) }
    }
  }

  public func close() async {
    await withCheckedContinuation { continuation in
      gate.withLock { state in
        state.closing = true
        queue.async { [self] in
          connection.shutdown()
          continuation.resume()
        }
      }
    }
  }

  public func admit(_ command: ExecutionAdmission) async throws {
    try validateAdmission(command)
    try await perform(admission: true) { [limits] db in
      try db.transaction { try Self.admitTransaction(db, command, limits: limits) }
    }
  }
  static func admitTransaction(
    _ db: SQLiteConnection, _ command: ExecutionAdmission, limits: ExecutionLimits
  ) throws {
    try validateAdmission(command)
    guard
      try db.scalar("SELECT COUNT(*) FROM attempts WHERE id=?", [.text(command.attempt)]) == 0
    else { throw ExecutionError.conflict }
    guard try db.scalar("SELECT COUNT(*) FROM attempts") < 100_000 else {
      throw ExecutionError.capacity
    }
    try Self.checkAccountAdmission(db, command)
    try Self.checkKeyAdmission(db, command)
    // Lifetime unresolved/active exposure survives window rotation. Budget/request totals belong to the admission window.
    for (scope, parameters) in [
      ("1=1", [SQLiteConnection.Value]()),
      ("principal=?", [.text(command.owner.principal)]),
      (
        "namespace=? AND identity=?",
        [.text(command.owner.namespace), .text(command.owner.identity)]
      ),
    ] {
      let counts = try db.rows(
        """
        SELECT COUNT(*), COALESCE(SUM(CASE WHEN state='intent' THEN 1 ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN state!='settled' THEN 1 ELSE 0 END),0)
        FROM attempts WHERE \(scope)
        """, parameters
      ) { s in
        (sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_int64(s, 2))
      }[0]
      let requests = try db.scalar(
        "SELECT COUNT(*) FROM attempts WHERE \(scope) AND window_id=?",
        parameters + [.text(command.window)])
      let exposure = try db.scalar(
        "SELECT COALESCE(SUM(estimated + CASE WHEN state!='settled' THEN MAX(reserved-estimated,0) ELSE 0 END),0) FROM attempts WHERE \(scope) AND window_id=?",
        parameters + [.text(command.window)])
      let unresolvedMicros = try db.scalar(
        "SELECT COALESCE(SUM(MAX(reserved,estimated)),0) FROM attempts WHERE \(scope) AND state!='settled'",
        parameters)
      guard command.reservedMicros <= limits.unresolvedMicros,
        unresolvedMicros <= limits.unresolvedMicros - command.reservedMicros,
        requests < limits.requests, counts.1 < limits.active, counts.2 < limits.unresolved,
        command.reservedMicros <= limits.budgetMicros,
        exposure <= limits.budgetMicros - command.reservedMicros
      else {
        throw ExecutionError.denied
      }
    }
    try db.write(
      """
      INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,reserved,state,admission_json)
      VALUES(?,?,?,?,?,?,?,?,?,'intent',?)
      """,
      [
        .text(command.attempt), .text(command.owner.principal), .text(command.owner.key),
        .text(command.owner.namespace), .text(command.owner.identity), .text(command.window),
        .text(command.policyVersion), .text(command.pricingVersion),
        .number(command.reservedMicros), .text(try encode(command)),
      ])
  }

  public func bind(attempt: String, object: ObjectBinding) async throws {
    try validateStrings([attempt, object.type, object.rawID])
    try await perform { db in
      try db.transaction {
        let snapshot = try Self.load(db, attempt)
        guard snapshot.state == .intent else { throw ExecutionError.conflict }
        let owner = snapshot.admission.owner
        let values: [SQLiteConnection.Value] = [
          .text(owner.principal), .text(owner.namespace), .text(owner.identity), .text(object.type),
          .text(object.rawID),
        ]
        let matches = try db.rows(
          "SELECT attempt FROM bindings WHERE principal=? AND namespace=? AND identity=? AND object_type=? AND raw_id=?",
          values
        ) { String(cString: sqlite3_column_text($0, 0)) }
        if let bound = matches.first {
          guard bound == attempt else { throw ExecutionError.conflict }
          return
        }
        guard try db.scalar("SELECT COUNT(*) FROM bindings WHERE attempt=?", [.text(attempt)]) < 32
        else { throw ExecutionError.capacity }
        try db.write("INSERT INTO bindings VALUES(?,?,?,?,?,?)", values + [.text(attempt)])
      }
    }
  }

  public func resolve(principal: String, object: ObjectBinding, namespace: String? = nil)
    async throws -> ExecutionOwner
  {
    try validateStrings([principal, object.type, object.rawID])
    if let namespace { try validateStrings([namespace], maximum: 512) }
    return try await perform { db in
      var sql =
        "SELECT a.admission_json FROM bindings b JOIN attempts a ON a.id=b.attempt WHERE b.principal=? AND b.object_type=? AND b.raw_id=?"
      var values: [SQLiteConnection.Value] = [
        .text(principal), .text(object.type), .text(object.rawID),
      ]
      if let namespace {
        sql += " AND b.namespace=?"
        values.append(.text(namespace))
      }
      sql += " LIMIT 2"
      let owners = try db.rows(sql, values) {
        try decode(ExecutionAdmission.self, String(cString: sqlite3_column_text($0, 0))).owner
      }
      guard let owner = owners.first else { throw ExecutionError.unknownObject }
      guard owners.count == 1 else { throw ExecutionError.ambiguousObject }
      return owner
    }
  }

  public func finalize(attempt: String, evidence: UsageEvidence?) async throws {
    try validateStrings([attempt])
    if let evidence { try validate(evidence) }
    try await perform(critical: true) { db in
      try db.transaction {
        let snapshot = try Self.load(db, attempt)
        guard let evidence else {
          if snapshot.state == .intent {
            try db.write("UPDATE attempts SET state='unknown' WHERE id=?", [.text(attempt)])
          }
          return
        }
        let existing = try db.rows(
          "SELECT payload FROM evidence WHERE attempt=? AND revision=?",
          [.text(attempt), .number(evidence.revision)]
        ) { String(cString: sqlite3_column_text($0, 0)) }
        if let existing = existing.first {
          guard try decode(UsageEvidence.self, existing) == evidence else {
            throw ExecutionError.conflict
          }
          return
        }
        let floor = try db.scalar(
          "SELECT evidence_floor FROM attempts WHERE id=?", [.text(attempt)])
        guard evidence.revision > floor else { throw ExecutionError.staleEvidence }
        if let old = snapshot.usage, evidence.revision > old.revision {
          guard evidence.inputTokens >= old.inputTokens, evidence.outputTokens >= old.outputTokens,
            evidence.cachedTokens >= old.cachedTokens, evidence.images >= old.images,
            evidence.estimatedMicros >= old.estimatedMicros,
            old.completeness != .complete || evidence.completeness == .complete
          else { throw ExecutionError.conflict }
        }
        if let old = snapshot.usage, evidence.revision < old.revision {
          guard evidence.inputTokens <= old.inputTokens, evidence.outputTokens <= old.outputTokens,
            evidence.cachedTokens <= old.cachedTokens, evidence.images <= old.images,
            evidence.estimatedMicros <= old.estimatedMicros,
            evidence.completeness != .complete || old.completeness == .complete
          else {
            throw ExecutionError.conflict
          }
        }
        try db.write(
          "INSERT INTO evidence VALUES(?,?,?)",
          [
            .text(attempt), .number(evidence.revision),
            .text(try encode(evidence)),
          ])
        if try db.scalar("SELECT COUNT(*) FROM evidence WHERE attempt=?", [.text(attempt)]) > 128 {
          let retired = try db.scalar(
            "SELECT MIN(revision) FROM evidence WHERE attempt=?", [.text(attempt)])
          try db.write(
            "DELETE FROM evidence WHERE attempt=? AND revision=?",
            [.text(attempt), .number(retired)])
          try db.write(
            "UPDATE attempts SET evidence_floor=? WHERE id=?", [.number(retired), .text(attempt)])
        }
        if snapshot.usage == nil || evidence.revision > snapshot.usage!.revision {
          try db.write(
            "UPDATE attempts SET state=?,usage_json=?,estimated=? WHERE id=?",
            [
              .text(evidence.completeness == .complete ? "settled" : "unknown"),
              .text(try encode(evidence)),
              .number(evidence.estimatedMicros), .text(attempt),
            ])
        }
      }
    }
  }

  public func snapshot(attempt: String) async throws -> ExecutionSnapshot {
    try validateStrings([attempt])
    return try await perform { try Self.load($0, attempt) }
  }
  private static func load(_ db: SQLiteConnection, _ attempt: String) throws -> ExecutionSnapshot {
    let results = try db.rows(
      "SELECT admission_json,state,usage_json FROM attempts WHERE id=?", [.text(attempt)]
    ) { s in
      let admission = try decode(
        ExecutionAdmission.self, String(cString: sqlite3_column_text(s, 0)))
      guard
        let state = ExecutionSnapshot.State(rawValue: String(cString: sqlite3_column_text(s, 1)))
      else { throw ExecutionError.storageUnavailable }
      let usage =
        sqlite3_column_type(s, 2) == SQLITE_NULL
        ? nil : try decode(UsageEvidence.self, String(cString: sqlite3_column_text(s, 2)))
      return ExecutionSnapshot(admission: admission, state: state, usage: usage)
    }
    guard let result = results.first else { throw ExecutionError.unknownAttempt }
    return result
  }
}

private func validateStrings(_ values: [String], maximum: Int = 256) throws {
  guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximum && !$0.utf8.contains(0) })
  else {
    throw ExecutionError.invalidCommand
  }
}
func validateAdmission(_ value: ExecutionAdmission) throws {
  try validateStrings(
    [
      value.attempt, value.owner.principal, value.owner.key,
      value.owner.identity, value.window, value.policyVersion, value.pricingVersion,
    ] + (value.requestID.map { [$0] } ?? []) + (value.model.map { [$0] } ?? []))
  try validateStrings([value.owner.namespace], maximum: 512)
  if let account = value.accountSnapshot {
    _ = try AccountDispatchSnapshot(
      revision: account.revision, credentialVersion: account.credentialVersion,
      accessExpiresAtUnixSeconds: account.accessExpiresAtUnixSeconds,
      continuation: account.continuation)
  }
  guard (0...1_000_000_000_000).contains(value.reservedMicros) else {
    throw ExecutionError.invalidCommand
  }
}
private func validate(_ value: UsageEvidence) throws {
  guard
    [
      value.revision, value.inputTokens, value.outputTokens, value.cachedTokens, value.images,
      value.estimatedMicros,
    ].allSatisfy({ (0...1_000_000_000_000).contains($0) }), value.cachedTokens <= value.inputTokens
  else { throw ExecutionError.invalidCommand }
}
private func encode<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}
private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
  do { return try JSONDecoder().decode(type, from: Data(value.utf8)) } catch {
    throw ExecutionError.storageUnavailable
  }
}
