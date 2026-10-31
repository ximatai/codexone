import CSQLite
import CodexOneCore
import Dispatch
import Foundation
import Synchronization

public final class SQLiteExecutionStore: ExecutionStore, Sendable {
  private let queue = DispatchQueue(label: "codexone.core-database")
  private let connection: SQLiteConnection
  let path: String
  let usageReaderGate = Mutex(false)
  let usageActivity = Mutex(false)
  let liveFirstEvents = Mutex([String: Bool]())
  let storage: SQLiteStorageGuard
  public var allowsOptionalStorageWork: Bool { isAvailable && storage.snapshot.optionalWorkAllowed }
  let limits: ExecutionLimits
  let unresolvedCapacity: Int64
  private let restoration: RestoreRecord?
  public var hasRestoredSnapshot: Bool { restoration != nil }
  public var isAdmissionReady: Bool {
    isAvailable && storage.snapshot.admissionAllowed
      && (restoration?.allowsAdmission(at: Int64(Date().timeIntervalSince1970)) ?? true)
  }
  private let gate = Mutex(
    (
      regular: 0, critical: 0, closing: false, failed: false, recentWait: UInt64(0),
      maxWait: UInt64(0)
    ))

  public var isAvailable: Bool { gate.withLock { !$0.closing && !$0.failed } }

