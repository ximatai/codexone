import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func swiftRustStorageInteroperability() async throws {
  let runner = try #require(ProcessInfo.processInfo.environment["CODEXONE_STORAGE_RUST_TEST"])
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

  func runRust(_ phase: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: runner)
    process.arguments = ["--ignored", "--exact", "swift_database"]
    var environment = ProcessInfo.processInfo.environment
    environment["CODEXONE_STORAGE_DB"] = path
    environment["CODEXONE_STORAGE_KEYRING"] = keyring.path
    environment["CODEXONE_STORAGE_PHASE"] = phase
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationReason == .exit && process.terminationStatus == 0)
  }

  try runRust("locked")
  await store.close()
  try runRust("rewrite")

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
