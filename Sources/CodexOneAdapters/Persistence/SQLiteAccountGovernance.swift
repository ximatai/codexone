import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: AccountGovernanceStore {
  static func checkAccountAdmission(_ db: SQLiteConnection, _ command: ExecutionAdmission) throws {
    guard let snapshot = command.accountSnapshot else {
      // Matching managed identities cannot fall back to the legacy admission contract.
      guard
        try db.scalar(
          "SELECT COUNT(*) FROM accounts WHERE id=? AND namespace=?",
          [
            .text(command.owner.identity), .text(command.owner.namespace),
          ]) == 0
      else { throw ExecutionError.invalidCommand }
      return
    }
    guard let model = command.model, !model.isEmpty else { throw ExecutionError.invalidCommand }
    let account = try loadAccount(db, command.owner.identity).account
    guard account.namespace == command.owner.namespace,
      account.revision == snapshot.revision,
      account.credentialVersion == snapshot.credentialVersion
    else { throw ExecutionError.conflict }
    guard account.authorization == .ready,
      account.mode == .enabled || (account.mode == .draining && snapshot.continuation),
      snapshot.accessExpiresAtUnixSeconds > Int64(Date().timeIntervalSince1970)
    else { throw ExecutionError.denied }
    try Self.checkAccountHealth(db, account: account, model: model)
  }
  public func createVerifiedAccount(id: String, namespace: String, envelope: String) async throws
    -> ManagedAccount
  {
    try Self.validateAccountID(id)
    try Self.validateAccountEnvelope(envelope)
    _ = try AccountCredentialContext(identity: id, namespace: namespace, version: 1)
    return try await perform(optional: true) { db in
      try db.transaction {
        try Self.checkAccountCapacity(db)
        guard try db.scalar("SELECT COUNT(*) FROM accounts") < 64 else {
          throw ExecutionError.capacity
        }
        guard
          try db.scalar(
            "SELECT COUNT(*) FROM accounts WHERE id=? OR namespace=?",
            [.text(id), .text(namespace)]) == 0
        else { throw ExecutionError.conflict }
        let account = try ManagedAccount(
          id: id, namespace: namespace, revision: 1, credentialVersion: 1,
          mode: .disabled, authorization: .ready, refreshIntent: nil,
          createdAtUnixSeconds: Int64(Date().timeIntervalSince1970))
        try db.write(
          "INSERT INTO accounts VALUES(?,?,?,?,?,?,?,NULLIF(?,''),?,?)",
          Self.accountValues(account, envelope: envelope))
        try Self.auditAccount(db, account, action: "create_verified")
        return account
      }
    }
  }
  public func accountCredential(id: String) async throws -> StoredAccountCredential {
    try Self.validateAccountID(id)
    return try await perform { try Self.loadAccount($0, id) }
  }
  public func listAccounts(after: String? = nil) async throws -> [ManagedAccount] {
    if let after { try Self.validateAccountID(after) }
    return try await perform { db in
      try db.rows("SELECT * FROM accounts WHERE id>? ORDER BY id LIMIT 64", [.text(after ?? "")]) {
        try Self.decodeAccount($0).account
      }
    }
  }
  public func setAccountDisplayName(id: String, revision: Int64, displayName: String?) async throws
    -> ManagedAccount
  {
    try Self.validateAccountID(id)
    try ManagedAccount.validateDisplayName(displayName)
    guard (1...1_000_000).contains(revision) else { throw ExecutionError.invalidCommand }
    return try await perform(optional: true) { db in
      try db.transaction {
        let stored = try Self.loadAccount(db, id)
        let old = stored.account
        guard old.revision == revision else { throw ExecutionError.conflict }
        let next = try Self.nextAccount(old)
        try Self.checkAccountCapacity(db)
        let account = try ManagedAccount(
          id: old.id, namespace: old.namespace, revision: next.revision,
          credentialVersion: old.credentialVersion, mode: old.mode,
          authorization: old.authorization,
          refreshIntent: old.refreshIntent, createdAtUnixSeconds: old.createdAtUnixSeconds,
          displayName: displayName)
        try Self.saveAccount(db, account, envelope: stored.envelope)
        try Self.auditAccount(db, account, action: "display_name")
        return account
      }
    }
  }
  public func setAccountMode(id: String, revision: Int64, mode: AccountMode) async throws
    -> ManagedAccount
  {
    try Self.validateAccountID(id)
    return try await perform(optional: mode == .enabled, essential: mode != .enabled) {
      [storage] db in
      try db.transaction {
        let stored = try Self.loadAccount(db, id)
        let old = stored.account
        guard old.revision == revision else { throw ExecutionError.conflict }
        let restricting =
          (old.mode == .enabled && mode != .enabled) || (old.mode == .draining && mode == .disabled)
        guard storage.snapshot.optionalWorkAllowed || restricting else {
          throw ExecutionError.storagePressure
        }
        try Self.checkAccountCapacity(db, disabling: old.mode != .disabled && mode == .disabled)
        let account = try Self.nextAccount(old, mode: mode)
        try Self.saveAccount(db, account, envelope: stored.envelope)
        try Self.auditAccount(db, account, action: "mode")
        return account
      }
    }
  }
  public func beginAccountRefresh(id: String, revision: Int64, intent: String) async throws
    -> StoredAccountCredential
  {
    try Self.validateAccountID(id)
    try Self.validateAccountID(intent)
    return try await perform(admission: true) { db in
      try db.transaction {
        let stored = try Self.loadAccount(db, id)
        let old = stored.account
        guard old.revision == revision, old.authorization == .ready,
          old.credentialVersion < 1_000_000,
          old.revision < 999_999
        else { throw ExecutionError.conflict }
        try Self.checkAccountCapacity(db, startingRefresh: true)
        let account = try Self.nextAccount(old, authorization: .refreshing, intent: intent)
        try Self.saveAccount(db, account, envelope: stored.envelope)
        try Self.auditAccount(db, account, action: "refresh_begin")
        return StoredAccountCredential(account: account, envelope: stored.envelope)
      }
    }
  }
  public func finishAccountRefresh(
    id: String, credentialVersion: Int64, intent: String, envelope: String
  ) async throws -> ManagedAccount {
    try Self.validateAccountID(id)
    try Self.validateAccountID(intent)
    try Self.validateAccountEnvelope(envelope)
    return try await perform(critical: true) { db in
      try db.transaction {
        let old = try Self.loadAccount(db, id).account
        try Self.matchRefresh(old, version: credentialVersion, intent: intent)
        let account = try Self.nextAccount(
          old, authorization: .ready, intent: nil, credentialVersion: credentialVersion + 1)
        try Self.saveAccount(db, account, envelope: envelope)
        try Self.auditAccount(db, account, action: "refresh_commit")
        return account
      }
    }
  }
  public func failAccountRefresh(
    id: String, credentialVersion: Int64, intent: String, authorizationRequired: Bool = false
  ) async throws
    -> ManagedAccount
  {
    try Self.validateAccountID(id)
    try Self.validateAccountID(intent)
    return try await perform(critical: true) { db in
      try db.transaction {
        let stored = try Self.loadAccount(db, id)
        let old = stored.account
        try Self.matchRefresh(old, version: credentialVersion, intent: intent)
        let account = try Self.nextAccount(
          old, authorization: authorizationRequired ? .requiresAuth : .authUncertain, intent: intent
        )
        try Self.saveAccount(db, account, envelope: stored.envelope)
        try Self.auditAccount(
          db, account, action: authorizationRequired ? "refresh_requires_auth" : "refresh_uncertain"
        )
        return account
      }
    }
  }
  public func replaceVerifiedAccountCredential(
    id: String, revision: Int64, namespace: String, envelope: String
  ) async throws -> ManagedAccount {
    try Self.validateAccountID(id)
    try Self.validateAccountEnvelope(envelope)
    return try await perform(optional: true) { db in
      try db.transaction {
        let old = try Self.loadAccount(db, id).account
        guard old.revision == revision, old.namespace == namespace,
          old.authorization != .refreshing,
          old.credentialVersion < 1_000_000
        else { throw ExecutionError.conflict }
        try Self.checkAccountCapacity(db)
        let account = try Self.nextAccount(
          old, authorization: .ready, intent: nil, credentialVersion: old.credentialVersion + 1)
        try Self.saveAccount(db, account, envelope: envelope)
        try Self.auditAccount(db, account, action: "reauthorize_verified")
        return account
      }
    }
  }
  static func recoverAccountRefreshes(_ db: SQLiteConnection) throws {
    let interrupted = try db.rows(
      "SELECT * FROM accounts WHERE authorization='refreshing'", map: Self.decodeAccount)
    guard interrupted.count <= 64 else { throw ExecutionError.storageUnavailable }
    for stored in interrupted {
      let account = try nextAccount(
        stored.account, authorization: .authUncertain, intent: stored.account.refreshIntent)
      try saveAccount(db, account, envelope: stored.envelope)
      try auditAccount(db, account, action: "refresh_restart_uncertain")
    }
  }
  private static func matchRefresh(_ account: ManagedAccount, version: Int64, intent: String) throws
  {
    guard account.authorization == .refreshing, account.credentialVersion == version,
      account.refreshIntent == intent
    else { throw ExecutionError.conflict }
  }
  private static func nextAccount(
    _ old: ManagedAccount, mode: AccountMode? = nil, authorization: AccountAuthorization? = nil,
    intent: String? = nil, credentialVersion: Int64? = nil
  ) throws -> ManagedAccount {
    let auth = authorization ?? old.authorization
    let pending = authorization == nil ? old.refreshIntent : intent
    guard old.revision < (auth == .refreshing ? 999_999 : 1_000_000) else {
      throw ExecutionError.conflict
    }
    return try ManagedAccount(
      id: old.id, namespace: old.namespace, revision: old.revision + 1,
      credentialVersion: credentialVersion ?? old.credentialVersion, mode: mode ?? old.mode,
      authorization: auth, refreshIntent: pending, createdAtUnixSeconds: old.createdAtUnixSeconds,
      displayName: old.displayName)
  }
  private static func validateAccountID(_ value: String) throws {
    guard ManagedAccount.validID(value) else { throw ExecutionError.invalidCommand }
  }
  private static func validateAccountEnvelope(_ value: String) throws {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard value.utf8.count <= 49_152, parts.count == 3, parts[0] == "v1", parts[1].count == 32,
      parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let bytes = Data(base64Encoded: String(parts[2])), bytes.count >= 28,
      bytes.base64EncodedString() == parts[2]
    else { throw ExecutionError.invalidCommand }
  }
  static func loadAccount(_ db: SQLiteConnection, _ id: String) throws
    -> StoredAccountCredential
  {
    guard
      let stored = try db.rows("SELECT * FROM accounts WHERE id=?", [.text(id)], map: decodeAccount)
        .first
    else { throw ExecutionError.unknownObject }
    return stored
  }
  private static func decodeAccount(_ row: OpaquePointer) throws -> StoredAccountCredential {
    func string(_ index: Int32) -> String { String(cString: sqlite3_column_text(row, index)) }
    guard let mode = AccountMode(rawValue: string(4)),
      let authorization = AccountAuthorization(rawValue: string(5))
    else { throw ExecutionError.storageUnavailable }
    let account = try ManagedAccount(
      id: string(0), namespace: string(1), revision: sqlite3_column_int64(row, 2),
      credentialVersion: sqlite3_column_int64(row, 3), mode: mode,
      authorization: authorization,
      refreshIntent: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : string(7),
      createdAtUnixSeconds: sqlite3_column_int64(row, 8),
      displayName: sqlite3_column_type(row, 9) == SQLITE_NULL ? nil : string(9))
    let envelope = string(6)
    try validateAccountEnvelope(envelope)
    return StoredAccountCredential(account: account, envelope: envelope)
  }
  private static func accountValues(_ account: ManagedAccount, envelope: String)
    -> [SQLiteConnection.Value]
  {
    [
      .text(account.id), .text(account.namespace), .number(account.revision),
      .number(account.credentialVersion), .text(account.mode.rawValue),
      .text(account.authorization.rawValue), .text(envelope), .text(account.refreshIntent ?? ""),
      .number(account.createdAtUnixSeconds), account.displayName.map { .text($0) } ?? .null,
    ]
  }
  private static func saveAccount(
    _ db: SQLiteConnection, _ account: ManagedAccount, envelope: String
  ) throws {
    let values = accountValues(account, envelope: envelope)
    try db.write(
      "UPDATE accounts SET namespace=?,revision=?,credential_version=?,mode=?,authorization=?,sealed_credential=?,refresh_intent=NULLIF(?,''),created_at_epoch=?,display_name=? WHERE id=?",
      Array(values.dropFirst()) + [values[0]])
  }
  private static func checkAccountCapacity(
    _ db: SQLiteConnection, disabling: Bool = false, startingRefresh: Bool = false
  ) throws {
    let events = try db.scalar("SELECT COUNT(*) FROM account_events")
    let pending = try db.scalar("SELECT COUNT(*) FROM accounts WHERE authorization='refreshing'")
    let needed: Int64 = startingRefresh ? 2 : 1
    guard events + pending + needed <= (disabling ? 4160 : 4096) else {
      throw ExecutionError.capacity
    }
  }
  private static func auditAccount(
    _ db: SQLiteConnection, _ account: ManagedAccount, action: String
  ) throws {
    guard try db.scalar("SELECT COUNT(*) FROM account_events") < 4160 else {
      throw ExecutionError.capacity
    }
    let data = try JSONEncoder().encode(account)
    try db.write(
      "INSERT INTO account_events VALUES(?,?,?,?,?,?)",
      [
        .text(UUID().uuidString), .text(account.id), .number(account.revision), .text(action),
        .text(String(decoding: data, as: UTF8.self)), .number(Int64(Date().timeIntervalSince1970)),
      ])
  }
}