  init(
    connection: SQLiteConnection, limits: ExecutionLimits, path: String,
    restoration: RestoreRecord? = nil, storage: SQLiteStorageGuard? = nil,
    unresolvedCapacity: Int64 = ExecutionLimits.unresolvedCapacity
  ) throws {
    self.storage = try storage ?? SQLiteStorageGuard(path: path, policy: .standard)
    if storage == nil { try self.storage.refresh(connection, maintenance: false) }
    self.path = path
    self.restoration = restoration
    self.connection = connection
    self.limits = limits
    self.unresolvedCapacity = unresolvedCapacity
  }
  /// Call before publishing any admission path. Initialization never blocks a network event loop.
  public static func open(
    path: String, limits: ExecutionLimits,
    unresolvedCapacity: Int64 = ExecutionLimits.unresolvedCapacity
  ) async throws
    -> SQLiteExecutionStore
  {
    try await open(
      path: path, limits: limits, storagePolicy: .standard, available: StorageCapacity.available,
      unresolvedCapacity: unresolvedCapacity)
  }
  package static func open(
    path: String, limits: ExecutionLimits, storagePolicy: StorageSpacePolicy,
    available: @escaping @Sendable (String) throws -> Int64,
    unresolvedCapacity: Int64 = ExecutionLimits.unresolvedCapacity
  ) async throws -> SQLiteExecutionStore {
    guard unresolvedCapacity > 0, unresolvedCapacity <= 1_000_000_000_000,
      [
        limits.requests, limits.active, limits.unresolved, limits.budgetMicros,
        limits.unresolvedMicros,
      ].allSatisfy({
        $0.map { $0 > 0 && $0 <= 1_000_000_000_000 } ?? false
      })
    else {
      throw ExecutionError.invalidCommand
    }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try SQLiteConnection(path: path)
          guard try connection.reencryptionCheckpoint()?.complete != false else {
            throw KeyMaintenanceError.incompleteReencryption
          }
          let storage = try SQLiteStorageGuard(
            path: path, policy: storagePolicy, available: available)
          try storage.refresh(connection, maintenance: true)
          try storage.prepare(connection, admission: false, optional: false, essential: true)
          try connection.transaction {
            let json = try encode(limits)
            let existing = try connection.rows("SELECT limits_json FROM metadata WHERE id=1") {
              String(cString: sqlite3_column_text($0, 0))
            }
            if let existing = existing.first {
              guard try decode(ExecutionLimits.self, existing) == limits else {
                throw ExecutionError.conflict
              }
            } else {
              try connection.write("INSERT INTO metadata VALUES(1,?)", [.text(json)])
            }
            try connection.exec(
              "DELETE FROM account_concurrency WHERE peak<=(SELECT COUNT(*) FROM attempts a WHERE a.namespace=account_concurrency.namespace AND a.identity=account_concurrency.identity AND a.state='intent')"
            )
            try connection.write(
              "INSERT INTO account_concurrency SELECT namespace,identity,?,COUNT(*) FROM attempts WHERE state='intent' GROUP BY namespace,identity ON CONFLICT(namespace,identity,at_epoch) DO UPDATE SET peak=MAX(peak,excluded.peak)",
              [.number(Int64(Date().timeIntervalSince1970))])
            // All intents belonged to the previous owner, whose instance lock is now ours.
            try connection.write(
              "UPDATE attempts SET state='unknown',unknown_since_epoch=? WHERE state='intent'",
              [.number(Int64(Date().timeIntervalSince1970))])
            try Self.recoverAccountRefreshes(connection)
            if storage.snapshot.optionalWorkAllowed {
              try connection.write(
                "DELETE FROM request_diagnostics WHERE at_epoch<?",
                [.number(Int64(Date().timeIntervalSince1970) - 30 * 86400)])
            }
          }
          try storage.refresh(connection, maintenance: false)
          continuation.resume(
            returning: try SQLiteExecutionStore(
              connection: connection, limits: limits, path: path,
              restoration: try connection.restoreRecord(), storage: storage,
              unresolvedCapacity: unresolvedCapacity))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// Offline, instance-locked upgrade; a consistent private backup precedes any schema change.
  public static func migrate(path: String) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try SQLiteConnection(path: path, migrating: true)
          connection.shutdown()
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// Queue capacity is acquired before dispatch; finalization has its own reserved slots.
  func perform<T: Sendable>(
    critical: Bool = false, admission: Bool = false, optional: Bool = false,
    essential: Bool = false,
    _ body: @escaping @Sendable (SQLiteConnection) throws -> T
  ) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
      let enqueuedAt = DispatchTime.now().uptimeNanoseconds
      let accepted = gate.withLock { state in
        guard !state.closing else { return false }
        if critical {
          guard state.critical < 16 else { return false }
          state.critical += 1
        } else {
          guard state.regular < 16 else { return false }
          state.regular += 1
        }
        // Enqueue under the gate so close cannot overtake an already accepted command.
        queue.async { [self] in
          let wait = (DispatchTime.now().uptimeNanoseconds - enqueuedAt) / 1000
          gate.withLock {
            $0.recentWait = wait
            $0.maxWait = max($0.maxWait, wait)
          }
          let result = Result {
            if (admission || optional) && gate.withLock({ $0.failed }) {
              throw ExecutionError.storageUnavailable
            }
            if admission || optional || essential || critical {
              try storage.prepare(
                connection, admission: admission, optional: optional,
                essential: essential || critical)
            }
            return try body(connection)
          }
          gate.withLock { state in
            if case .failure(let error) = result, error as? ExecutionError == .storageUnavailable {
              state.failed = true
            }
            if critical { state.critical -= 1 } else { state.regular -= 1 }
          }
          continuation.resume(with: result)
        }
        return true
      }
      if !accepted { continuation.resume(throwing: ExecutionError.capacity) }
    }
  }

  public func close() async {
    await withCheckedContinuation { continuation in
      gate.withLock { state in
        state.closing = true
        queue.async { [self] in
          storage.shutdown()
          connection.shutdown()
          continuation.resume()
        }
      }
    }
  }

  /// An already observed, unadmitted provider execution is responsibility, not new permission.
  /// Preserve the connection's durable owner even if the Key has since been disabled or exhausted.
  public func recordUnexpectedExecution(basedOn attempt: String) async throws {
    try await perform(essential: true) { db in
      try db.transaction {
        let original = try Self.load(db, attempt).admission
        let command = ExecutionAdmission(
          attempt: UUID().uuidString, owner: original.owner,
          window: "utc-day-\(Int64(Date().timeIntervalSince1970) / 86400)",
          policyVersion: original.policyVersion, pricingVersion: original.pricingVersion,
          reservedMicros: original.reservedMicros, requestID: UUID().uuidString,
          mode: .generation, keyRevision: original.keyRevision,
          accountSnapshot: original.accountSnapshot)
        try Self.insertAttempt(db, command, state: "unknown")
      }
    }
  }

  public func admit(_ command: ExecutionAdmission) async throws {
    try validateAdmission(command)
    try await perform(admission: true) { [limits, unresolvedCapacity] db in
      try db.transaction {
        try Self.admitTransaction(
          db, command, limits: limits, unresolvedCapacity: unresolvedCapacity)
      }
    }
  }
  static func admitTransaction(
    _ db: SQLiteConnection, _ command: ExecutionAdmission, limits: ExecutionLimits,
    unresolvedCapacity: Int64
  ) throws {
    try validateAdmission(command)
    if let restored = try db.restoreRecord() {
      let now = Int64(Date().timeIntervalSince1970)
      guard restored.allowsAdmission(at: now), command.keyRevision != nil,
        command.window == "utc-day-\(now / 86400)"
      else { throw ExecutionError.maintenanceRequired }

    }
    guard
      try db.scalar("SELECT COUNT(*) FROM attempts WHERE id=?", [.text(command.attempt)]) == 0
    else { throw ExecutionError.conflict }
    try Self.checkAccountAdmission(db, command)
    try Self.checkKeyAdmission(db, command)
    let active = try db.scalar(
      "SELECT COUNT(*) FROM attempts WHERE namespace=? AND identity=? AND state='intent'",
      [.text(command.owner.namespace), .text(command.owner.identity)])
    guard active < ExecutionLimits.accountConcurrency else {
      throw ExecutionError.accountConcurrency
    }
    for reference in command.references ?? [] {
      let values: [SQLiteConnection.Value] = [
        .text(command.owner.principal), .text(command.owner.namespace),
        .text(command.owner.identity), .text(reference.type), .text(reference.rawID),
      ]
      guard
        try db.scalar(
          "SELECT COUNT(*) FROM bindings WHERE principal=? AND namespace=? AND identity=? AND object_type=? AND raw_id=? AND expires_at_epoch>strftime('%s','now')",
          values) == 1
      else { throw ExecutionError.unknownObject }
      try db.write(
        "UPDATE bindings SET expires_at_epoch=? WHERE principal=? AND namespace=? AND identity=? AND object_type=? AND raw_id=?",
        [.number(Int64(Date().timeIntervalSince1970) + ExecutionLimits.bindingContinuationSeconds)]
          + values)
    }
    try Self.insertAttempt(db, command, state: "intent")
  }

  static func insertAttempt(
    _ db: SQLiteConnection, _ command: ExecutionAdmission, state: String
  ) throws {
    try db.write(
      """
      INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,reserved,state,admission_json,created_at_epoch,request_id,unknown_since_epoch)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      """,
      [
        .text(command.attempt), .text(command.owner.principal), .text(command.owner.key),
        .text(command.owner.namespace), .text(command.owner.identity), .text(command.window),
        .text(command.policyVersion), .text(command.pricingVersion),
        .number(command.reservedMicros), .text(state), .text(try encode(command)),
        .number(Int64(Date().timeIntervalSince1970)), command.requestID.map { .text($0) } ?? .null,
        state == "unknown" ? .number(Int64(Date().timeIntervalSince1970)) : .null,
      ])
    if state == "intent" { try Self.recordAccountConcurrency(db, owner: command.owner) }
  }

  static func recordAccountConcurrency(_ db: SQLiteConnection, owner: ExecutionOwner) throws {
    let current = try db.scalar(
      "SELECT COUNT(*) FROM attempts WHERE namespace=? AND identity=? AND state='intent'",
      [.text(owner.namespace), .text(owner.identity)])
    // A newer sample dominates older samples of equal/lower concurrency for every future window.
    // Keep a monotone frontier (at most 16 values/account), rather than one row per request/second.
    let now = Int64(Date().timeIntervalSince1970)
    try db.write(
      "DELETE FROM account_concurrency WHERE namespace=? AND identity=? AND at_epoch<=? AND peak<=?",
      [.text(owner.namespace), .text(owner.identity), .number(now), .number(current)])
    try db.write(
      "INSERT INTO account_concurrency VALUES(?,?,?,?) ON CONFLICT(namespace,identity,at_epoch) DO UPDATE SET peak=MAX(peak,excluded.peak)",
      [
        .text(owner.namespace), .text(owner.identity), .number(now),
        .number(current),
      ])
  }

  public func bind(attempt: String, object: ObjectBinding) async throws {
    try validateStrings([attempt, object.type, object.rawID])
    try await perform(essential: true) { db in
      try db.transaction {
        let snapshot = try Self.load(db, attempt)
        guard snapshot.state == .intent else { throw ExecutionError.conflict }
        let owner = snapshot.admission.owner
        let values: [SQLiteConnection.Value] = [
          .text(owner.principal), .text(owner.namespace), .text(owner.identity), .text(object.type),
          .text(object.rawID),
        ]
        let matches = try db.rows(
          "SELECT attempt FROM bindings WHERE principal=? AND namespace=? AND identity=? AND object_type=? AND raw_id=?",
          values
        ) { String(cString: sqlite3_column_text($0, 0)) }
        // Retained history re-emits objects already owned by this principal and identity.
        guard matches.isEmpty else {
          try db.write(
            "UPDATE bindings SET expires_at_epoch=? WHERE principal=? AND namespace=? AND identity=? AND object_type=? AND raw_id=?",
            [
              .number(
                Int64(Date().timeIntervalSince1970) + ExecutionLimits.bindingContinuationSeconds)
            ] + values)
          return
        }
        try db.write(
          "INSERT INTO bindings VALUES(?,?,?,?,?,?,?)",
          values + [
            .text(attempt),
            .number(
              Int64(Date().timeIntervalSince1970) + ExecutionLimits.bindingContinuationSeconds),
          ])
      }
    }
  }

  public func resolve(principal: String, object: ObjectBinding, namespace: String? = nil)
    async throws -> ExecutionOwner
  {
    try validateStrings([principal, object.type, object.rawID])
    if let namespace { try validateStrings([namespace], maximum: 512) }
    return try await perform { db in
      var sql =
        "SELECT a.admission_json FROM bindings b JOIN attempts a ON a.id=b.attempt WHERE b.expires_at_epoch>strftime('%s','now') AND b.principal=? AND b.object_type=? AND b.raw_id=?"
      var values: [SQLiteConnection.Value] = [
        .text(principal), .text(object.type), .text(object.rawID),
      ]
      if let namespace {
        sql += " AND b.namespace=?"
        values.append(.text(namespace))
      }
      sql += " LIMIT 2"
      let owners = try db.rows(sql, values) {
        try decode(ExecutionAdmission.self, String(cString: sqlite3_column_text($0, 0))).owner
      }
      guard let owner = owners.first else { throw ExecutionError.unknownObject }
      guard owners.count == 1 else { throw ExecutionError.ambiguousObject }
      return owner
    }
  }

  public func finalize(attempt: String, evidence: UsageEvidence?, outcome: ExecutionOutcome? = nil)
    async throws
  {
    try validateStrings([attempt])
    if let evidence { try validate(evidence) }
    try outcome?.validate()
    try await perform(critical: true) { db in
      try db.transaction {
        let snapshot = try Self.load(db, attempt)
        if snapshot.state == .intent {
          try Self.recordAccountConcurrency(db, owner: snapshot.admission.owner)
        }
        if let outcome { try Self.recordOutcome(db, snapshot: snapshot, outcome: outcome) }
        guard let evidence else {
          if snapshot.state == .intent {
            try db.write(
              "UPDATE attempts SET state='unknown',unknown_since_epoch=COALESCE(unknown_since_epoch,?) WHERE id=?",
              [.number(Int64(Date().timeIntervalSince1970)), .text(attempt)])
          }
          return
        }
        let existing = try db.rows(
          "SELECT payload FROM evidence WHERE attempt=? AND revision=?",
          [.text(attempt), .number(evidence.revision)]
        ) { String(cString: sqlite3_column_text($0, 0)) }
        if let existing = existing.first {
          guard try decode(UsageEvidence.self, existing) == evidence else {
            throw ExecutionError.conflict
          }
          return
        }
        let floor = try db.scalar(
          "SELECT evidence_floor FROM attempts WHERE id=?", [.text(attempt)])
        guard evidence.revision > floor else { throw ExecutionError.staleEvidence }
        if let old = snapshot.usage, evidence.revision > old.revision {
          guard evidence.inputTokens >= old.inputTokens, evidence.outputTokens >= old.outputTokens,
            evidence.cachedTokens >= old.cachedTokens, evidence.images >= old.images,
            evidence.estimatedMicros >= old.estimatedMicros,
            (evidence.imageInputTokens ?? 0) >= (old.imageInputTokens ?? 0),
            (evidence.imageOutputTokens ?? 0) >= (old.imageOutputTokens ?? 0),
            (evidence.imageInputTextTokens ?? 0) >= (old.imageInputTextTokens ?? 0),
            (evidence.imageInputImageTokens ?? 0) >= (old.imageInputImageTokens ?? 0),
            old.completeness != .complete || evidence.completeness == .complete
          else { throw ExecutionError.conflict }
        }
        if let old = snapshot.usage, evidence.revision < old.revision {
          guard evidence.inputTokens <= old.inputTokens, evidence.outputTokens <= old.outputTokens,
            evidence.cachedTokens <= old.cachedTokens, evidence.images <= old.images,
            evidence.estimatedMicros <= old.estimatedMicros,
            (evidence.imageInputTokens ?? 0) <= (old.imageInputTokens ?? 0),
            (evidence.imageOutputTokens ?? 0) <= (old.imageOutputTokens ?? 0),
            (evidence.imageInputTextTokens ?? 0) <= (old.imageInputTextTokens ?? 0),
            (evidence.imageInputImageTokens ?? 0) <= (old.imageInputImageTokens ?? 0),
            evidence.completeness != .complete || old.completeness == .complete
          else {
            throw ExecutionError.conflict
          }
        }
        try db.write(
          "INSERT INTO evidence VALUES(?,?,?)",
          [
            .text(attempt), .number(evidence.revision),
            .text(try encode(evidence)),
          ])
        if try db.scalar("SELECT COUNT(*) FROM evidence WHERE attempt=?", [.text(attempt)]) > 128 {
          let retired = try db.scalar(
            "SELECT MIN(revision) FROM evidence WHERE attempt=?", [.text(attempt)])
          try db.write(
            "DELETE FROM evidence WHERE attempt=? AND revision=?",
            [.text(attempt), .number(retired)])
          try db.write(
            "UPDATE attempts SET evidence_floor=? WHERE id=?", [.number(retired), .text(attempt)])
        }
        // An audited manual release remains settled when late evidence is still incomplete.
        if snapshot.usage == nil || evidence.revision > snapshot.usage!.revision {
          try db.write(
            "UPDATE attempts SET state=?,usage_json=?,estimated=?,unknown_since_epoch=COALESCE(unknown_since_epoch,?),closed_unknown_at_epoch=CASE WHEN ?='complete' THEN NULL ELSE closed_unknown_at_epoch END WHERE id=?",
            [
              .text(
                snapshot.state == .settled || snapshot.state == .closedUnknown
                  || evidence.completeness == .complete
                  ? "settled" : "unknown"),
              .text(try encode(evidence)),
              .number(evidence.estimatedMicros), .number(Int64(Date().timeIntervalSince1970)),
              .text(evidence.completeness.rawValue), .text(attempt),
            ])
        }
      }
    }
  }

  public func snapshot(attempt: String) async throws -> ExecutionSnapshot {
    try validateStrings([attempt])
    return try await perform { try Self.load($0, attempt) }
  }
  private static func load(_ db: SQLiteConnection, _ attempt: String) throws -> ExecutionSnapshot {
    let results = try db.rows(
      "SELECT admission_json,CASE WHEN closed_unknown_at_epoch IS NOT NULL THEN 'closed_unknown' ELSE state END,usage_json FROM attempts WHERE id=?",
      [.text(attempt)]
    ) { s in
      let admission = try decode(
        ExecutionAdmission.self, String(cString: sqlite3_column_text(s, 0)))
      guard
        let state = ExecutionSnapshot.State(rawValue: String(cString: sqlite3_column_text(s, 1)))
      else { throw ExecutionError.storageUnavailable }
      let usage =
        sqlite3_column_type(s, 2) == SQLITE_NULL
        ? nil : try decode(UsageEvidence.self, String(cString: sqlite3_column_text(s, 2)))
      return ExecutionSnapshot(admission: admission, state: state, usage: usage)
    }
    guard let result = results.first else { throw ExecutionError.unknownAttempt }
    return result
  }
}

