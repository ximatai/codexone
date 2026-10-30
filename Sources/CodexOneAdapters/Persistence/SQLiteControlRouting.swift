import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore {
  public func selectControlAccount(
    key: ManagedKey, candidates: [AccountRouteCandidate], preferred: AccountRouteIdentity?
  ) async throws -> AccountRouteIdentity {
    guard (1...64).contains(candidates.count) else { throw AccountDispatchError.unavailable }
    return try await perform { db in
      // Recheck revocation without creating an execution or consuming any Key quota.
      let currentKey = try Self.loadKey(db, key.id)
      guard currentKey.enabled, currentKey.revision == key.revision else {
        throw ExecutionError.unauthorized
      }
      var ranked: [(AccountRouteIdentity, Int64)] = []
      for candidate in candidates {
        let account = try Self.loadAccount(db, candidate.identity.id).account
        guard account.namespace == candidate.identity.namespace,
          account.revision == candidate.snapshot.revision,
          account.credentialVersion == candidate.snapshot.credentialVersion,
          account.authorization == .ready, account.mode == .enabled,
          candidate.snapshot.accessExpiresAtUnixSeconds > Int64(Date().timeIntervalSince1970)
        else { continue }
        let health = try Self.loadHealth(db, account: account)
        guard !health.authenticationRejected, health.cooldowns.isEmpty else { continue }
        let active = try db.scalar(
          "SELECT COUNT(*) FROM attempts WHERE identity=? AND namespace=? AND state='intent'",
          [.text(account.id), .text(account.namespace)])
        ranked.append((candidate.identity, active))
      }
      ranked.sort {
        if ($0.0 == preferred) != ($1.0 == preferred) { return $0.0 == preferred }
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        return $0.0.id < $1.0.id
      }
      guard let selected = ranked.first else { throw AccountDispatchError.unavailable }
      return selected.0
    }
  }

  public func recordControlOutcome(account: AccountRouteCandidate, outcome: ExecutionOutcome)
    async throws
  {
    try outcome.validate()
    try await perform(essential: true) { db in
      try db.transaction {
        let current = try Self.loadAccount(db, account.identity.id).account
        guard current.namespace == account.identity.namespace,
          current.credentialVersion == account.snapshot.credentialVersion
        else { return }
        // Auxiliary endpoints are account-wide; apply cooldown to every configured model.
        let models = try db.rows("SELECT model FROM health_models") {
          String(cString: sqlite3_column_text($0, 0))
        }
        try Self.applyAccountFailure(db, account: current, model: nil, outcome: outcome)
        for model in models {
          try Self.applyAccountFailure(db, account: current, model: model, outcome: outcome)
        }
      }
    }
  }
}
