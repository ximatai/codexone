import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func imageAndVisionPermissionsAreRecheckedAtomicallyWithoutGrantingEachOther() async throws {
  let path = try temporaryExecutionPath()
  let limits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 1000)
  let store = try await SQLiteExecutionStore.open(path: path, limits: limits)
  do {
    var key = try await store.createKey(
      id: "key", principal: "team", digest: String(repeating: "a", count: 64),
      policy: .init(models: ["synthetic-chat"], limits: limits, visionInput: true))
    func command(
      _ id: String, _ model: String, _ revision: Int64, _ requirements: ExecutionRequirements
    ) -> ExecutionAdmission {
      .init(
        attempt: id,
        owner: .init(principal: "team", key: "key", namespace: "synthetic", identity: "single"),
        window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 1,
        keyRevision: revision, model: model, requirements: requirements)
    }
    let vision = try ExecutionRequirements(route: .conversation, visionInput: true)
    let image = try ExecutionRequirements(route: .images, imageModel: "synthetic-image")
    try await store.admit(command("vision", "synthetic-chat", key.revision, vision))
    await #expect(throws: ExecutionError.unauthorized) {
      try await store.admit(command("denied-image", "synthetic-image", key.revision, image))
    }
    let oldRevision = key.revision
    key = try await store.updateKey(
      id: key.id, revision: key.revision, enabled: true,
      policy: .init(
        models: [], limits: limits, imageGeneration: true, imageModels: ["synthetic-image"]))
    await #expect(throws: ExecutionError.unauthorized) {
      try await store.admit(command("stale-vision", "synthetic-chat", oldRevision, vision))
    }
    await #expect(throws: ExecutionError.unauthorized) {
      try await store.admit(command("revoked-vision", "synthetic-chat", key.revision, vision))
    }
    try await store.admit(command("image", "synthetic-image", key.revision, image))
    await #expect(throws: ExecutionError.unauthorized) {
      try await store.admit(command("image-as-chat", "synthetic-image", key.revision, .init()))
    }
    let snapshot = try await store.snapshot(attempt: "image")
    #expect(snapshot.admission.executionRequirements == image)
    #expect(try await store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") } == 2)
  } catch {
    await store.close()
    throw error
  }
  await store.close()
  try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

@Test func v5ImageSemanticMigrationRequiresOfflineBackupAndPreservesLegacyDenial() async throws {
  let path = try temporaryExecutionPath()
  let directory = (path as NSString).deletingLastPathComponent
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let limits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 1000)
  let store = try await SQLiteExecutionStore.open(path: path, limits: limits)
  _ = try await store.createKey(
    id: "legacy", principal: "team", digest: String(repeating: "a", count: 64),
    policy: .init(models: ["synthetic-chat"], limits: limits))
  await store.close()
  // v5 has the same physical tables; only persisted semantic guarantees change in v6.
  try rawSQL(
    path,
    "UPDATE managed_keys SET metadata_json=json_remove(metadata_json,'$.policy.visionInput','$.policy.imageGeneration','$.policy.imageModels'); PRAGMA user_version=5"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: limits)
  }
  try await SQLiteExecutionStore.migrate(path: path)
  try await SQLiteExecutionStore.migrate(path: path)
  let backups = try FileManager.default.contentsOfDirectory(atPath: directory).filter {
    $0.contains(".pre-v6-")
  }
  #expect(backups.count == 1)
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: limits)
  do {
    let key = try #require(try await reopened.listKeys(after: nil).first)
    #expect(
      !key.policy.visionInput && !key.policy.imageGeneration && key.policy.imageModels.isEmpty)
    let version = try await reopened.perform { try $0.scalar("PRAGMA user_version") }
    #expect(version == 6)
  } catch {
    await reopened.close()
    throw error
  }
  await reopened.close()
}