private func validateStrings(_ values: [String], maximum: Int = 256) throws {
  guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximum && !$0.utf8.contains(0) })
  else {
    throw ExecutionError.invalidCommand
  }
}
func validateAdmission(_ value: ExecutionAdmission) throws {
  try value.executionRequirements.validate()
  guard (value.references?.count ?? 0) <= 32 else { throw ExecutionError.invalidCommand }
  for reference in value.references ?? [] {
    try validateStrings([reference.type, reference.rawID])
  }
  guard
    value.executionRequirements.route != .images
      || value.executionRequirements.imageModel == value.model
  else {
    throw ExecutionError.invalidCommand
  }
  try validateStrings(
    [
      value.attempt, value.owner.principal, value.owner.key,
      value.owner.identity, value.window, value.policyVersion, value.pricingVersion,
    ] + (value.requestID.map { [$0] } ?? []) + (value.model.map { [$0] } ?? []))
  try validateStrings([value.owner.namespace], maximum: 512)
  if let account = value.accountSnapshot {
    _ = try AccountDispatchSnapshot(
      revision: account.revision, credentialVersion: account.credentialVersion,
      accessExpiresAtUnixSeconds: account.accessExpiresAtUnixSeconds,
      continuation: account.continuation)
  }
  guard (0...1_000_000_000_000).contains(value.reservedMicros) else {
    throw ExecutionError.invalidCommand
  }
}
private func validate(_ value: UsageEvidence) throws {
  guard
    [
      value.revision, value.inputTokens, value.outputTokens, value.cachedTokens, value.images,
      value.estimatedMicros, value.imageInputTokens ?? 0, value.imageOutputTokens ?? 0,
      value.imageInputTextTokens ?? 0, value.imageInputImageTokens ?? 0,
    ].allSatisfy({ (0...1_000_000_000_000).contains($0) }), value.cachedTokens <= value.inputTokens
  else { throw ExecutionError.invalidCommand }
}
func encode<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}
func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
  do { return try JSONDecoder().decode(type, from: Data(value.utf8)) } catch {
    throw ExecutionError.storageUnavailable
  }
}

