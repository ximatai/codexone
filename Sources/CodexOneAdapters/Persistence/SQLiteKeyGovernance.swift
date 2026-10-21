import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: KeyGovernanceStore {
  public func authenticateKey(digest: String) async throws -> ManagedKey {
    try Self.validateDigest(digest)
    return try await perform { db in
      let values = try db.rows(
        "SELECT metadata_json FROM managed_keys WHERE digest=?", [.text(digest)]
      ) {
        try Self.decodeKey($0)
      }
      guard let key = values.first, key.enabled else { throw ExecutionError.unauthorized }
      return key
    }
  }
  public func createKey(id: String, principal: String, digest: String, policy: KeyPolicy)
    async throws -> ManagedKey
  {
    try Self.validateKeyID(id)
    try Self.validateKeyID(principal)
    try Self.validateDigest(digest)
    try policy.validate()
    return try await perform { db in
      try db.transaction {
        try Self.checkKeyCapacity(db, creating: true)
        guard
          try db.scalar(
            "SELECT COUNT(*) FROM managed_keys WHERE id=? OR digest=?", [.text(id), .text(digest)])
            == 0
        else { throw ExecutionError.conflict }
        let key = ManagedKey(
          id: id, principal: principal, revision: 1, enabled: true, policy: policy,
          createdAtUnixSeconds: Int64(Date().timeIntervalSince1970))
        try db.write(
          "INSERT INTO managed_keys VALUES(?,?,?)",
          [.text(id), .text(digest), .text(try Self.encodeKey(key))])
        try Self.auditKey(db, key: key, action: "create")
        return key
      }
    }
  }
  public func updateKey(id: String, revision: Int64, enabled: Bool, policy: KeyPolicy) async throws
    -> ManagedKey
  {
    try Self.validateKeyID(id)
    try policy.validate()
    return try await perform { db in
      try db.transaction {
        let old = try Self.loadKey(db, id)
        guard old.revision == revision, revision < 1_000_000 else { throw ExecutionError.conflict }
        let revoking = old.enabled && !enabled
        try Self.checkKeyCapacity(db, revocation: revoking)
        let key = ManagedKey(
          id: old.id, principal: old.principal, revision: revision + 1, enabled: enabled,
          policy: policy, createdAtUnixSeconds: old.createdAtUnixSeconds)
        try db.write(
          "UPDATE managed_keys SET metadata_json=? WHERE id=?",
          [.text(try Self.encodeKey(key)), .text(id)])
        try Self.auditKey(db, key: key, action: revoking ? "disable" : "update")
        return key
      }
    }
  }
  public func rotateKey(id: String, revision: Int64, digest: String) async throws -> ManagedKey {
    try Self.validateKeyID(id)
    try Self.validateDigest(digest)
    return try await perform { db in
      try db.transaction {
        try Self.checkKeyCapacity(db)
        let old = try Self.loadKey(db, id)
        guard old.revision == revision, revision < 1_000_000,
          try db.scalar("SELECT COUNT(*) FROM managed_keys WHERE digest=?", [.text(digest)]) == 0
        else { throw ExecutionError.conflict }
        let key = ManagedKey(
          id: old.id, principal: old.principal, revision: revision + 1,
          enabled: old.enabled, policy: old.policy, createdAtUnixSeconds: old.createdAtUnixSeconds)
        try db.write(
          "UPDATE managed_keys SET digest=?,metadata_json=? WHERE id=?",
          [.text(digest), .text(try Self.encodeKey(key)), .text(id)])
        try Self.auditKey(db, key: key, action: "rotate")
        return key
      }
    }
  }
  public func listKeys(after: String? = nil) async throws -> [ManagedKey] {
    if let after { try Self.validateKeyID(after) }
    return try await perform { db in
      try db.rows(
        "SELECT metadata_json FROM managed_keys WHERE id>? ORDER BY id LIMIT 64",
        [.text(after ?? "")]
      ) {
        try Self.decodeKey($0)
      }
    }
  }
  static func checkKeyAdmission(_ db: SQLiteConnection, _ command: ExecutionAdmission) throws {
    guard let revision = command.keyRevision else { return }
    let key = try loadKey(db, command.owner.key)
    guard key.enabled, key.revision == revision, key.principal == command.owner.principal else {
      throw ExecutionError.unauthorized
    }
    guard let model = command.model, key.policy.models.contains(model) else {
      throw ExecutionError.unauthorized
    }
    let limits = key.policy.limits
    let values: [SQLiteConnection.Value] = [.text(command.owner.key)]
    let counts = try db.rows(
      """
      SELECT COALESCE(SUM(CASE WHEN state='intent' THEN 1 ELSE 0 END),0),
      COALESCE(SUM(CASE WHEN state!='settled' THEN 1 ELSE 0 END),0),
      COALESCE(SUM(CASE WHEN state!='settled' THEN MAX(reserved,estimated) ELSE 0 END),0)
      FROM attempts WHERE key_id=?
      """, values
    ) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2)) }[0]
    let window = values + [.text(command.window)]
    let requests = try db.scalar(
      "SELECT COUNT(*) FROM attempts WHERE key_id=? AND window_id=?", window)
    let exposure = try db.scalar(
      "SELECT COALESCE(SUM(estimated + CASE WHEN state!='settled' THEN MAX(reserved-estimated,0) ELSE 0 END),0) FROM attempts WHERE key_id=? AND window_id=?",
      window)
    guard counts.0 < limits.active, counts.1 < limits.unresolved, requests < limits.requests,
      command.reservedMicros <= limits.unresolvedMicros,
      counts.2 <= limits.unresolvedMicros - command.reservedMicros,
      command.reservedMicros <= limits.budgetMicros,
      exposure <= limits.budgetMicros - command.reservedMicros
    else { throw ExecutionError.denied }
  }
  private static func loadKey(_ db: SQLiteConnection, _ id: String) throws -> ManagedKey {
    guard
      let key = try db.rows(
        "SELECT metadata_json FROM managed_keys WHERE id=?", [.text(id)], map: { try decodeKey($0) }
      ).first
    else {
      throw ExecutionError.unauthorized
    }
    return key
  }
  private static func decodeKey(_ statement: OpaquePointer) throws -> ManagedKey {
    do {
      let key = try JSONDecoder().decode(
        ManagedKey.self, from: Data(String(cString: sqlite3_column_text(statement, 0)).utf8))
      try validateKeyID(key.id)
      try validateKeyID(key.principal)
      try key.policy.validate()
      guard (1...1_000_000).contains(key.revision), key.createdAtUnixSeconds >= 0 else {
        throw ExecutionError.storageUnavailable
      }
      return key
    } catch { throw ExecutionError.storageUnavailable }
  }
  private static func encodeKey(_ key: ManagedKey) throws -> String {
    String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
  }
  private static func checkKeyCapacity(
    _ db: SQLiteConnection, creating: Bool = false, revocation: Bool = false
  ) throws {
    let limit: Int64 = revocation ? 4352 : 4096
    guard try db.scalar("SELECT COUNT(*) FROM key_events") < limit else {
      throw ExecutionError.capacity
    }
    if creating, try db.scalar("SELECT COUNT(*) FROM managed_keys") >= 256 {
      throw ExecutionError.capacity
    }
  }
  private static func auditKey(_ db: SQLiteConnection, key: ManagedKey, action: String) throws {
    try db.write(
      "INSERT INTO key_events VALUES(?,?,?,?,?,?)",
      [
        .text(UUID().uuidString), .text(key.id), .number(key.revision), .text(action),
        .number(Int64(Date().timeIntervalSince1970)), .text(try encodeKey(key)),
      ])
  }
  private static func validateKeyID(_ id: String) throws {
    guard (1...64).contains(id.utf8.count),
      id.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      })
    else { throw ExecutionError.invalidCommand }
  }
  private static func validateDigest(_ value: String) throws {
    guard value.utf8.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else {
      throw ExecutionError.invalidCommand
    }
  }
}
