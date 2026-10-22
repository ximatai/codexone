import CSQLite
import CodexOneCore
import Dispatch
import Foundation

public enum KeyMaintenanceError: Error { case incompleteReencryption, wrongActiveKey }

public struct KeyMaintenanceStatus: Codable, Sendable {
  public let activeKeyID: String
  public let availableKeyIDs: [String]
  public let requiredCurrentKeyIDs: [String]
  public let checkpoint: CredentialReencryptionCheckpoint?
  public let backupInventoryRequired: Bool = true
}

/// Offline local maintenance shares the primary instance lock, never contacts an account provider.
public enum SQLiteKeyMaintenance {
  private static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try body() })
      }
    }
  }
  public static func status(path: String, protection: AccountCredentialCipher) async throws
    -> KeyMaintenanceStatus
  {
    try await run {
      let db = try SQLiteConnection(path: path, existingOnly: true)
      defer { db.shutdown() }
      return try status(db, protection)
    }
  }
  private static func status(_ db: SQLiteConnection, _ protection: AccountCredentialCipher) throws
    -> KeyMaintenanceStatus
  {
    KeyMaintenanceStatus(
      activeKeyID: protection.keyID, availableKeyIDs: protection.availableKeyIDs,
      requiredCurrentKeyIDs: try SQLiteSnapshotMaintenance.verifyCredentials(db, protection),
      checkpoint: try db.reencryptionCheckpoint())
  }
  /// A new job requires an independently completed pre-maintenance bundle; nil explicitly resumes.
  public static func reencrypt(
    path: String, protection: AccountCredentialCipher, backupDestination: String?
  ) async throws -> KeyMaintenanceStatus {
    try await reencrypt(
      path: path, protection: protection, backupDestination: backupDestination,
      beforePageCommit: { _ in }, afterPageCommit: { _ in })
  }
  // Fault seams are package-only, used by tests and the credential-free subprocess probe.
  package static func reencrypt(
    path: String, protection: AccountCredentialCipher, backupDestination: String?,
    beforePageCommit: @escaping @Sendable (CredentialReencryptionCheckpoint) throws -> Void,
    afterPageCommit: @escaping @Sendable (CredentialReencryptionCheckpoint) throws -> Void
  ) async throws -> KeyMaintenanceStatus {
    try await run {
      let db = try SQLiteConnection(path: path, existingOnly: true)
      defer { db.shutdown() }
      var checkpoint: CredentialReencryptionCheckpoint
      let old = try db.reencryptionCheckpoint()
      // Authenticate every current envelope before any job/credential mutation.
      _ = try SQLiteSnapshotMaintenance.verifyCredentials(db, protection)
      if let backupDestination {
        guard old?.complete != false else { throw KeyMaintenanceError.incompleteReencryption }
        // Reserve all possible pages plus start/completion before creating the independent backup.
        guard try db.scalar("SELECT COUNT(*) FROM maintenance_events") <= 990 else {
          throw ExecutionError.capacity
        }
        let backup = try SQLiteSnapshotMaintenance.backup(
          db, destination: backupDestination, protection: protection)
        checkpoint = try CredentialReencryptionCheckpoint(
          jobID: UUID().uuidString, backupID: backup.id,
          targetKeyID: protection.keyID, startedUnixSeconds: Int64(Date().timeIntervalSince1970))
        try db.transaction { try save(db, checkpoint) }
      } else {
        guard let old else { throw ExecutionError.conflict }
        guard old.targetKeyID == protection.keyID else { throw KeyMaintenanceError.wrongActiveKey }
        if old.complete { return try status(db, protection) }
        checkpoint = old
      }
      while !checkpoint.complete {
        let current = checkpoint
        checkpoint = try db.transaction {
          guard try db.reencryptionCheckpoint() == current else { throw ExecutionError.conflict }
          let page = try db.rows(
            "SELECT id,namespace,credential_version,revision,sealed_credential FROM accounts WHERE sealed_credential NOT LIKE ? ORDER BY id LIMIT 8",
            [.text("v1." + protection.keyID + ".%")]
          ) { row in
            guard sqlite3_column_bytes(row, 0) <= 64, sqlite3_column_bytes(row, 1) <= 512,
              sqlite3_column_bytes(row, 4) <= 49_152
            else { throw ExecutionError.capacity }
            return (
              String(cString: sqlite3_column_text(row, 0)),
              String(cString: sqlite3_column_text(row, 1)),
              sqlite3_column_int64(row, 2), sqlite3_column_int64(row, 3),
              String(cString: sqlite3_column_text(row, 4))
            )
          }
          for row in page {
            let context = try AccountCredentialContext(
              identity: row.0, namespace: row.1, version: row.2)
            let plaintext = try protection.open(row.4, context: context)
            let envelope = try protection.seal(plaintext, context: context)
            _ = try protection.open(envelope, context: context)
            try db.write(
              "UPDATE accounts SET sealed_credential=? WHERE id=? AND namespace=? AND credential_version=? AND revision=? AND sealed_credential=?",
              [
                .text(envelope), .text(row.0), .text(row.1), .number(row.2), .number(row.3),
                .text(row.4),
              ])
            guard sqlite3_changes(db.handle) == 1 else { throw ExecutionError.conflict }
          }
          let remaining = try db.scalar(
            "SELECT COUNT(*) FROM accounts WHERE sealed_credential NOT LIKE ?",
            [.text("v1." + protection.keyID + ".%")])
          let next = try current.advancing(by: page.count, complete: remaining == 0)
          if next.complete {
            let required = try SQLiteSnapshotMaintenance.verifyCredentials(db, protection)
            guard required.isEmpty || required == [protection.keyID] else {
              throw ExecutionError.conflict
            }
          }
          try beforePageCommit(next)
          try save(db, next)
          return next
        }
        try afterPageCommit(checkpoint)
      }
      return try status(db, protection)
    }
  }
  private static func save(_ db: SQLiteConnection, _ checkpoint: CredentialReencryptionCheckpoint)
    throws
  {
    try SQLiteSnapshotMaintenance.audit(
      db, action: "credential_reencryption",
      record: String(decoding: JSONEncoder().encode(checkpoint), as: UTF8.self),
      at: Int64(Date().timeIntervalSince1970))
  }

  private struct RetirementInventory: Decodable {
    let format: Int
    let inventoryComplete: Bool
    let auditReference: String
    let retainedBackups: [String]
    let restoreDrills: [String]
    let legacyDatabases: [String]
    let legacyRestoreAuditReference: String?
  }
  private struct RetirementEvidence: Codable, Sendable {
    let auditReference: String
    let activeKeyID: String
    let availableKeyIDs: [String]
    let requiredCurrentKeyIDs: [String]
    let requiredBackupKeyIDs: [String]
    let verifiedBackupIDs: [String]
    let verifiedRestoreIDs: [String]
    let verifiedLegacySHA256: [String]
    let legacyRestoreAuditReference: String?
  }
  /// Checks a proposed keyring, not deletion. The operator attests the complete retained inventory.
  public static func checkRetirement(
    path: String, protection: AccountCredentialCipher, inventoryFile: String
  ) async throws -> Data {
    try await run {
      let inventory = try JSONDecoder().decode(
        RetirementInventory.self,
        from: readPrivateData(inventoryFile, maximum: 32768))
      guard inventory.format == 1, inventory.inventoryComplete,
        (1...128).contains(inventory.auditReference.utf8.count),
        inventory.auditReference.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || [45, 46, 95].contains($0)
        }),
        inventory.retainedBackups.count <= 32, inventory.restoreDrills.count <= 32,
        inventory.legacyDatabases.count <= 32,
        Set(inventory.legacyDatabases).count == inventory.legacyDatabases.count,
        Set(inventory.retainedBackups).count == inventory.retainedBackups.count,
        Set(inventory.restoreDrills).count == inventory.restoreDrills.count,
        (inventory.retainedBackups + inventory.restoreDrills + inventory.legacyDatabases)
          .allSatisfy({
            $0.hasPrefix("/") && !$0.utf8.contains(0) && $0.utf8.count <= 4096
          })
      else { throw ExecutionError.invalidCommand }
      if !inventory.legacyDatabases.isEmpty {
        guard let reference = inventory.legacyRestoreAuditReference,
          (1...128).contains(reference.utf8.count),
          reference.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              || [45, 46, 95].contains($0)
          })
        else { throw ExecutionError.invalidCommand }
      }
      let db = try SQLiteConnection(path: path, existingOnly: true)
      defer { db.shutdown() }
      guard try db.reencryptionCheckpoint()?.complete != false else {
        throw KeyMaintenanceError.incompleteReencryption
      }
      let current = try SQLiteSnapshotMaintenance.verifyCredentials(db, protection)
      var backups = Set<String>()
      var requiredBackupKeys = Set<String>()
      for bundle in inventory.retainedBackups {
        let manifest = try SQLiteSnapshotMaintenance.verifyBackup(
          bundle: bundle, protection: protection)
        requiredBackupKeys.formUnion(manifest.requiredKeyIDs)
        guard backups.insert(manifest.id).inserted else { throw ExecutionError.conflict }
      }
      var legacyHashes = Set<String>()
      for file in inventory.legacyDatabases {
        for suffix in ["-wal", "-shm", ".lock", ".restore-pending"] {
          guard !FileManager.default.fileExists(atPath: file + suffix) else {
            throw ExecutionError.invalidCommand
          }
        }
        let original = try SQLiteSnapshotMaintenance.fingerprint(file)
        let legacy = try SQLiteConnection(readOnlyPath: file)
        defer { legacy.shutdown() }
        guard
          try legacy.rows(
            "PRAGMA quick_check", map: { String(cString: sqlite3_column_text($0, 0)) }) == ["ok"],
          try legacy.scalar("SELECT COUNT(*) FROM pragma_foreign_key_check") == 0,
          try legacy.reencryptionCheckpoint()?.complete != false
        else { throw ExecutionError.invalidCommand }
        requiredBackupKeys.formUnion(
          try SQLiteSnapshotMaintenance.verifyCredentials(legacy, protection))
        let unchanged = try SQLiteSnapshotMaintenance.fingerprint(file)
        guard unchanged.0 == original.0, unchanged.1 == original.1,
          legacyHashes.insert(original.1).inserted
        else { throw ExecutionError.conflict }
      }
      var drilled = Set<String>()
      var restores = Set<String>()
      for directory in inventory.restoreDrills {
        let drill = try SQLiteConnection(path: directory + "/core.sqlite", existingOnly: true)
        defer { drill.shutdown() }
        guard try drill.reencryptionCheckpoint()?.complete != false,
          let record = try drill.restoreRecord(), backups.contains(record.backupID),
          restores.insert(record.id).inserted
        else { throw ExecutionError.conflict }
        _ = try SQLiteSnapshotMaintenance.verifyCredentials(drill, protection)
        drilled.insert(record.backupID)
      }
      guard drilled == backups else { throw ExecutionError.denied }
      let evidence = RetirementEvidence(
        auditReference: inventory.auditReference, activeKeyID: protection.keyID,
        availableKeyIDs: protection.availableKeyIDs, requiredCurrentKeyIDs: current,
        requiredBackupKeyIDs: requiredBackupKeys.sorted(), verifiedBackupIDs: backups.sorted(),
        verifiedRestoreIDs: restores.sorted(), verifiedLegacySHA256: legacyHashes.sorted(),
        legacyRestoreAuditReference: inventory.legacyDatabases.isEmpty
          ? nil : inventory.legacyRestoreAuditReference)
      let encoded = try JSONEncoder().encode(evidence)
      try db.transaction {
        try SQLiteSnapshotMaintenance.audit(
          db, action: "key_retirement_checked", record: String(decoding: encoded, as: UTF8.self),
          at: Int64(Date().timeIntervalSince1970))
      }
      return encoded
    }
  }
}

extension SQLiteConnection {
  func reencryptionCheckpoint() throws -> CredentialReencryptionCheckpoint? {
    try rows(
      "SELECT record_json FROM maintenance_events WHERE action='credential_reencryption' ORDER BY id DESC LIMIT 1"
    ) { row in
      guard sqlite3_column_bytes(row, 0) <= 8192 else { throw ExecutionError.capacity }
      let checkpoint = try JSONDecoder().decode(
        CredentialReencryptionCheckpoint.self,
        from: Data(String(cString: sqlite3_column_text(row, 0)).utf8))
      try checkpoint.validate()
      return checkpoint
    }.first
  }
}