extension SQLiteExecutionStore: StorageMonitoring {
  public var storageObservation: StorageObservation {
    var observation = storage.snapshot
    gate.withLock { state in
      observation.coreAvailable = !state.closing && !state.failed
      observation.regularQueued = state.regular
      observation.criticalQueued = state.critical
      observation.recentQueueWaitMicros = state.recentWait
      observation.maximumQueueWaitMicros = state.maxWait
    }
    observation.usageReaderActive = usageActivity.withLock { $0 }
    return observation
  }
  public func maintainStorage() async throws {
    try await perform { [self] db in
      guard isAvailable else { throw ExecutionError.storageUnavailable }
      try storage.refresh(db, maintenance: true)
      // Only expired diagnostics are eligible, with bounded work and spare space above admission.
      if storage.snapshot.pressure == .degraded,
        (storage.snapshot.availableBytes ?? 0) > storage.policy.stopBytes + 8 * 1024 * 1024
      {
        try db.write(
          "DELETE FROM request_diagnostics WHERE request_id IN (SELECT request_id FROM request_diagnostics WHERE at_epoch<? ORDER BY at_epoch LIMIT 100)",
          [.number(Int64(Date().timeIntervalSince1970) - 30 * 86400)])
      }
    }
  }
}

extension SQLiteExecutionStore: ExecutionLiveObserving {
  public func executionStarted(attempt: String) {
    liveFirstEvents.withLock { if $0.count < 16 { $0[attempt] = false } }
  }
  public func executionReceivedFirstEvent(attempt: String) {
    liveFirstEvents.withLock { if $0[attempt] != nil { $0[attempt] = true } }
  }
  public func executionObservationEnded(attempt: String) {
    liveFirstEvents.withLock { _ = $0.removeValue(forKey: attempt) }
  }
}

extension SQLiteExecutionStore: UnknownExecutionReleasing {
  public func releaseUnknown(beforeUnixSeconds: Int64, expectedCount: Int64) async throws -> Int64 {
    guard beforeUnixSeconds >= 0, expectedCount >= 0 else { throw ExecutionError.invalidCommand }
    return try await perform(essential: true) { db in
      try db.transaction {
        let count = try db.scalar(
          "SELECT COUNT(*) FROM attempts WHERE state='unknown' AND created_at_epoch<?",
          [.number(beforeUnixSeconds)])
        guard count == expectedCount else { throw ExecutionError.conflict }
        try Self.closeUnknown(
          db,
          ids: try db.rows(
            "SELECT id FROM attempts WHERE state='unknown' AND created_at_epoch<?",
            [.number(beforeUnixSeconds)]
          ) { String(cString: sqlite3_column_text($0, 0)) }, before: beforeUnixSeconds,
          automatic: false, now: Int64(Date().timeIntervalSince1970))
        return count
      }
    }
  }
}
