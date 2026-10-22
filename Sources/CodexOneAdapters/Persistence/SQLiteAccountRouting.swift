import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: AccountRoutingStore {
  public func resolveAccountAffinity(
    principal: String, references: [ObjectBinding], connection: AccountRouteIdentity?
  ) async throws -> AccountRouteIdentity? {
    try Self.validateAccountReferences(principal: principal, references: references)
    return try await perform { db in
      try Self.accountAffinity(
        db, principal: principal, references: references, connection: connection)
    }
  }
  public func admitSelectingAccount(_ command: AccountPoolAdmission) async throws
    -> ExecutionAdmission
  {
    try Self.validateAccountReferences(
      principal: command.policy.key.principal, references: command.references)
    guard (1...64).contains(command.candidates.count) else { throw ExecutionError.invalidCommand }
    for candidate in command.candidates { try validateAdmission(command.selecting(candidate)) }
    return try await perform(admission: true) { [limits] db in
      try db.transaction {
        let affinity = try Self.accountAffinity(
          db, principal: command.policy.key.principal, references: command.references,
          connection: command.connection)
        var ranked: [(AccountRouteCandidate, Int64, UInt64)] = []
        for candidate in command.candidates {
          guard affinity == nil || affinity == candidate.identity,
            candidate.snapshot.continuation == (affinity == candidate.identity)
          else { continue }
          let admission = command.selecting(candidate)
          do { try Self.checkAccountAdmission(db, admission) } catch ExecutionError.conflict {
            continue
          } catch ExecutionError.denied { continue } catch ExecutionError.unknownObject { continue }
          let values: [SQLiteConnection.Value] = [
            .text(candidate.identity.namespace), .text(candidate.identity.id),
          ]
          let counts = try db.rows(
            """
            SELECT COALESCE(SUM(CASE WHEN state='intent' THEN 1 ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN state!='settled' THEN 1 ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN state!='settled' THEN MAX(reserved,estimated) ELSE 0 END),0)
            FROM attempts WHERE namespace=? AND identity=?
            """, values
          ) {
            (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2))
          }[0]
          let window = values + [.text(command.window)]
          let requests = try db.scalar(
            "SELECT COUNT(*) FROM attempts WHERE namespace=? AND identity=? AND window_id=?", window
          )
          let exposure = try db.scalar(
            "SELECT COALESCE(SUM(estimated + CASE WHEN state!='settled' THEN MAX(reserved-estimated,0) ELSE 0 END),0) FROM attempts WHERE namespace=? AND identity=? AND window_id=?",
            window)
          let reserved = command.policy.reservedMicros
          guard counts.0 < limits.active, counts.1 < limits.unresolved, requests < limits.requests,
            reserved <= limits.unresolvedMicros, counts.2 <= limits.unresolvedMicros - reserved,
            reserved <= limits.budgetMicros, exposure <= limits.budgetMicros - reserved
          else { continue }
          ranked.append(
            (
              candidate, counts.0,
              Self.routeTie(command.requestID ?? command.attempt, candidate.identity)
            ))
        }
        ranked.sort {
          if $0.1 != $1.1 { return $0.1 < $1.1 }
          if $0.2 != $1.2 { return $0.2 < $1.2 }
          return $0.0.identity.id < $1.0.identity.id
        }
        guard let selected = ranked.first?.0 else { throw AccountDispatchError.unavailable }
        let admission = command.selecting(selected)
        // Common Key/global/principal rejection propagates once; it is not an account failure.
        try Self.admitTransaction(db, admission, limits: limits)
        return admission
      }
    }
  }
  private static func accountAffinity(
    _ db: SQLiteConnection, principal: String, references: [ObjectBinding],
    connection: AccountRouteIdentity?
  ) throws -> AccountRouteIdentity? {
    var matching: Set<AccountRouteIdentity>? = connection.map { [$0] }
    for reference in references {
      var sql = """
        SELECT DISTINCT b.identity,b.namespace FROM bindings b
        JOIN accounts a ON a.id=b.identity AND a.namespace=b.namespace
        WHERE b.principal=? AND b.object_type=? AND b.raw_id=?
        """
      var values: [SQLiteConnection.Value] = [
        .text(principal), .text(reference.type), .text(reference.rawID),
      ]
      if let connection {
        sql += " AND b.identity=? AND b.namespace=?"
        values += [.text(connection.id), .text(connection.namespace)]
      }
      sql += " LIMIT 65"
      let rows = try db.rows(sql, values) { statement in
        try AccountRouteIdentity(
          id: String(cString: sqlite3_column_text(statement, 0)),
          namespace: String(cString: sqlite3_column_text(statement, 1)))
      }
      guard !rows.isEmpty else { throw ExecutionError.unknownObject }
      guard rows.count <= 64 else { throw ExecutionError.ambiguousObject }
      let found = Set(rows)
      matching = matching.map { $0.intersection(found) } ?? found
      guard matching?.isEmpty == false else { throw ExecutionError.unknownObject }
    }
    guard let matching else { return nil }
    guard matching.count == 1 else { throw ExecutionError.ambiguousObject }
    return matching.first
  }
  private static func validateAccountReferences(principal: String, references: [ObjectBinding])
    throws
  {
    guard !principal.isEmpty, principal.utf8.count <= 256, !principal.utf8.contains(0),
      references.count <= 32,
      references.allSatisfy({ reference in
        [reference.type, reference.rawID].allSatisfy {
          !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
        }
      })
    else { throw ExecutionError.invalidCommand }
  }
  /// Stable non-security tie breaking; never Swift's process-randomized hashValue.
  private static func routeTie(_ seed: String, _ identity: AccountRouteIdentity) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in (seed + "\0" + identity.namespace + "\0" + identity.id).utf8 {
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return hash
  }
}
