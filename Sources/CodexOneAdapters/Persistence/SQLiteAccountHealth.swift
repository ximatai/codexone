import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: AccountHealthStore {
  public func configureHealthModels(_ models: Set<String>) async throws {
    guard models.count <= 48, models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
      throw ExecutionError.invalidCommand
    }
    try await perform(essential: true) { db in
      try db.transaction {
        let existing = try db.rows("SELECT model FROM health_models") {
          String(cString: sqlite3_column_text($0, 0))
        }
        for model in existing where !models.contains(model) {
          try db.write("DELETE FROM health_models WHERE model=?", [.text(model)])
        }
        for model in models {
          try db.write("INSERT OR IGNORE INTO health_models VALUES(?)", [.text(model)])
        }
      }
    }
  }
  public func accountHealth(id: String) async throws -> AccountHealth {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    return try await perform { db in
      let account = try Self.loadAccount(db, id).account
      return try Self.loadHealth(db, account: account)
    }
  }
  public func hasHealthyModel(id: String, credentialVersion: Int64, models: Set<String>)
    async throws -> Bool
  {
    guard models.count <= 48, models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
      throw ExecutionError.invalidCommand
    }
    return try await perform { db in
      let account = try Self.loadAccount(db, id).account
      guard account.credentialVersion == credentialVersion else { return false }
      let health = try Self.loadHealth(db, account: account)
      return !health.authenticationRejected
        && !models.subtracting(Set(health.cooldowns.map(\.model))).isEmpty
    }
  }
  static func checkAccountHealth(_ db: SQLiteConnection, account: ManagedAccount, model: String)
    throws
  {
    let blocked = try db.scalar(
      "SELECT COUNT(*) FROM account_health WHERE account_id=? AND auth_rejected_version=?",
      [.text(account.id), .number(account.credentialVersion)])
    guard blocked == 0,
      try db.scalar(
        "SELECT COUNT(*) FROM account_model_health WHERE account_id=? AND model=? AND until_epoch>?",
        [.text(account.id), .text(model), .number(Int64(Date().timeIntervalSince1970))]) == 0
    else { throw ExecutionError.denied }
  }
  static func loadHealth(_ db: SQLiteConnection, account: ManagedAccount) throws
    -> AccountHealth
  {
    let records = try db.rows(
      "SELECT auth_rejected_version,last_failure,at_epoch FROM account_health WHERE account_id=?",
      [.text(account.id)]
    ) {
      (
        sqlite3_column_int64($0, 0), String(cString: sqlite3_column_text($0, 1)),
        sqlite3_column_int64($0, 2)
      )
    }
    let cooldowns = try db.rows(
      "SELECT model,until_epoch,failure FROM account_model_health WHERE account_id=? AND until_epoch>? ORDER BY model LIMIT 49",
      [.text(account.id), .number(Int64(Date().timeIntervalSince1970))]
    ) { row -> AccountModelCooldown in
      guard let failure = ExecutionFailure(rawValue: String(cString: sqlite3_column_text(row, 2))),
        failure == .rateLimited || failure == .upstreamUnavailable
      else { throw ExecutionError.storageUnavailable }
      return .init(
        model: String(cString: sqlite3_column_text(row, 0)),
        untilUnixSeconds: sqlite3_column_int64(row, 1), failure: failure)
    }
    guard cooldowns.count <= 48 else { throw ExecutionError.storageUnavailable }
    if let row = records.first {
      guard let failure = ExecutionFailure(rawValue: row.1) else {
        throw ExecutionError.storageUnavailable
      }
      return .init(
        authenticationRejected: row.0 == account.credentialVersion,
        lastFailure: failure, lastFailureAtUnixSeconds: row.2, cooldowns: cooldowns)
    }
    return .init(
      authenticationRejected: false, lastFailure: nil, lastFailureAtUnixSeconds: nil,
      cooldowns: cooldowns)
  }
  static func recordOutcome(
    _ db: SQLiteConnection, snapshot: ExecutionSnapshot, outcome: ExecutionOutcome
  ) throws {
    let attempt = snapshot.admission.attempt
    let previous =
      try db.rows("SELECT outcome_json FROM attempts WHERE id=?", [.text(attempt)]) {
        row -> String? in
        sqlite3_column_type(row, 0) == SQLITE_NULL
          ? nil : String(cString: sqlite3_column_text(row, 0))
      }.first ?? nil
    if let previous {
      guard try decode(ExecutionOutcome.self, previous) == outcome else {
        throw ExecutionError.conflict
      }
      return
    }
    try db.write(
      "UPDATE attempts SET outcome_json=? WHERE id=?", [.text(try encode(outcome)), .text(attempt)])
    guard let failure = outcome.failure,
      [.authenticationRejected, .rateLimited, .upstreamUnavailable].contains(failure),
      let captured = snapshot.admission.accountSnapshot
    else { return }
    let id = snapshot.admission.owner.identity
    let current = try Self.loadAccount(db, id).account
    guard current.namespace == snapshot.admission.owner.namespace,
      current.credentialVersion == captured.credentialVersion
    else { return }
    try applyAccountFailure(db, account: current, model: snapshot.admission.model, outcome: outcome)
  }
  static func applyAccountFailure(
    _ db: SQLiteConnection, account current: ManagedAccount, model: String?,
    outcome: ExecutionOutcome
  ) throws {
    guard let failure = outcome.failure,
      [.authenticationRejected, .rateLimited, .upstreamUnavailable].contains(failure)
    else { return }
    let id = current.id
    try db.write(
      """
      INSERT INTO account_health VALUES(?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET
        auth_rejected_version=COALESCE(excluded.auth_rejected_version,auth_rejected_version),
        last_failure=CASE WHEN excluded.at_epoch>=at_epoch THEN excluded.last_failure ELSE last_failure END,
        at_epoch=MAX(at_epoch,excluded.at_epoch)
      """,
      [
        .text(id), failure == .authenticationRejected ? .number(current.credentialVersion) : .null,
        .text(failure.rawValue), .number(outcome.atUnixSeconds),
      ])
    guard failure != .authenticationRejected, let model,
      try db.scalar("SELECT COUNT(*) FROM health_models WHERE model=?", [.text(model)]) == 1
    else { return }
    let until =
      outcome.atUnixSeconds + (outcome.cooldownSeconds ?? (failure == .rateLimited ? 30 : 15))
    try db.write(
      """
      INSERT INTO account_model_health VALUES(?,?,?,?) ON CONFLICT(account_id,model) DO UPDATE SET
        failure=CASE WHEN excluded.until_epoch>=until_epoch THEN excluded.failure ELSE failure END,
        until_epoch=MAX(until_epoch,excluded.until_epoch)
      """, [.text(id), .text(model), .number(until), .text(failure.rawValue)])
  }
}
