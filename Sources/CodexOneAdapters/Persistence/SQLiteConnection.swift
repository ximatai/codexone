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
  enum Value {
    case text(String)
    case number(Int64)
  }

  init(path: String) throws {
    guard path != ":memory:", !path.utf8.contains(0) else { throw ExecutionError.invalidCommand }
    let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    lockFD = try Self.secureFile(canonical + ".lock", create: true)
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      close(lockFD)
      lockFD = -1
      throw ExecutionError.instanceLocked
    }
    do {
      // Existing data must pass compatibility checks before changing journal mode or schema.
      let file = try Self.secureFile(canonical, create: true)
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
      guard version == 0 || version == 1 else { throw ExecutionError.incompatibleSchema }
      if version == 0 {
        guard try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'") == 0
        else {
          throw ExecutionError.incompatibleSchema
        }
      } else {
        for (table, expected) in Self.columns {
          let actual = try rows("PRAGMA table_info(\(table))") {
            String(cString: sqlite3_column_text($0, 1))
          }
          guard actual == expected else { throw ExecutionError.incompatibleSchema }
        }
      }
      guard try scalar("PRAGMA busy_timeout") == 250 else {
        throw ExecutionError.storageUnavailable
      }
      let journal = try rows("PRAGMA journal_mode=WAL") {
        String(cString: sqlite3_column_text($0, 0))
      }
      guard journal == ["wal"] else { throw ExecutionError.storageUnavailable }
      try exec("PRAGMA synchronous=FULL")
      guard try scalar("PRAGMA synchronous") == 2 else { throw ExecutionError.storageUnavailable }
      if version == 0 {
        try transaction {
          try exec(Self.schema)
          try exec("PRAGMA user_version=1")
        }
      }
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
      }
      guard result == SQLITE_OK else { throw ExecutionError.storageUnavailable }
    }
    var result: [T] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: result.append(try map(statement))
      case SQLITE_DONE: return result
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
