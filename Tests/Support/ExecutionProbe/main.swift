import CodexOneAdapters
import CodexOneCore
import Foundation

/// Credential-free subprocess harness, never part of the gateway's public command surface.
@main struct ExecutionProbe {
  static func main() async {
    do {
      guard CommandLine.arguments.count == 2 else { throw ExecutionError.invalidCommand }
      let store = try await SQLiteExecutionStore.open(
        path: CommandLine.arguments[1],
        limits: .init(
          requests: 100, active: 4, unresolved: 4, budgetMicros: 100))
      emit("ready")
      var accountRefresh: AccountRefreshWork?
      while let command = readLine() {
        switch command {
        case "admit":
          try await store.admit(
            .init(
              attempt: "attempt",
              owner: .init(principal: "p", key: "k", namespace: "synthetic", identity: "i"),
              window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 100))
          emit("admitted")
        case "bind":
          try await store.bind(
            attempt: "attempt", object: .init(type: "response", rawID: "response1"))
          emit("bound")
        case "finalize":
          try await store.finalize(
            attempt: "attempt",
            evidence: .init(
              revision: 1,
              inputTokens: 10, outputTokens: 5, cachedTokens: 0, images: 0, estimatedMicros: 30,
              completeness: .complete))
          emit("settled")
        case "snapshot":
          do {
            emit(try await store.snapshot(attempt: "attempt").state.rawValue)
          } catch ExecutionError.unknownAttempt { emit("absent") }
        case "resolve":
          do {
            _ = try await store.resolve(
              principal: "p", object: .init(type: "response", rawID: "response1"))
            emit("owned")
          } catch ExecutionError.unknownObject { emit("absent") }
        case "capacity":
          do {
            try await store.admit(
              .init(
                attempt: "new",
                owner: .init(principal: "p", key: "k", namespace: "synthetic", identity: "i"),
                window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 1))
            emit("accepted")
          } catch ExecutionError.denied { emit("denied") }
        case "account-create":
          let app = try await accountApplication(store)
          _ = try await app.importVerified(
            id: "account", namespace: "synthetic/account",
            credential: syntheticAccountCredential(version: 1))
          emit("account_created")
        case "account-enable":
          let old = try await store.accountCredential(id: "account").account
          _ = try await store.setAccountMode(id: old.id, revision: old.revision, mode: .enabled)
          emit("account_enabled")
        case "account-refresh":
          let app = try await accountApplication(store)
          let old = try await store.accountCredential(id: "account").account
          do {
            accountRefresh = try await app.beginRefresh(id: old.id, revision: old.revision)
            emit("refresh_started")
          } catch ExecutionError.conflict { emit("refresh_denied") }
        case "account-commit":
          guard let work = accountRefresh else { throw ExecutionError.invalidCommand }
          let app = try await accountApplication(store)
          _ = try await app.finishVerifiedRefresh(
            work, namespace: "synthetic/account", credential: syntheticAccountCredential(version: 2)
          )
          emit("refresh_committed")
        case "account-state":
          let account = try await store.accountCredential(id: "account").account
          emit(
            account.authorization.rawValue + ":" + String(account.credentialVersion) + ":"
              + account.mode.rawValue)
        case "close":
          await store.close()
          emit("closed")
          return
        default: throw ExecutionError.invalidCommand
        }
      }
      await store.close()
    } catch {
      // No path, SQL, user payload or raw framework error is printed.
      emit("probe_failed")
      exit(1)
    }
  }
  static func accountApplication(_ store: SQLiteExecutionStore) async throws -> AccountCredentials {
    guard let path = ProcessInfo.processInfo.environment["CODEXONE_PROBE_KEY_FILE"] else {
      throw ExecutionError.invalidCommand
    }
    let protection = try await AccountCredentialCipher.load(path: path)
    return AccountCredentials(store: store, protection: protection)
  }
  static func syntheticAccountCredential(version: Int) throws -> AccountCredential {
    try AccountCredential(
      accessToken: "synthetic-access-" + String(version),
      refreshToken: "synthetic-refresh-" + String(version), idToken: nil,
      expiresAtUnixSeconds: 2_000_000_000)
  }
  static func emit(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
}
