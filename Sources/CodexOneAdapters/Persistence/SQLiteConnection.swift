import CSQLite
import CodexOneCore
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// All access is confined to SQLiteExecutionStore's serial queue.
final class SQLiteConnection: @unchecked Sendable {
  private(set) var handle: OpaquePointer?
  private var lockFD: Int32 = -1
  private var readOnly = false
  let clock: WallClock
  let filePath: String
  enum Value: Sendable {
    case text(String)
    case number(Int64)
    case null
  }

  init(
    path: String, migrating: Bool = false, existingOnly: Bool = false, restoringV7: Bool = false,
    clock: WallClock = .system
  )
    throws
  {
    self.clock = clock
    filePath = path
    guard path != ":memory:", !path.utf8.contains(0) else { throw ExecutionError.invalidCommand }
    let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    lockFD = try Self.secureFile(canonical + ".lock", create: true)
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      close(lockFD)
      lockFD = -1
      throw ExecutionError.instanceLocked
    }
    do {
      if FileManager.default.fileExists(atPath: canonical + ".restore-pending") {
        throw SnapshotMaintenanceError.incompleteRestore
      }
      // Existing data must pass compatibility checks before changing journal mode or schema.
      let file = try Self.secureFile(canonical, create: !migrating && !existingOnly)
      guard file >= 0 else { throw ExecutionError.storageUnavailable }
      close(file)
      // Existing WAL/SHM can predate a tightened main-file mode.
      for suffix in ["-wal", "-shm"] {
        let sidecar = try Self.secureFile(canonical + suffix, create: false)
        if sidecar >= 0 { close(sidecar) }
      }
      guard
        sqlite3_open_v2(
          canonical, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
          == SQLITE_OK
      else {
        throw ExecutionError.storageUnavailable
      }
      guard sqlite3_busy_timeout(handle, 250) == SQLITE_OK else {
        throw ExecutionError.storageUnavailable
      }
      try exec("PRAGMA foreign_keys=ON")
      guard try scalar("PRAGMA foreign_keys") == 1 else { throw ExecutionError.storageUnavailable }
      let version = try scalar("PRAGMA user_version")
      guard
        version == 0 || version == 10 || (restoringV7 && [7, 8, 9].contains(version))
          || (migrating && (1...9).contains(version))
      else {
        throw ExecutionError.incompatibleSchema
      }
      if existingOnly && version != 10 && !(restoringV7 && [7, 8, 9].contains(version)) {
        throw ExecutionError.incompatibleSchema
      }
      if version == 0 {
        guard try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'") == 0
        else {
          throw ExecutionError.incompatibleSchema
        }
      } else {
        let expectedTables =
          Self.columns.map { table, columns in
            (
              table,
              columns
                + (version >= 5 && table == "attempts"
                  ? ["created_at_epoch", "outcome_json", "request_id"] : [])
                + (version >= 10 && table == "attempts"
                  ? ["unknown_since_epoch", "closed_unknown_at_epoch"] : [])
                + (version >= 10 && table == "bindings" ? ["expires_at_epoch"] : [])
            )
          } + (version >= 2 ? Self.keyColumns : [])
          + (version >= 3
            ? Self.accountColumns.map { table, columns in
              (table, columns + (version >= 9 && table == "accounts" ? ["display_name"] : []))
            } : [])
          + (version >= 5 ? Self.observationColumns : [])
          + (version >= 7 ? Self.maintenanceColumns : [])
          + (version >= 10 ? Self.governanceColumns : [])
        for (table, expected) in expectedTables {
          let actual = try rows("PRAGMA table_info(\(table))") {
            String(cString: sqlite3_column_text($0, 1))
          }
          guard actual == expected else { throw ExecutionError.incompatibleSchema }
        }
      }
      if migrating, !(1...10).contains(version) {
        throw ExecutionError.incompatibleSchema
      }
      guard try scalar("PRAGMA busy_timeout") == 250 else {
        throw ExecutionError.storageUnavailable
      }
      if version == 0 { try exec("PRAGMA auto_vacuum=INCREMENTAL") }
      let journal = try rows("PRAGMA journal_mode=WAL") {
        String(cString: sqlite3_column_text($0, 0))
      }
      guard journal == ["wal"] else { throw ExecutionError.storageUnavailable }
      try exec("PRAGMA synchronous=FULL")
      guard try scalar("PRAGMA synchronous") == 2 else { throw ExecutionError.storageUnavailable }
      if version == 0 {
        try transaction {
          try exec(Self.schema)
          try exec(Self.keySchema)
          try exec(Self.accountSchema)
          try exec(Self.observationSchema)
          try exec(Self.maintenanceSchema)
          if version < 9 {
            try exec("ALTER TABLE accounts ADD COLUMN display_name TEXT")
            try exec(
              "CREATE INDEX attempts_in_flight ON attempts(created_at_epoch DESC,id DESC) WHERE state='intent'"
            )
          }
          try exec(Self.governanceSchema(now: clock.unixSeconds))
          try exec("PRAGMA user_version=10")
        }
      }
      if (1...9).contains(version) {
        guard
          try rows("PRAGMA quick_check", map: { String(cString: sqlite3_column_text($0, 0)) }) == [
            "ok"
          ]
        else { throw ExecutionError.storageUnavailable }
        if !restoringV7 { try backupBeforeUpgrade(canonical) }
        try StorageCapacity.require(
          (canonical as NSString).deletingLastPathComponent,
          additionalBytes: scalar("PRAGMA page_count") * scalar("PRAGMA page_size") * 2 + 8 * 1024
            * 1024, optional: true)
        if try scalar("PRAGMA auto_vacuum") != 2 {
          try exec("PRAGMA auto_vacuum=INCREMENTAL")
          try exec("VACUUM")
        }
        try transaction {
          if version == 1 { try exec(Self.keySchema) }
          if version < 3 { try exec(Self.accountSchema) }
          if version < 5 { try exec(Self.observationSchema) }
          if version < 7 { try exec(Self.maintenanceSchema) }
          if version < 9 {
            try exec("ALTER TABLE accounts ADD COLUMN display_name TEXT")
            try exec(
              "CREATE INDEX attempts_in_flight ON attempts(created_at_epoch DESC,id DESC) WHERE state='intent'"
            )
          }
          try exec(Self.governanceSchema(now: clock.unixSeconds))
          try exec("PRAGMA user_version=10")
        }
      }
      guard try scalar("PRAGMA auto_vacuum") == 2 else { throw ExecutionError.storageUnavailable }
      guard
        try rows("PRAGMA quick_check", map: { String(cString: sqlite3_column_text($0, 0)) }) == [
          "ok"
        ]
      else {
        throw ExecutionError.storageUnavailable
      }
    } catch {
      shutdown()
      throw error
    }
  }

