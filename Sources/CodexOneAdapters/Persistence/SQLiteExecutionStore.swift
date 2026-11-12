import CSQLite
import CodexOneCore
import Dispatch
import Foundation
import Synchronization

public final class SQLiteExecutionStore: ExecutionStore, Sendable {
  private let queue = DispatchQueue(label: "codexone.core-database")
  private let connection: SQLiteConnection
  public var businessDay: BusinessDayDefinition { connection.businessDay }
  var clock: WallClock { connection.clock }
  let path: String
  let pacingWaiters: AccountPacingWaiters
  let usageReaderGate = Mutex(false)
  let quotaCycleReaderGate = Mutex(false)
  let usageActivity = Mutex(false)
  public let overviewActivity: OverviewActivity
  let liveFirstEvents = Mutex([String: Bool]())
  let storage: SQLiteStorageGuard
  public var allowsOptionalStorageWork: Bool { isAvailable && storage.snapshot.optionalWorkAllowed }
  let limits: ExecutionLimits
  let unresolvedCapacity: Int64
  private let restoration: RestoreRecord?
  public var hasRestoredSnapshot: Bool { restoration != nil }
  public var isAdmissionReady: Bool {
    isAvailable && storage.snapshot.admissionAllowed
      && (restoration?.allowsAdmission(at: connection.clock.unixSeconds) ?? true)
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
    unresolvedCapacity: Int64 = ExecutionLimits.unresolvedCapacity,
    pacingSleep: @escaping @Sendable (Double) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) throws {
    self.pacingWaiters = AccountPacingWaiters(sleep: pacingSleep)
    self.storage =
      try storage ?? SQLiteStorageGuard(path: path, policy: .standard, clock: connection.clock)
    if storage == nil { try self.storage.refresh(connection, maintenance: false) }
    self.path = path
    self.restoration = restoration
    self.connection = connection
    let historicalRateHorizon = try connection.scalar(
      "SELECT COALESCE(MAX(output_rate_settled_at),-1) FROM attempts")
    self.overviewActivity = OverviewActivity(
      businessDay: connection.businessDay,
      startedAt: max(connection.clock.unixSeconds, historicalRateHorizon))
    self.limits = limits
    self.unresolvedCapacity = unresolvedCapacity
    try loadOutputRateHistory(connection)
  }

