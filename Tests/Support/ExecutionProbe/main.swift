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
  static func emit(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
}
