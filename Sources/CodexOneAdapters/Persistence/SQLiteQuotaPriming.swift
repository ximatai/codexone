import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: QuotaPrimingStore {
  public func quotaPrimingState(id: String) async throws -> QuotaPrimingState {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    return try await perform { db in
      var state = try Self.loadQuotaPriming(db, id)
      state.revision = try Self.loadAccount(db, id).account.revision
      return state
    }
  }
  public func setQuotaPrimingSettings(id: String, revision: Int64, settings: QuotaPrimingSettings)
    async throws -> QuotaPrimingState
  {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    _ = try QuotaPrimingSettings(
      enabled: settings.enabled, model: settings.model, message: settings.message)
    return try await perform(optional: settings.enabled, essential: !settings.enabled) { db in
      try db.transaction {
        let account = try Self.loadAccount(db, id)
        guard account.account.revision == revision else { throw ExecutionError.conflict }
        try Self.checkAccountCapacity(db)
        let next = try Self.nextAccount(account.account)
        try Self.saveAccount(db, next, envelope: account.envelope)
        try Self.auditAccount(db, next, action: "quota_priming_settings")
        var state = try Self.loadQuotaPriming(db, id)
        state.settings = settings
        state.revision = next.revision
        state.failures = 0
        state.attention = nil
        try Self.saveQuotaPriming(db, id, state)
        return state
      }
    }
  }
  public func disableQuotaPriming(id: String, revision: Int64) async throws {
    try await perform(essential: true) { db in
      try db.transaction {
        let account = try Self.loadAccount(db, id)
        guard account.account.revision == revision else { throw ExecutionError.conflict }
        var state = try Self.loadQuotaPriming(db, id)
        guard state.settings.enabled else { return }
        try Self.checkAccountCapacity(db)
        let next = try Self.nextAccount(account.account)
        try Self.saveAccount(db, next, envelope: account.envelope)
        try Self.auditAccount(db, next, action: "quota_priming_model_removed")
        state.settings.enabled = false
        state.attention = "model_removed"
        try Self.saveQuotaPriming(db, id, state)
      }
    }
  }
  static func loadQuotaPriming(_ db: SQLiteConnection, _ id: String) throws -> QuotaPrimingState {
    let raw = try db.rows(
      "SELECT record_json FROM account_quota_priming WHERE account_id=?", [.text(id)]
    ) {
      String(cString: sqlite3_column_text($0, 0))
    }.first
    guard let raw else { return try .init() }
    let state = try decode(QuotaPrimingState.self, raw)
    _ = try QuotaPrimingSettings(
      enabled: state.settings.enabled, model: state.settings.model, message: state.settings.message)
    guard (0...1_000_000).contains(state.failures), state.windows.count <= 2,
      state.windows.keys.allSatisfy({ QuotaWindowKind(rawValue: $0) != nil })
    else { throw ExecutionError.storageUnavailable }
    return state
  }
  static func saveQuotaPriming(_ db: SQLiteConnection, _ id: String, _ state: QuotaPrimingState)
    throws
  {
    try db.write(
      "INSERT INTO account_quota_priming VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET record_json=excluded.record_json",
      [.text(id), .text(try encode(state))])
  }
  /// Called inside ordinary admission, after account health/capacity checks, before dispatch intent.
  static func admitQuotaPriming(_ db: SQLiteConnection, _ command: ExecutionAdmission) throws {
    guard command.owner.principal == QuotaPrimingIdentity.principal,
      command.owner.key == QuotaPrimingIdentity.principal, command.keyRevision == nil,
      command.accountSnapshot?.continuation == false, command.executionRequirements == .init(),
      command.references?.isEmpty != false, let model = command.model
    else { throw ExecutionError.denied }
    let id = command.owner.identity
    var state = try loadQuotaPriming(db, id)
    guard state.settings.model == nil || state.settings.model == model else {
      throw ExecutionError.denied
    }
    let raw = try db.rows("SELECT record_json FROM account_quota WHERE account_id=?", [.text(id)]) {
      String(cString: sqlite3_column_text($0, 0))
    }.first
    guard let raw else { throw ExecutionError.denied }
    let observation = try decode(AccountQuotaObservation.self, raw)
    let now = db.clock.unixSeconds
    state.observe(observation, now: now)
    let kinds = state.eligible(observation, now: now)
    guard !kinds.isEmpty else { throw ExecutionError.denied }
    guard try db.scalar("SELECT COUNT(*) FROM quota_priming_events") < 4096 else {
      throw ExecutionError.capacity
    }
    for kind in kinds {
      var saved = state.windows[kind.rawValue] ?? .init()
      saved.lastAttemptAt = now
      if case .idle(let reset) = QuotaIdleDetection.windows(observation, now: now)[kind] {
        saved.observedResetAt = reset
      }
      saved.awaitingActive = true
      state.windows[kind.rawValue] = saved
    }
    state.lastAttemptAt = now
    state.lastResult = "pending"
    try saveQuotaPriming(db, id, state)
    try db.write(
      "INSERT INTO quota_priming_events VALUES(?,?,?,?,?,?)",
      [
        .text(command.attempt), .text(id), .text(try encode(kinds)), .text(model), .text("pending"),
        .number(now),
      ])
  }
  static func finishQuotaPriming(
    _ db: SQLiteConnection, _ command: ExecutionAdmission, result: String
  ) throws {
    guard command.executionMode == .priming,
      try db.scalar(
        "SELECT COUNT(*) FROM quota_priming_events WHERE id=? AND result='pending'",
        [.text(command.attempt)]) == 1
    else { return }
    var state = try loadQuotaPriming(db, command.owner.identity)
    state.lastResult = result
    state.failures = result == "success" ? 0 : min(1_000_000, state.failures + 1)
    if state.failures >= 3 {
      if state.settings.enabled {
        let account = try loadAccount(db, command.owner.identity)
        if account.account.revision
          < (account.account.authorization == .refreshing ? 999_999 : 1_000_000)
        {
          let next = try nextAccount(account.account)
          try saveAccount(db, next, envelope: account.envelope)
        }
      }
      state.settings.enabled = false
      state.attention = "repeated_failure"
    }
    try saveQuotaPriming(db, command.owner.identity, state)
    try db.write(
      "UPDATE quota_priming_events SET result=? WHERE id=?",
      [.text(result), .text(command.attempt)])
  }
  static func recoverQuotaPriming(_ db: SQLiteConnection) throws {
    let commands = try db.rows(
      "SELECT a.admission_json FROM attempts a JOIN quota_priming_events e ON e.id=a.id WHERE e.result='pending' LIMIT 65"
    ) {
      try decode(ExecutionAdmission.self, String(cString: sqlite3_column_text($0, 0)))
    }
    guard commands.count <= 64 else { throw ExecutionError.storageUnavailable }
    for command in commands { try finishQuotaPriming(db, command, result: "unknown") }
  }
}
