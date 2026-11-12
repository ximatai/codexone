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
        try Self.replaceHealthModels(db, models)
      }
    }
  }
  static func replaceHealthModels(_ db: SQLiteConnection, _ models: Set<String>) throws {
    let existing = try db.rows("SELECT model FROM health_models") {
      String(cString: sqlite3_column_text($0, 0))
    }
    for model in existing where !models.contains(model) {
      try db.write("DELETE FROM health_models WHERE model=?", [.text(model)])
      for id in Array(db.overloadPacing.keys) { db.overloadPacing[id]?[model] = nil }
    }
    for model in models {
      try db.write("INSERT OR IGNORE INTO health_models VALUES(?)", [.text(model)])
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
        && models.contains { model in
          guard let cooldown = health.cooldowns.first(where: { $0.model == model }) else {
            return true
          }
          return cooldown.failure == .upstreamUnavailable
            && Self.pacingRemaining(db, account: account.id, cooldown: cooldown)
              <= OverloadPacing.maximumWaitSeconds
        }
    }
  }
  static func pacingRemaining(
    _ db: SQLiteConnection, account: String, cooldown: AccountModelCooldown
  ) -> Double {
    let now = Double(db.clock.unixMicroseconds) / 1_000_000
    let until = Double(cooldown.untilUnixSeconds)
    // After restart the origin of a persisted cooldown is unknown: honor its full duration.
    return db.overloadPacing[account]?[cooldown.model]?.remaining(
      now: now, persistedUntil: cooldown.untilUnixSeconds)
      ?? max(0, until - now)
  }
  static func checkAccountHealth(
    _ db: SQLiteConnection, account: ManagedAccount, model: String
  ) throws {
    let health = try loadHealth(db, account: account)
    guard !health.authenticationRejected else { throw ExecutionError.denied }
    guard let cooldown = health.cooldowns.first(where: { $0.model == model }) else { return }
    guard cooldown.failure == .upstreamUnavailable else { throw ExecutionError.denied }
    let remaining = pacingRemaining(db, account: account.id, cooldown: cooldown)
    try OverloadPacing.requiresWait(seconds: remaining)
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
      [.text(account.id), .number(db.clock.unixSeconds)]
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
    guard let captured = snapshot.admission.accountSnapshot else { return }
    let id = snapshot.admission.owner.identity
    let current = try Self.loadAccount(db, id).account
    guard current.namespace == snapshot.admission.owner.namespace,
      current.credentialVersion == captured.credentialVersion
    else { return }
    if outcome.kind == .succeeded, let model = snapshot.admission.model {
      db.overloadPacing[current.id]?[model] = nil
      try db.write(
        "DELETE FROM account_model_health WHERE account_id=? AND model=? AND failure=?",
        [.text(current.id), .text(model), .text(ExecutionFailure.upstreamUnavailable.rawValue)])
    }
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
    var until =
      outcome.atUnixSeconds + (outcome.cooldownSeconds ?? (failure == .rateLimited ? 30 : 15))
    if failure == .upstreamUnavailable {
      var pacing: OverloadPacing
      if let previous = db.overloadPacing[id]?[model] {
        pacing = previous
      } else {
        let previousUntil = try db.scalar(
          "SELECT COALESCE(MAX(until_epoch),0) FROM account_model_health WHERE account_id=? AND model=? AND failure=?",
          [.text(id), .text(model), .text(ExecutionFailure.upstreamUnavailable.rawValue)])
        pacing = OverloadPacing(persistedUntil: previousUntil)
      }
      pacing.record(
        now: Double(db.clock.unixMicroseconds) / 1_000_000, at: outcome.atUnixSeconds,
        retryAfter: outcome.cooldownSeconds)
      until = pacing.persistedUntil
      db.overloadPacing[id, default: [:]][model] = pacing
    }
    try db.write(
      """
      INSERT INTO account_model_health VALUES(?,?,?,?) ON CONFLICT(account_id,model) DO UPDATE SET
        failure=CASE WHEN excluded.until_epoch>=until_epoch THEN excluded.failure ELSE failure END,
        until_epoch=MAX(until_epoch,excluded.until_epoch)
      """, [.text(id), .text(model), .number(until), .text(failure.rawValue)])
  }
}
