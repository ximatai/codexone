import CSQLite
import CodexOneCore
import Crypto
import Foundation

extension SQLiteExecutionStore: AccountResetCreditStore {
  public func resetCreditState(id: String) async throws -> ResetCreditState {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    return try await perform { db in
      let account = try Self.loadAccount(db, id).account
      var state = try Self.loadResetCreditState(db, id)
      state.revision = account.revision
      return state
    }
  }
  public func setResetCreditSettings(id: String, revision: Int64, settings: ResetCreditSettings)
    async throws -> ResetCreditState
  {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    _ = try ResetCreditSettings(
      autoUseBeforeExpiry: settings.autoUseBeforeExpiry, leadMinutes: settings.leadMinutes,
      retryCount: settings.retryCount)
    return try await perform(
      optional: settings.autoUseBeforeExpiry, essential: !settings.autoUseBeforeExpiry
    ) { db in
      try db.transaction {
        let stored = try Self.loadAccount(db, id)
        guard stored.account.revision == revision else { throw ExecutionError.conflict }
        try Self.checkAccountCapacity(db)
        let next = try Self.nextAccount(stored.account)
        try Self.saveAccount(db, next, envelope: stored.envelope)
        try Self.auditAccount(db, next, action: "reset_credit_settings")
        var state = try Self.loadResetCreditState(db, id)
        state.revision = next.revision
        state.settings = settings
        try Self.saveResetCreditState(db, id, state)
        return state
      }
    }
  }
  public func beginResetCreditAttempt(account: ManagedAccount, creditID: String?, automatic: Bool)
    async throws -> ResetCreditAttempt
  {
    guard creditID.map({ ResetCredit.validIdentifier($0) }) ?? true else {
      throw ExecutionError.invalidCommand
    }
    return try await perform(admission: true, optional: true) { db in
      try db.transaction {
        let current = try Self.loadAccount(db, account.id).account
        guard current.namespace == account.namespace,
          current.credentialVersion == account.credentialVersion,
          current.revision == account.revision, current.authorization == .ready
        else { throw ExecutionError.conflict }
        var state = try Self.loadResetCreditState(db, account.id)
        if automatic {
          guard current.mode == .enabled, state.intent != nil || state.settings.autoUseBeforeExpiry
          else { throw ExecutionError.conflict }
        }
        let intent: ResetCreditIntent
        if let pending = state.intent {
          // A default reconciliation cannot change the stored provider choice.
          guard creditID == nil || creditID == pending.creditID else {
            throw ExecutionError.conflict
          }
          intent = pending
        } else {
          intent = .init(requestID: UUID().uuidString, creditID: creditID, automatic: automatic)
        }
        try Self.checkResetCreditAuditCapacity(db)
        let attempt = ResetCreditAttempt(
          intent: intent, auditID: UUID().uuidString,
          creditHash: intent.creditID.map(Self.resetCreditHash))
        try Self.resetCreditAudit(
          db, id: account.id, auditID: attempt.auditID, action: "consume", code: "unknown",
          automatic: automatic, creditID: intent.creditID)
        state.intent = intent
        state.lastCode = .unknown
        state.lastAttemptAt = db.clock.unixSeconds
        try Self.saveResetCreditState(db, account.id, state)
        return attempt
      }
    }
  }
  public func finishResetCreditAttempt(
    id: String, attempt: ResetCreditAttempt, result: ResetCreditResult
  ) async throws {
    try await perform(critical: true) { db in
      try db.transaction {
        var state = try Self.loadResetCreditState(db, id)
        guard state.intent == attempt.intent,
          try db.scalar(
            "SELECT COUNT(*) FROM reset_credit_events WHERE id=? AND account_id=? AND code='unknown'",
            [.text(attempt.auditID), .text(id)]) == 1
        else { throw ExecutionError.conflict }
        state.lastCode = result.code
        state.failures = result.code == .unknown ? min(state.failures + 1, 1_000_000) : 0
        state.lastFailureAt = result.code == .unknown ? db.clock.unixSeconds : nil
        if result.code != .unknown { state.intent = nil }
        if attempt.intent.automatic && result.code == .reset {
          state.lastAutoResetAt = db.clock.unixSeconds
        }
        try Self.saveResetCreditState(db, id, state)
        try db.write(
          "UPDATE reset_credit_events SET code=? WHERE id=?",
          [.text(result.code.rawValue), .text(attempt.auditID)])
      }
    }
  }
  public func recordResetCreditPollFailure(id: String) async throws {
    try await perform(optional: true) { db in
      try db.transaction {
        _ = try Self.loadAccount(db, id)
        try Self.checkResetCreditAuditCapacity(db)
        try Self.resetCreditAudit(
          db, id: id, auditID: UUID().uuidString, action: "list", code: "unavailable",
          automatic: true, creditID: nil)
        var state = try Self.loadResetCreditState(db, id)
        state.failures = min(state.failures + 1, 1_000_000)
        state.lastFailureAt = db.clock.unixSeconds
        try Self.saveResetCreditState(db, id, state)
      }
    }
  }
  public func recordResetCreditPollSuccess(id: String) async throws {
    try await perform(optional: true) { db in
      try db.transaction {
        var state = try Self.loadResetCreditState(db, id)
        guard state.failures > 0, state.intent == nil else { return }
        state.failures = 0
        state.lastFailureAt = nil
        try Self.saveResetCreditState(db, id, state)
      }
    }
  }
  private static func checkResetCreditAuditCapacity(_ db: SQLiteConnection) throws {
    guard try db.scalar("SELECT COUNT(*) FROM reset_credit_events") < 4096 else {
      throw ExecutionError.capacity
    }
  }
  private static func resetCreditAudit(
    _ db: SQLiteConnection, id: String, auditID: String, action: String, code: String,
    automatic: Bool, creditID: String?
  ) throws {
    let hash = creditID.map(Self.resetCreditHash)
    try db.write(
      "INSERT INTO reset_credit_events VALUES(?,?,?,?,?,?,?)",
      [
        .text(auditID), .text(id), .text(action), .text(code), .number(automatic ? 1 : 0),
        hash.map { .text($0) } ?? .null, .number(db.clock.unixSeconds),
      ])
  }
  private static func resetCreditHash(_ id: String) -> String {
    SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func loadResetCreditState(_ db: SQLiteConnection, _ id: String) throws -> ResetCreditState
  {
    let records = try db.rows(
      "SELECT record_json FROM account_reset_credits WHERE account_id=?", [.text(id)]
    ) { String(cString: sqlite3_column_text($0, 0)) }
    guard let raw = records.first else { return try ResetCreditState() }
    let state = try decode(ResetCreditState.self, raw)
    _ = try ResetCreditSettings(
      autoUseBeforeExpiry: state.settings.autoUseBeforeExpiry,
      leadMinutes: state.settings.leadMinutes,
      retryCount: state.settings.retryCount)
    guard (0...1_000_000).contains(state.failures),
      state.intent.map({
        UUID(uuidString: $0.requestID) != nil
          && ($0.creditID.map { ResetCredit.validIdentifier($0) } ?? true)
      }) ?? true
    else { throw ExecutionError.storageUnavailable }
    return state
  }
  private static func saveResetCreditState(
    _ db: SQLiteConnection, _ id: String, _ state: ResetCreditState
  ) throws {
    try db.write(
      "INSERT INTO account_reset_credits VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET record_json=excluded.record_json",
      [.text(id), .text(try encode(state))])
  }
}
