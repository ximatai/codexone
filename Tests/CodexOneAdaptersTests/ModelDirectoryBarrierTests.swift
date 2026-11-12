import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func retiredModelBlocksPrimingBeforeKeyRevisionCheck() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.perform { db in
    try db.write("INSERT INTO model_directory VALUES(1,1,'{}')")
  }
  let command = ExecutionAdmission(
    attempt: "synthetic",
    owner: .init(
      principal: "priming", key: "priming", namespace: "synthetic", identity: "account"),
    window: "window", policyVersion: "policy", pricingVersion: "price", reservedMicros: 0,
    mode: .priming, model: "synthetic-retired")
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.perform { db in
      try SQLiteExecutionStore.checkKeyAdmission(db, command)
    }
  }
  await store.close()
}

@Test func changedAccountRejectsDirectoryCommit() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let envelope =
    "v1." + String(repeating: "a", count: 32) + "."
    + Data(repeating: 7, count: 28).base64EncodedString()
  let created = try await store.createVerifiedAccount(
    id: "synthetic-account", namespace: "synthetic-namespace", envelope: envelope)
  let enabled = try await store.setAccountMode(
    id: created.id, revision: created.revision, mode: .enabled)
  _ = try await store.setAccountMode(id: enabled.id, revision: enabled.revision, mode: .disabled)
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic-text", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)
  let snapshot = ModelDirectorySnapshot(
    revision: 1, active: [model], retired: [], accountForModel: [model.id: enabled.id])
  await #expect(throws: ExecutionError.conflict) {
    try await store.replaceModelDirectory(
      snapshot, expected: 0, imageModels: [],
      expectedAccount: (id: enabled.id, revision: enabled.revision))
  }
  #expect(try await store.modelDirectorySnapshot().map { _ in true } != true)
  await store.close()
}
