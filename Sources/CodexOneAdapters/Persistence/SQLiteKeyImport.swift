import CodexOneCore
import Dispatch
import Foundation

public struct KeyImportResult: Encodable, Sendable {
  public let importedKeys: Int
  public let enabledKeys: Int = 0
}

private struct KeyImportManifest: Decodable {
  struct Entry: Decodable {
    let id: String
    let principal: String
    let digest: String
    let policy: KeyPolicy
    let sourceActive: Bool
    let sourceExpiresAtUnixSeconds: Int64?
    let policyEquivalent: Bool
  }
  let version: Int
  let capturedAtUnixSeconds: Int64
  let entries: [Entry]
}

extension SQLiteExecutionStore {
  /// Offline, new-target-only import. A digest is verification material and never returned.
  public static func importKeys(
    path: String, manifestFile: String, adminCredentialFile: String, clock: WallClock = .system
  ) async throws -> KeyImportResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(
          with: Result {
            try importKeysOffline(
              path: path, manifestFile: manifestFile, adminCredentialFile: adminCredentialFile,
              clock: clock)
          })
      }
    }
  }

  private static func importKeysOffline(
    path: String, manifestFile: String, adminCredentialFile: String, clock: WallClock
  ) throws -> KeyImportResult {
    guard path.hasPrefix("/"), manifestFile.hasPrefix("/"), adminCredentialFile.hasPrefix("/")
    else { throw ExecutionError.invalidCommand }
    let data = try readPrivateData(manifestFile, maximum: 1_048_576)
    let json = try JSONValue.decode(data)
    guard
      Set(json.object?.keys.map { $0 } ?? []) == ["version", "capturedAtUnixSeconds", "entries"],
      json["entries"]?.array?.allSatisfy({ entry in
        Set(entry.object?.keys.map { $0 } ?? []) == [
          "id", "principal", "digest", "policy", "sourceActive", "sourceExpiresAtUnixSeconds",
          "policyEquivalent",
        ]
          && entry["policy"]?.object?.keys.allSatisfy({
            ["models", "limits", "visionInput", "imageGeneration", "imageModels"].contains($0)
          }) == true
          && Set(entry["policy"]?["limits"]?.object?.keys.map { $0 } ?? []) == [
            "requests", "active", "unresolved", "budgetMicros", "unresolvedMicros",
          ]
      }) == true
    else { throw ExecutionError.invalidCommand }
    let manifest = try JSONDecoder().decode(KeyImportManifest.self, from: data)
    let now = clock.unixSeconds
    guard manifest.capturedAtUnixSeconds >= now - 300,
      manifest.capturedAtUnixSeconds <= now + 60, manifest.version == 1,
      (1...256).contains(manifest.entries.count),
      Set(manifest.entries.map(\.id)).count == manifest.entries.count,
      Set(manifest.entries.map(\.digest)).count == manifest.entries.count
    else { throw ExecutionError.invalidCommand }
    let admin = try readRuntimeSecret(adminCredentialFile)
    guard admin.utf8.count >= 32, !admin.hasPrefix("co1_") else {
      throw ExecutionError.invalidCommand
    }
    let adminDigest = try bearerDigest(["Bearer " + admin])
    for entry in manifest.entries {
      try validateKeyID(entry.id)
      try validateKeyID(entry.principal)
      try validateDigest(entry.digest)
      try entry.policy.validate()
      guard entry.digest != adminDigest, entry.sourceActive, entry.policyEquivalent,
        entry.sourceExpiresAtUnixSeconds == nil
      else { throw ExecutionError.invalidCommand }
    }
    // No new database is opened until the whole private manifest is valid.
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try StorageCapacity.require(directory, additionalBytes: 8 * 1024 * 1024, optional: true)
    let db = try SQLiteConnection(path: path, clock: clock)
    defer { db.shutdown() }
    try db.transaction {
      guard try db.restoreRecord() == nil,
        try db.scalar("SELECT COUNT(*) FROM managed_keys") == 0,
        try db.scalar("SELECT COUNT(*) FROM key_events") == 0,
        try db.scalar("SELECT COUNT(*) FROM attempts") == 0,
        try db.scalar("SELECT COUNT(*) FROM accounts") == 0,
        try db.scalar("SELECT COUNT(*) FROM maintenance_events") == 0
      else { throw ExecutionError.conflict }
      for entry in manifest.entries {
        let key = ManagedKey(
          id: entry.id, principal: entry.principal, revision: 1, enabled: false,
          policy: entry.policy,
          createdAtUnixSeconds: clock.unixSeconds)
        try db.write(
          "INSERT INTO managed_keys VALUES(?,?,?)",
          [.text(key.id), .text(entry.digest), .text(try encodeKey(key))])
        try auditKey(db, key: key, action: "import_disabled")
      }
    }
    return KeyImportResult(importedKeys: manifest.entries.count)
  }
}