  private func loadOutputRateHistory(_ db: SQLiteConnection) throws {
    let now = db.clock.unixSeconds
    let today = try db.businessDay.start(containing: now)
    func restore(
      from start: Int64, width: Int64, limit: Int, source: OverviewActivity.OutputSampleSource
    ) throws {
      let samples = try Self.outputSamples(db, from: start, width: width, limit: limit)
      for (second, rowID, rate) in samples.reversed() {
        overviewActivity.recordRequestOutput(
          rate, at: second, rowID: rowID, source: source)
      }
    }
    for day in stride(from: today - 6 * 86400, through: today, by: 86400) {
      try restore(
        from: day, width: 86400, limit: OverviewActivity.outputDayCapacity, source: .dailyHistory)
    }
    let hour = now / 3600 * 3600
    let firstHour = hour - Int64(OverviewActivity.outputHistoryHours - 1) * 3600
    for start in stride(from: firstHour, through: hour, by: 3600) {
      try restore(
        from: start, width: 3600, limit: OverviewActivity.outputHourCapacity, source: .hourlyHistory
      )
    }
  }
  private static func outputSamples(
    _ db: SQLiteConnection, from start: Int64, width: Int64, limit: Int
  ) throws -> [(Int64, Int64, Decimal)] {
    let now = db.clock.unixSeconds
    let samples = try db.rows(
      """
      SELECT output_rate_settled_at,rowid,output_rate FROM attempts
      WHERE output_rate_settled_at>=? AND output_rate_settled_at<?
        AND CASE WHEN json_valid(usage_json) THEN COALESCE(json_extract(usage_json, '$.images'), 0) ELSE 0 END = 0
      ORDER BY output_rate_settled_at DESC,rowid DESC LIMIT ?
      """,
      [
        .number(start), .number(min(start + width, now + 1)), .number(Int64(limit)),
      ]
    ) { row -> (Int64, Int64, Decimal)? in
      guard let raw = sqlite3_column_text(row, 2),
        let rate = Decimal(
          string: String(cString: raw), locale: Locale(identifier: "en_US_POSIX"))
      else { return nil }
      return (sqlite3_column_int64(row, 0), sqlite3_column_int64(row, 1), rate)
    }
    return samples.compactMap { $0 }
  }
  /// Call before publishing any admission path. Initialization never blocks a network event loop.
  public static func open(
    path: String, limits: ExecutionLimits,
    unresolvedCapacity: Int64 = ExecutionLimits.unresolvedCapacity, clock: WallClock = .system,
    businessDay: BusinessDayDefinition = .utc, allowStartupMigration: Bool = false,
    pacingSleep: @escaping @Sendable (Double) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) async throws
    -> SQLiteExecutionStore
  {
    try await open(
      path: path, limits: limits, storagePolicy: .standard, available: StorageCapacity.available,
      unresolvedCapacity: unresolvedCapacity, clock: clock, businessDay: businessDay,
      allowStartupMigration: allowStartupMigration, pacingSleep: pacingSleep)
  }
  package static func open(
    path: String, limits: ExecutionLimits, storagePolicy: StorageSpacePolicy,
    available: @escaping @Sendable (String) throws -> Int64,
    unresolvedCapacity: Int64 = ExecutionLimits.unresolvedCapacity, clock: WallClock = .system,
    businessDay: BusinessDayDefinition = .utc, allowStartupMigration: Bool = false,
    pacingSleep: @escaping @Sendable (Double) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
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
          let connection = try SQLiteConnection(
            path: path, allowStartupMigration: allowStartupMigration, clock: clock,
            businessDay: businessDay)
          guard try connection.reencryptionCheckpoint()?.complete != false else {
            throw KeyMaintenanceError.incompleteReencryption
          }
          let storage = try SQLiteStorageGuard(
            path: path, policy: storagePolicy, available: available, clock: clock)
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
              [.number(connection.clock.unixSeconds)])
            // All intents belonged to the previous owner, whose instance lock is now ours.
            try connection.write(
              "UPDATE attempts SET state='unknown',unknown_since_epoch=? WHERE state='intent'",
              [.number(connection.clock.unixSeconds)])
            try Self.recoverAccountRefreshes(connection)
            try Self.recoverQuotaPriming(connection)
            if storage.snapshot.optionalWorkAllowed {
              try connection.write(
                "DELETE FROM request_diagnostics WHERE at_epoch<?",
                [.number(connection.clock.unixSeconds - 30 * 86400)])
            }
          }
          try storage.refresh(connection, maintenance: false)
          continuation.resume(
            returning: try SQLiteExecutionStore(
              connection: connection, limits: limits, path: path,
              restoration: try connection.restoreRecord(), storage: storage,
              unresolvedCapacity: unresolvedCapacity, pacingSleep: pacingSleep))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// Offline, instance-locked upgrade; a consistent private backup precedes any schema change.
  public static func migrate(path: String, clock: WallClock = .system) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try SQLiteConnection(path: path, migrating: true, clock: clock)
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
    gate.withLock { $0.closing = true }
    await pacingWaiters.close()
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
        let now = db.clock.unixSeconds
        let original = try Self.load(db, attempt).admission
        let command = ExecutionAdmission(
          attempt: UUID().uuidString, owner: original.owner,
          window: try db.businessDay.window(containing: now),
          policyVersion: original.policyVersion, pricingVersion: original.pricingVersion,
          reservedMicros: original.reservedMicros, requestID: UUID().uuidString,
          mode: .generation, keyRevision: original.keyRevision,
          accountSnapshot: original.accountSnapshot)
        try Self.insertAttempt(db, command, state: "unknown", at: now)
      }
    }
  }

  @discardableResult public func admit(_ command: ExecutionAdmission) async throws
    -> ExecutionAdmission
  {
    try validateAdmission(command)
    return try await perform(admission: true) { [limits, unresolvedCapacity] db in
      let admitted = try db.transaction {
        try Self.admitTransaction(
          db, command, limits: limits, unresolvedCapacity: unresolvedCapacity)
      }
      self.publishOverview(admitted, at: db.clock.unixSeconds)
      return admitted
    }
  }
  static func admitTransaction(
    _ db: SQLiteConnection, _ command: ExecutionAdmission, limits: ExecutionLimits,
    unresolvedCapacity: Int64
  ) throws -> ExecutionAdmission {
    try validateAdmission(command)
    let now = db.clock.unixSeconds
    // The transaction clock determines the final window for every admission.
    let command = command.withWindow(try db.businessDay.window(containing: now))
    if let restored = try db.restoreRecord() {
      guard restored.allowsAdmission(at: now),
        command.keyRevision != nil || command.executionMode == .priming
      else { throw ExecutionError.maintenanceRequired }

    }
    guard
      try db.scalar("SELECT COUNT(*) FROM attempts WHERE id=?", [.text(command.attempt)]) == 0
    else { throw ExecutionError.conflict }
    try Self.checkAccountAdmission(db, command)
    try Self.checkKeyAdmission(db, command, now: now)
    let active = try db.scalar(
      "SELECT COUNT(*) FROM attempts WHERE namespace=? AND identity=? AND state='intent'",
      [.text(command.owner.namespace), .text(command.owner.identity)])
    guard active < ExecutionLimits.accountConcurrency else {
      throw ExecutionError.accountConcurrency
    }
    if command.executionMode == .priming { try Self.admitQuotaPriming(db, command) }
    for reference in command.references ?? [] {
      let values: [SQLiteConnection.Value] = [
        .text(command.owner.principal), .text(command.owner.namespace),
        .text(command.owner.identity), .text(reference.type), .text(reference.rawID),
      ]
      guard
        try db.scalar(
          "SELECT COUNT(*) FROM bindings WHERE principal=? AND namespace=? AND identity=? AND object_type=? AND raw_id=? AND expires_at_epoch>\(db.clock.unixSeconds)",
          values) == 1
      else { throw ExecutionError.unknownObject }
      try db.write(
        "UPDATE bindings SET expires_at_epoch=? WHERE principal=? AND namespace=? AND identity=? AND object_type=? AND raw_id=?",
        [.number(db.clock.unixSeconds + ExecutionLimits.bindingContinuationSeconds)]
          + values)
    }
    try Self.insertAttempt(db, command, state: "intent", at: now)
    return command
  }

  static func insertAttempt(
    _ db: SQLiteConnection, _ command: ExecutionAdmission, state: String, at: Int64? = nil
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
        .number(at ?? db.clock.unixSeconds), command.requestID.map { .text($0) } ?? .null,
        state == "unknown" ? .number(db.clock.unixSeconds) : .null,
      ])
    if state == "intent" { try Self.recordAccountConcurrency(db, owner: command.owner) }
  }

  static func recordAccountConcurrency(_ db: SQLiteConnection, owner: ExecutionOwner) throws {
    let current = try db.scalar(
      "SELECT COUNT(*) FROM attempts WHERE namespace=? AND identity=? AND state='intent'",
      [.text(owner.namespace), .text(owner.identity)])
    // A newer sample dominates older samples of equal/lower concurrency for every future window.
    // Keep a monotone frontier (at most 16 values/account), rather than one row per request/second.
    let now = db.clock.unixSeconds
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
                db.clock.unixSeconds + ExecutionLimits.bindingContinuationSeconds)
            ] + values)
          return
        }
        try db.write(
          "INSERT INTO bindings VALUES(?,?,?,?,?,?,?)",
          values + [
            .text(attempt),
            .number(
              db.clock.unixSeconds + ExecutionLimits.bindingContinuationSeconds),
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
        "SELECT a.admission_json FROM bindings b JOIN attempts a ON a.id=b.attempt WHERE b.expires_at_epoch>\(db.clock.unixSeconds) AND b.principal=? AND b.object_type=? AND b.raw_id=?"
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
      let outputSample = try db.transaction {
        () -> (
          rate: Decimal?, second: Int64, rowID: Int64, days: [(Int64, Int64, Decimal)]?,
          hours: [(Int64, Int64, Decimal)]?
        )? in
        let snapshot = try Self.load(db, attempt)
        if snapshot.state == .intent {
          try Self.recordAccountConcurrency(db, owner: snapshot.admission.owner)
        }
        if let outcome {
          try Self.recordOutcome(db, snapshot: snapshot, outcome: outcome)
          try Self.finishQuotaPriming(
            db, snapshot.admission,
            result: outcome.failure?.rawValue
              ?? (evidence?.completeness == .complete ? "success" : "unknown"))
        }
        guard let evidence else {
          if snapshot.state == .intent {
            try db.write(
              "UPDATE attempts SET state='unknown',unknown_since_epoch=COALESCE(unknown_since_epoch,?) WHERE id=?",
              [.number(db.clock.unixSeconds), .text(attempt)])
          }
          return nil
        }
        let existing = try db.rows(
          "SELECT payload FROM evidence WHERE attempt=? AND revision=?",
          [.text(attempt), .number(evidence.revision)]
        ) { String(cString: sqlite3_column_text($0, 0)) }
        if let existing = existing.first {
          guard try decode(UsageEvidence.self, existing) == evidence else {
            throw ExecutionError.conflict
          }
          return nil
        }
        let floor = try db.scalar(
          "SELECT evidence_floor FROM attempts WHERE id=?", [.text(attempt)])
        guard evidence.revision > floor else { throw ExecutionError.staleEvidence }
        if let old = snapshot.usage, evidence.revision > old.revision {
          guard evidence.isAtLeast(old)
          else { throw ExecutionError.conflict }
        }
        if let old = snapshot.usage, evidence.revision < old.revision {
          guard old.isAtLeast(evidence)
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
              .number(evidence.estimatedMicros), .number(db.clock.unixSeconds),
              .text(evidence.completeness.rawValue), .text(attempt),
            ])
          if evidence.images > 0, snapshot.usage?.completeness == .complete {
            let recordedAt = try db.scalar(
              "SELECT COALESCE(output_rate_settled_at,-1) FROM attempts WHERE id=?",
              [.text(attempt)])
            try db.write(
              "UPDATE attempts SET output_rate_settled_at=NULL,output_rate=NULL WHERE id=?",
              [.text(attempt)])
            let rowID = try db.scalar("SELECT rowid FROM attempts WHERE id=?", [.text(attempt)])
            if recordedAt < 0 { return nil }
            let day = try db.businessDay.start(containing: recordedAt)
            let hour = recordedAt / 3600 * 3600
            let days = try Self.outputSamples(
              db, from: day, width: 86400, limit: OverviewActivity.outputDayCapacity)
            let hours = try Self.outputSamples(
              db, from: hour, width: 3600, limit: OverviewActivity.outputHourCapacity)
            return (nil, recordedAt, rowID, days, hours)
          }
          if snapshot.usage?.completeness != .complete, evidence.images == 0,
            snapshot.admission.executionRequirements.route == .conversation,
            evidence.completeness == .complete, evidence.outputTokens > 0
          {
            let duration =
              try outcome?.totalMilliseconds
              ?? db.scalar(
                "SELECT COALESCE(json_extract(outcome_json,'$.totalMilliseconds'),0) FROM attempts WHERE id=?",
                [.text(attempt)])
            if duration > 0 {
              let second = db.clock.unixSeconds
              let rate = Decimal(evidence.outputTokens) * 1000 / Decimal(duration)
              try db.write(
                "UPDATE attempts SET output_rate_settled_at=?,output_rate=? WHERE id=?",
                [
                  .number(second), .text(NSDecimalNumber(decimal: rate).stringValue),
                  .text(attempt),
                ])
              let rowID = try db.scalar("SELECT rowid FROM attempts WHERE id=?", [.text(attempt)])
              return (rate, second, rowID, nil, nil)
            }
          }
        }
        return nil
      }
      if let outputSample {
        if let rate = outputSample.rate {
          self.overviewActivity.recordRequestOutput(
            rate, at: outputSample.second, rowID: outputSample.rowID)
        } else if outputSample.second >= 0 {
          let day = try db.businessDay.start(containing: outputSample.second)
          let hour = outputSample.second / 3600 * 3600
          self.overviewActivity.replaceRequestOutput(
            day: day, days: outputSample.days ?? [], hour: hour, hours: outputSample.hours ?? [])
        }
      }
      self.overviewActivity.publish { .finished(id: attempt) }
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
  try value.validate()
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
          [.number(db.clock.unixSeconds - 30 * 86400)])
      }
    }
  }
}

extension SQLiteExecutionStore: ExecutionLiveObserving {
  public func executionStarted(attempt: String) {
    liveFirstEvents.withLock { if $0.count < 200 { $0[attempt] = false } }
  }
  public func executionReceivedFirstEvent(attempt: String) {
    let first = liveFirstEvents.withLock { values in
      guard values[attempt] == false else { return false }
      values[attempt] = true
      return true
    }
    guard first else { return }
    overviewActivity.publish {
      .firstEvent(id: attempt)
    }
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
          automatic: false, now: db.clock.unixSeconds)
        return count
      }
    }
  }
}
