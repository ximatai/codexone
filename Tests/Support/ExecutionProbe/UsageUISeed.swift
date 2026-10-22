import CodexOneAdapters
import CodexOneCore
import Foundation

extension ExecutionProbe {
  /// Query/UI dataset only. Actual data-plane collection has independent real-socket coverage.
  static func seedUsageUI(_ store: SQLiteExecutionStore) async throws {
    try await store.configureHealthModels(["synthetic-text"])
    let limits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 100)
    for (key, digest) in [("synthetic-alpha", "a"), ("synthetic-beta", "b")] {
      _ = try await store.createKey(
        id: key, principal: key, digest: String(repeating: digest, count: 64),
        policy: .init(models: ["synthetic-text"], limits: limits))
      for index in 0..<(key == "synthetic-alpha" ? 60 : 1) {
        let id = key + "-" + String(format: "%02d", index)
        try await store.admit(
          .init(
            attempt: id,
            owner: .init(
              principal: key, key: key, namespace: "synthetic", identity: "synthetic-account"),
            window: "synthetic-ui", policyVersion: "1", pricingVersion: "1", reservedMicros: 1,
            requestID: "request-" + id,
            mode: index == 4 ? .compact : index == 5 ? .warmup : .generation,
            keyRevision: 1, model: "synthetic-text"))
        let evidence: UsageEvidence? =
          index == 2
          ? nil
          : .init(
            revision: 1,
            inputTokens: index == 0 ? 1_000_000_000_000 : 3, outputTokens: 1, cachedTokens: 0,
            images: 0, estimatedMicros: 0, completeness: index == 1 ? .partial : .complete)
        try await store.finalize(
          attempt: id, evidence: evidence,
          outcome: .init(
            failure: index == 2 ? .clientCancelled : index == 3 ? .upstreamRejected : nil,
            atUnixSeconds: Int64(Date().timeIntervalSince1970)))
      }
    }
    try await store.recordRejection(
      requestID: "synthetic-rejection", keyID: "synthetic-alpha", model: "synthetic-text",
      mode: .generation, failure: .objectUnavailable)
  }
}
