import CodexOneCore
import Foundation

extension SQLiteExecutionStore: ExecutionDiagnosticsStore {
  public func recordRejection(
    requestID: String, keyID: String, model: String?, mode: ExecutionMode, failure: ExecutionFailure
  ) async throws {
    guard
      [requestID, keyID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }
      ),
      model.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true
    else { throw ExecutionError.invalidCommand }
    let now = Int64(Date().timeIntervalSince1970)
    try await perform(optional: true) { db in
      try db.transaction {
        // A committed intent already owns its outcome, including cancellation between
        // commit and invocation. Never mislabel that attempt as a pre-dispatch refusal.
        guard
          try db.scalar("SELECT COUNT(*) FROM attempts WHERE request_id=?", [.text(requestID)]) == 0
        else { return }
        try db.write(
          "DELETE FROM request_diagnostics WHERE at_epoch<?", [.number(now - 30 * 86400)])
        if try db.scalar("SELECT COUNT(*) FROM request_diagnostics") >= 10_000 {
          try db.write(
            "DELETE FROM request_diagnostics WHERE request_id IN (SELECT request_id FROM request_diagnostics ORDER BY at_epoch,request_id LIMIT 100)"
          )
        }
        try db.write(
          "INSERT OR IGNORE INTO request_diagnostics VALUES(?,?,?,?,?,?)",
          [
            .text(requestID), .number(now), .text(keyID), model.map { .text($0) } ?? .null,
            .text(mode.rawValue), .text(failure.rawValue),
          ])
      }
    }
  }
}