  /// The already locked primary store owns this one read-only WAL connection.
  init(readOnlyPath: String, clock: WallClock = .system) throws {
    self.clock = clock
    readOnly = true
    filePath = readOnlyPath
    guard let resolved = readOnlyPath.withCString({ realpath($0, nil) }) else {
      throw ExecutionError.storageUnavailable
    }
    let canonical = String(cString: resolved)
    free(resolved)
    guard
      sqlite3_open_v2(
        canonical, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        == SQLITE_OK
    else {
      shutdown()
      throw ExecutionError.storageUnavailable
    }
    do {
      guard sqlite3_busy_timeout(handle, 50) == SQLITE_OK else {
        throw ExecutionError.storageUnavailable
      }
      try exec("PRAGMA query_only=ON")
      guard [7, 8, 9, 10].contains(try scalar("PRAGMA user_version")),
        try scalar("PRAGMA query_only") == 1
      else {
        throw ExecutionError.incompatibleSchema
      }
    } catch {
      shutdown()
      throw error
    }
  }

  deinit { shutdown() }
  private static func secureFile(_ path: String, create: Bool) throws -> Int32 {
    let descriptor = open(
      path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0), mode_t(0o600))
    if descriptor < 0 {
      if !create && errno == ENOENT { return -1 }
      throw ExecutionError.storageUnavailable
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, fchmod(descriptor, mode_t(0o600)) == 0
    else {
      close(descriptor)
      throw ExecutionError.storageUnavailable
    }
    return descriptor
  }
  func shutdown() {
    if let handle {
      sqlite3_close_v2(handle)
      self.handle = nil
    }
    if lockFD >= 0 {
      flock(lockFD, LOCK_UN)
      close(lockFD)
      lockFD = -1
    }
  }
  func exec(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw ExecutionError.storageUnavailable
    }
  }
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try exec("COMMIT")
      return value
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }
  func rows<T>(_ sql: String, _ values: [Value] = [], map: (OpaquePointer) throws -> T) throws
    -> [T]
  {
    guard let handle else { throw ExecutionError.closed }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw ExecutionError.storageUnavailable
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      let result: Int32
      switch value {
      case .text(let text):
        result = text.withCString {
          sqlite3_bind_text(
            statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)
          )
        }
      case .number(let number): result = sqlite3_bind_int64(statement, Int32(index + 1), number)
      case .null: result = sqlite3_bind_null(statement, Int32(index + 1))
      }
      guard result == SQLITE_OK else { throw ExecutionError.storageUnavailable }
    }
    var result: [T] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: result.append(try map(statement))
      case SQLITE_DONE: return result
      case SQLITE_INTERRUPT where readOnly: throw ExecutionError.capacity
      default: throw ExecutionError.storageUnavailable
      }
    }
  }
  func write(_ sql: String, _ values: [Value] = []) throws {
    let _: [Int] = try rows(sql, values) { _ in 0 }
  }
  func scalar(_ sql: String, _ values: [Value] = []) throws -> Int64 {
    guard let result = try rows(sql, values, map: { sqlite3_column_int64($0, 0) }).first else {
      throw ExecutionError.storageUnavailable
    }
    return result
  }
  static let schema = """
    CREATE TABLE attempts (
      id TEXT PRIMARY KEY, principal TEXT NOT NULL, key_id TEXT NOT NULL,
      namespace TEXT NOT NULL, identity TEXT NOT NULL, window_id TEXT NOT NULL,
      policy_version TEXT NOT NULL, pricing_version TEXT NOT NULL,
      reserved INTEGER NOT NULL CHECK(reserved>=0),
      state TEXT NOT NULL CHECK(state IN ('intent','unknown','settled')),
      admission_json TEXT NOT NULL, usage_json TEXT, evidence_floor INTEGER NOT NULL DEFAULT -1,
      estimated INTEGER NOT NULL DEFAULT 0 CHECK(estimated>=0)
    );
    CREATE INDEX attempts_principal ON attempts(principal,window_id);
    CREATE INDEX attempts_identity ON attempts(namespace,identity,window_id);
    CREATE INDEX attempts_window ON attempts(window_id);
    CREATE TABLE bindings (
      principal TEXT NOT NULL, namespace TEXT NOT NULL, identity TEXT NOT NULL,
      object_type TEXT NOT NULL, raw_id TEXT NOT NULL,
      attempt TEXT NOT NULL REFERENCES attempts(id),
      PRIMARY KEY(principal,namespace,identity,object_type,raw_id)
    );
    CREATE INDEX bindings_lookup ON bindings(principal,object_type,raw_id);
    CREATE TABLE evidence (
      attempt TEXT NOT NULL REFERENCES attempts(id),
      revision INTEGER NOT NULL CHECK(revision>=0), payload TEXT NOT NULL,
      PRIMARY KEY(attempt,revision)
    );
    CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK(id=1), limits_json TEXT NOT NULL);
    """

  static let keySchema = """
    CREATE TABLE managed_keys (id TEXT PRIMARY KEY, digest TEXT NOT NULL UNIQUE, metadata_json TEXT NOT NULL);
    CREATE TABLE key_events (id TEXT PRIMARY KEY, key_id TEXT NOT NULL REFERENCES managed_keys(id),
      revision INTEGER NOT NULL, action TEXT NOT NULL, at_epoch INTEGER NOT NULL, metadata_json TEXT NOT NULL);
    CREATE INDEX attempts_key ON attempts(key_id,window_id);
    """
  private static let keyColumns: [(String, [String])] = [
    ("managed_keys", ["id", "digest", "metadata_json"]),
    ("key_events", ["id", "key_id", "revision", "action", "at_epoch", "metadata_json"]),
  ]

  static let accountSchema = """
    CREATE TABLE accounts (id TEXT PRIMARY KEY, namespace TEXT NOT NULL UNIQUE,
      revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 1000000),
      credential_version INTEGER NOT NULL CHECK(credential_version BETWEEN 1 AND 1000000),
      mode TEXT NOT NULL CHECK(mode IN ('enabled','draining','disabled')),
      authorization TEXT NOT NULL CHECK(authorization IN ('ready','refreshing','requires_auth','auth_uncertain')),
      sealed_credential TEXT NOT NULL, refresh_intent TEXT, created_at_epoch INTEGER NOT NULL);
    CREATE TABLE account_events (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
      revision INTEGER NOT NULL, action TEXT NOT NULL, metadata_json TEXT NOT NULL, at_epoch INTEGER NOT NULL);
    """
  private static let accountColumns: [(String, [String])] = [
    (
      "accounts",
      [
        "id", "namespace", "revision", "credential_version", "mode", "authorization",
        "sealed_credential", "refresh_intent", "created_at_epoch",
      ]
    ),
    ("account_events", ["id", "account_id", "revision", "action", "metadata_json", "at_epoch"]),
  ]

  static let observationSchema = """
    ALTER TABLE attempts ADD COLUMN created_at_epoch INTEGER;
    ALTER TABLE attempts ADD COLUMN outcome_json TEXT;
    ALTER TABLE attempts ADD COLUMN request_id TEXT;
    CREATE INDEX attempts_request ON attempts(request_id);
    CREATE INDEX attempts_created ON attempts(created_at_epoch,key_id);
    CREATE TABLE account_quota (account_id TEXT PRIMARY KEY REFERENCES accounts(id), record_json TEXT NOT NULL CHECK(length(record_json)<=16384));
    CREATE TABLE account_health (account_id TEXT PRIMARY KEY REFERENCES accounts(id),
      auth_rejected_version INTEGER, last_failure TEXT NOT NULL, at_epoch INTEGER NOT NULL);
    CREATE TABLE health_models (model TEXT PRIMARY KEY);
    CREATE TABLE account_model_health (account_id TEXT NOT NULL REFERENCES accounts(id),
      model TEXT NOT NULL REFERENCES health_models(model) ON DELETE CASCADE,
      until_epoch INTEGER NOT NULL, failure TEXT NOT NULL, PRIMARY KEY(account_id,model));
    CREATE TABLE request_diagnostics (request_id TEXT PRIMARY KEY, at_epoch INTEGER NOT NULL,
      key_id TEXT NOT NULL, model TEXT, mode TEXT NOT NULL, failure TEXT NOT NULL);
    CREATE INDEX diagnostics_created ON request_diagnostics(at_epoch,request_id);
    """
  private static let observationColumns: [(String, [String])] = [
    ("account_quota", ["account_id", "record_json"]),
    ("account_health", ["account_id", "auth_rejected_version", "last_failure", "at_epoch"]),
    ("health_models", ["model"]),
    ("account_model_health", ["account_id", "model", "until_epoch", "failure"]),
    ("request_diagnostics", ["request_id", "at_epoch", "key_id", "model", "mode", "failure"]),
  ]

  static let maintenanceSchema = """
    CREATE TABLE maintenance_state (id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT NOT NULL, restore_json TEXT);
    INSERT INTO maintenance_state VALUES(1, lower(hex(randomblob(16))), NULL);
    CREATE TABLE maintenance_events (id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT NOT NULL, record_json TEXT NOT NULL, at_epoch INTEGER NOT NULL);
    """
  private static let maintenanceColumns: [(String, [String])] = [
    ("maintenance_state", ["id", "generation", "restore_json"]),
    ("maintenance_events", ["id", "action", "record_json", "at_epoch"]),
  ]

  static func governanceSchema(now: Int64) -> String {
    """
    ALTER TABLE attempts ADD COLUMN unknown_since_epoch INTEGER;
    ALTER TABLE attempts ADD COLUMN closed_unknown_at_epoch INTEGER;
    UPDATE attempts SET unknown_since_epoch=COALESCE(json_extract(outcome_json,'$.atUnixSeconds'),created_at_epoch,\(now)) WHERE state='unknown';
    UPDATE attempts SET closed_unknown_at_epoch=COALESCE(created_at_epoch,\(now)) WHERE state='settled' AND COALESCE(json_extract(usage_json,'$.completeness'),'')!='complete';
    ALTER TABLE bindings ADD COLUMN expires_at_epoch INTEGER;
    UPDATE bindings SET expires_at_epoch=\(now)+\(ExecutionLimits.bindingContinuationSeconds);
    CREATE INDEX bindings_expiry ON bindings(expires_at_epoch);
    CREATE INDEX attempts_active_identity ON attempts(namespace,identity) WHERE state='intent';
    CREATE INDEX attempts_retention ON attempts(created_at_epoch,id) WHERE state='settled';
    CREATE INDEX attempts_unknown_since ON attempts(unknown_since_epoch,id) WHERE state='unknown';
    CREATE TABLE account_concurrency(namespace TEXT NOT NULL,identity TEXT NOT NULL,at_epoch INTEGER NOT NULL,peak INTEGER NOT NULL,PRIMARY KEY(namespace,identity,at_epoch));
    CREATE TABLE usage_daily(
      day_epoch INTEGER NOT NULL,key_id TEXT NOT NULL,model TEXT NOT NULL,mode TEXT NOT NULL,
      outcome TEXT NOT NULL,failure TEXT NOT NULL,completeness TEXT NOT NULL,usage_unknown INTEGER NOT NULL,
      requests INTEGER NOT NULL,last_used_epoch INTEGER NOT NULL,
      input_tokens INTEGER,output_tokens INTEGER,cached_tokens INTEGER,images INTEGER,estimated_micros INTEGER,
      image_input_tokens INTEGER,image_output_tokens INTEGER,image_input_text_tokens INTEGER,image_input_image_tokens INTEGER,
      PRIMARY KEY(day_epoch,key_id,model,mode,outcome,failure,completeness,usage_unknown));
    CREATE INDEX usage_daily_key ON usage_daily(key_id,last_used_epoch);
    """
  }
  private static let governanceColumns: [(String, [String])] = [
    ("account_concurrency", ["namespace", "identity", "at_epoch", "peak"]),
    (
      "usage_daily",
      [
        "day_epoch", "key_id", "model", "mode", "outcome", "failure", "completeness",
        "usage_unknown", "requests", "last_used_epoch", "input_tokens", "output_tokens",
        "cached_tokens", "images", "estimated_micros", "image_input_tokens", "image_output_tokens",
        "image_input_text_tokens", "image_input_image_tokens",
      ]
    ),
  ]

  private func backupBeforeUpgrade(_ path: String) throws {
    try StorageCapacity.require(
      (path as NSString).deletingLastPathComponent,
      additionalBytes: scalar("PRAGMA page_count") * scalar("PRAGMA page_size") + 8 * 1024 * 1024,
      optional: true)
    let destination = path + ".pre-v10-" + UUID().uuidString + ".sqlite"
    let partial = destination + ".partial"
    let fd = open(partial, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw ExecutionError.storageUnavailable }
    defer { close(fd) }
    var target: OpaquePointer?
    guard
      sqlite3_open_v2(partial, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK
    else {
      if let target { sqlite3_close_v2(target) }
      throw ExecutionError.storageUnavailable
    }
    defer { if let target { sqlite3_close_v2(target) } }
    guard let copy = sqlite3_backup_init(target, "main", handle, "main") else {
      throw ExecutionError.storageUnavailable
    }
    var finished = false
    defer { if !finished { sqlite3_backup_finish(copy) } }
    var step: Int32
    repeat {
      try StorageCapacity.require(
        (path as NSString).deletingLastPathComponent, additionalBytes: 2 * 1024 * 1024,
        optional: true)
      step = sqlite3_backup_step(copy, 128)
    } while step == SQLITE_OK
    let finish = sqlite3_backup_finish(copy)
    finished = true
    guard step == SQLITE_DONE, finish == SQLITE_OK else {
      throw ExecutionError.storageUnavailable
    }
    // Publish a self-contained file that can be opened read-only without WAL sidecars.
    guard sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
      throw ExecutionError.storageUnavailable
    }
    guard sqlite3_close(target) == SQLITE_OK else { throw ExecutionError.storageUnavailable }
    target = nil
    for suffix in ["-wal", "-shm"] {
      guard unlink(partial + suffix) == 0 || errno == ENOENT else {
        throw ExecutionError.storageUnavailable
      }
    }
    guard fsync(fd) == 0 else { throw ExecutionError.storageUnavailable }
    guard rename(partial, destination) == 0 else { throw ExecutionError.storageUnavailable }
    let parent = open((destination as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)
    guard parent >= 0 else { throw ExecutionError.storageUnavailable }
    defer { close(parent) }
    guard fsync(parent) == 0 else { throw ExecutionError.storageUnavailable }
  }

  private static let columns: [(String, [String])] = [
    (
      "attempts",
      [
        "id", "principal", "key_id", "namespace", "identity", "window_id", "policy_version",
        "pricing_version", "reserved", "state", "admission_json", "usage_json", "evidence_floor",
        "estimated",
      ]
    ),
    ("bindings", ["principal", "namespace", "identity", "object_type", "raw_id", "attempt"]),
    ("evidence", ["attempt", "revision", "payload"]),
    ("metadata", ["id", "limits_json"]),
  ]
}
