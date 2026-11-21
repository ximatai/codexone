import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func runRust(_ phase: String, path: String, keyring: URL? = nil) throws {
  let runner = try #require(ProcessInfo.processInfo.environment["CODEXONE_STORAGE_RUST_TEST"])
  let process = Process()
  process.executableURL = URL(fileURLWithPath: runner)
  process.arguments = ["--ignored", "--exact", "swift_database"]
  var environment = ProcessInfo.processInfo.environment
  environment["CODEXONE_STORAGE_DB"] = path
  environment["CODEXONE_STORAGE_KEYRING"] = keyring?.path
  environment["CODEXONE_STORAGE_PHASE"] = phase
  process.environment = environment
  try process.run()
  process.waitUntilExit()
  try #require(process.terminationReason == .exit && process.terminationStatus == 0)
}

@Test func swiftRustStorageInteroperability() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("storage.sqlite").path
  let keyring = directory.appendingPathComponent("master")
  let oldHex = String(repeating: "a1", count: 32)
  let activeHex = String(repeating: "B2", count: 32)
  let keyringJSON = """
    {"format":1.0,"active":"\(activeHex)","decryptOnly":["\(oldHex)"]}
    """
  try Data(keyringJSON.utf8).write(to: keyring)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyring.path)
  let old = try AccountCredentialCipher(hexKey: oldHex)
  let active = try await AccountCredentialCipher.load(path: keyring.path)
  let limits = ExecutionLimits(
    requests: 20, active: 3, unresolved: 4, budgetMicros: 100, unresolvedMicros: 10)
  let store = try await SQLiteExecutionStore.open(path: path, limits: limits)
  let policy = try KeyPolicy(models: ["synthetic-text"], limits: limits)
  let id = "synthetic-account"
  let namespace = #"https://example.test/subscription/a\"b"#
  let context = try AccountCredentialContext(identity: id, namespace: namespace, version: 1)
  let credential = try AccountCredential(
    accessToken: "swift/access+1=", refreshToken: "swift.refresh~1", idToken: "swift_id-1",
    expiresAtUnixSeconds: 2_000_000_000)
  _ = try await store.createVerifiedAccount(
    id: id, namespace: namespace, envelope: old.seal(credential, context: context))
  _ = try await store.createKey(
    id: "synthetic-key", principal: "synthetic-principal",
    digest: bearerDigest(["Bearer co1_synthetic-swift-managed-key"]), policy: policy)

  try runRust("locked", path: path)
  await store.close()
  try runRust("rewrite", path: path, keyring: keyring)

  let reopened = try await SQLiteExecutionStore.open(path: path, limits: limits)
  let stored = try await reopened.accountCredential(id: id)
  #expect(stored.account.namespace == namespace)
  #expect(stored.account.credentialVersion == 1)
  let decoded = try active.open(stored.envelope, context: context)
  #expect(decoded.accessToken == "rust/access+2=")
  #expect(decoded.refreshToken == "rust.refresh~2")
  #expect(decoded.idToken == nil)
  #expect(decoded.expiresAtUnixSeconds == 2_000_000_001)
  #expect(throws: ExecutionError.invalidCommand) {
    try old.open(stored.envelope, context: context)
  }
  let key = try await reopened.authenticateKey(
    digest: bearerDigest(["Bearer co1_synthetic-rust-managed-key"]))
  #expect(key.id == "synthetic-key")
  await #expect(throws: ExecutionError.unauthorized) {
    try await reopened.authenticateKey(
      digest: bearerDigest(["Bearer co1_synthetic-swift-managed-key"]))
  }
  await reopened.close()
}

