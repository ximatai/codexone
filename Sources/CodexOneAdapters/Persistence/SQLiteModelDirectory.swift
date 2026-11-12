import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore {
  static func modelDirectoryRevision(_ db: SQLiteConnection) throws -> Int64 {
    try db.scalar("SELECT coalesce((SELECT revision FROM model_directory WHERE singleton=1),0)")
  }

  static func readModelDirectory(_ db: SQLiteConnection) throws -> ModelDirectorySnapshot? {
    try db.rows("SELECT document FROM model_directory WHERE singleton=1") { row in
      guard let raw = sqlite3_column_text(row, 0) else { throw ExecutionError.storageUnavailable }
      let decoder = JSONDecoder()
      decoder.userInfo[.persistedModelDirectory] = true
      return try decoder.decode(ModelDirectorySnapshot.self, from: Data(String(cString: raw).utf8))
    }.first
  }

  func modelDirectorySnapshot() async throws -> ModelDirectorySnapshot? {
    try await perform { try Self.readModelDirectory($0) }
  }

  func replaceModelDirectory(
    _ snapshot: ModelDirectorySnapshot, expected: Int64, imageModels: [String],
    expectedAccount: (id: String, revision: Int64)?
  ) async throws {
    let document = try JSONEncoder().encode(snapshot)
    guard document.count <= 4 * 1024 * 1024 else { throw ExecutionError.capacity }
    try await perform(optional: true) { db in
      try db.transaction {
        guard try Self.modelDirectoryRevision(db) == expected else {
          throw ExecutionError.conflict
        }
        if let expectedAccount {
          let account = try Self.loadAccount(db, expectedAccount.id).account
          guard account.revision == expectedAccount.revision, account.mode == .enabled,
            account.authorization == .ready
          else { throw ExecutionError.conflict }
        }
        try db.write(
          """
          INSERT INTO model_directory(singleton,revision,document) VALUES(1,?,?)
          ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,document=excluded.document
          """, [.number(snapshot.revision), .text(String(decoding: document, as: UTF8.self))])
        try Self.replaceHealthModels(db, Set(snapshot.active.map(\.id) + imageModels))
        try db.write("DELETE FROM model_directory_routes")
        for model in snapshot.active {
          let efforts = try model.reasoningSettings?.allowed.map {
            SQLiteConnection.Value.text(
              String(decoding: try JSONEncoder().encode($0), as: UTF8.self))
          }
          try db.write(
            "INSERT INTO model_directory_routes(model,account,reasoning_efforts) VALUES(?,?,?)",
            [
              .text(model.id),
              snapshot.accountForModel[model.id].map(SQLiteConnection.Value.text) ?? .null,
              efforts ?? .null,
            ])
        }
      }
    }
  }
}