@Test(arguments: [0, 9, 18])
func swiftRustStorageInteroperabilitySchema(_ version: Int) async throws {
  let rustPath = try temporaryExecutionPath()
  let directory = URL(fileURLWithPath: rustPath).deletingLastPathComponent()
  defer { try? FileManager.default.removeItem(at: directory) }
  let swiftPath = directory.appendingPathComponent("swift.sqlite").path
  let manager = FileManager.default
  let automatic = version != 9

  if version == 9 {
    // The pre-governance layout, built using the baseline Swift DDL.
    try rawSQL(
      swiftPath,
      [SQLiteConnection.schema, SQLiteConnection.keySchema, SQLiteConnection.accountSchema,
        SQLiteConnection.observationSchema, SQLiteConnection.maintenanceSchema, """
        ALTER TABLE accounts ADD COLUMN display_name TEXT;
        CREATE INDEX attempts_in_flight ON attempts(created_at_epoch DESC,id DESC) WHERE state='intent';
        INSERT INTO attempts(id, principal, key_id, namespace, identity, window_id, policy_version,
          pricing_version, reserved, state, admission_json, created_at_epoch, outcome_json)
        VALUES('synthetic', 'p', 'k', 'n', 'i', 'w', 'policy', 'pricing', 1, 'unknown', '{}', 10,
          '{"atUnixSeconds":200}');
        PRAGMA user_version=9;
        """].joined(separator: "\n"))
  } else if version == 18 {
    try SQLiteConnection(path: swiftPath).shutdown()
    try rawSQL(
      swiftPath, """
      ALTER TABLE request_diagnostics DROP COLUMN reasoning_effort;
      INSERT INTO request_diagnostics(request_id,at_epoch,key_id,mode,failure,reason)
      VALUES('synthetic',200,'k','generation','invalid_request','reasoning_effort_not_allowed');
      PRAGMA user_version=18;
      """)
  }
  if version != 0 {
    try manager.copyItem(atPath: swiftPath, toPath: rustPath)
  }
  try runRust(automatic ? "startup" : "migrate", path: rustPath)
  if !automatic { try await SQLiteExecutionStore.migrate(path: swiftPath) }

  let rust = try SQLiteConnection(path: rustPath, existingOnly: true)
  defer { rust.shutdown() }
  let swift = try SQLiteConnection(path: swiftPath, allowStartupMigration: automatic)
  defer { swift.shutdown() }
  func schema(_ db: SQLiteConnection) throws -> [String] {
    try db.rows(
      "SELECT type || ':' || name || ':' || sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name"
    ) { String(cString: sqlite3_column_text($0, 0)).filter { !$0.isWhitespace } }
  }
  #expect(try schema(rust) == schema(swift))
  #expect(try rust.scalar("SELECT count(*) FROM maintenance_state WHERE length(generation)=32") == 1)
  if version == 0 {
    rust.shutdown()
    let store = try await SQLiteExecutionStore.open(path: rustPath, limits: syntheticLimits)
    try await store.admit(admission("swift-on-rust-created-database"))
    await store.close()
    return
  }
  if version == 9 {
    let migrated = "SELECT unknown_since_epoch FROM attempts WHERE id='synthetic'"
    #expect(try rust.scalar(migrated) == 200)
    #expect(try swift.scalar(migrated) == 200)
  } else {
    let migrated = """
      SELECT count(*) FROM request_diagnostics WHERE request_id='synthetic'
      AND reason='reasoning_effort_not_allowed' AND reasoning_effort IS NULL
      """
    #expect(try rust.scalar(migrated) == 1)
    #expect(try swift.scalar(migrated) == 1)
  }
  let prefix = URL(fileURLWithPath: rustPath).lastPathComponent + ".pre-v\(max(13, version + 1))-"
  let backups = try manager.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasPrefix(prefix) }
  let name = try #require(backups.first)
  #expect(backups.count == 1 && name.hasSuffix(".sqlite"))
  let backup = try SQLiteConnection(readOnlyPath: directory.appendingPathComponent(name).path)
  defer { backup.shutdown() }
  #expect(try backup.scalar("PRAGMA user_version") == version)
  #expect(try backup.scalar("SELECT count(*) FROM \(version == 9 ? "attempts" : "request_diagnostics")") == 1)
}
