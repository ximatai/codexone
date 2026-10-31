import CodexOneCore
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

@Test func requestMetadataIsBoundedAndNeverRewritesProviderParameters() throws {
  let valid = [
    "none", "minimal", "low", "medium", "high", "xhigh", "auto", "priority", "a_1-b",
    String(repeating: "a", count: 32),
  ]
  let invalid: [JSONValue] = [
    .string("HIGH"), .string(""), .string("bad value"), .string(String(repeating: "a", count: 33)),
    .number(3), .bool(true), .null, .array([]), .object([:]),
  ]
  for value in valid.map({ JSONValue.string($0) }) + invalid {
    let input: JSONValue = .object([
      "model": .string("synthetic-text"), "input": .string("synthetic"),
      "reasoning": .object(["effort": value]), "service_tier": value,
    ])
    let request = try ResponseRequest(data: input.data())
    let expected = valid.contains(value.string ?? "") ? value.string : "other"
    #expect(request.reasoningEffort == expected)
    #expect(request.serviceTier == expected)
    // Null reasoning members follow the pre-existing omission rule; metadata adds no rewrite.
    #expect(request.document["reasoning"]?["effort"] == (value == .null ? nil : value))
    #expect(request.document["service_tier"] == value)
    let wire = try request.preparedDocument(contract: .responses, nativeWebSocket: false)
    #expect(wire == request.document)
  }
  let missing = try ResponseRequest(
    data: Data(#"{"model":"synthetic-text","input":"synthetic"}"#.utf8))
  #expect(missing.reasoningEffort == nil && missing.serviceTier == nil)
}

private final class MetadataFinalizer: FinalizationSink, Sendable {
  let result = Synchronization.Mutex<Finalization?>(nil)
  var isAccepting: Bool { true }
  func reserve() throws -> UUID { UUID() }
  func canExecute(_ ticket: UUID) -> Bool { true }
  func abandon(_ ticket: UUID) {}
  func handoff(_ ticket: UUID, finalization: Finalization) {
    result.withLock { $0 = finalization }
  }
}

@Test func terminalTierSurvivesCancellationAndDownstreamWriteFailure() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: .init(requests: 100, active: 8, unresolved: 8, budgetMicros: 1000))
  do {
    for (index, tier) in [nil, JSONValue.string("priority"), .string("INVALID"), .number(7)]
      .enumerated()
    {
      let finalizer = MetadataFinalizer()
      let coordinator = ExecutionCoordinator(store: store, finalizer: finalizer)
      let admission = ExecutionAdmission(
        attempt: "synthetic-tier-\(index)",
        owner: .init(
          principal: "synthetic", key: "synthetic", namespace: "synthetic", identity: "synthetic"),
        window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 1)
      await #expect(throws: GatewayProtocolError.self) {
        try await coordinator.execute(admission) { context in
          if index % 2 == 1 {
            try context.observeOutcome(.init(failure: .clientCancelled, atUnixSeconds: 1))
          }
          return try await observeExecution(context) {
            var response: [String: JSONValue] = ["id": .string("resp_synthetic")]
            response["service_tier"] = tier
            try observeTerminalOutcome(
              .object([
                "type": .string("response.completed"), "response": .object(response),
              ]), context: context)
            // Synthetic downstream write failure after a valid provider terminal.
            throw GatewayProtocolError(502, "downstream_write_failed")
          }
        }
      }
      let result = try #require(finalizer.result.withLock { $0 })
      #expect(result.outcome?.actualServiceTier == requestMetadataValue(tier))
      #expect(result.outcome?.failure == (index % 2 == 1 ? .clientCancelled : .indeterminate))
      try await store.finalize(attempt: admission.attempt, evidence: nil, outcome: result.outcome)
    }
  } catch {
    await store.close()
    throw error
  }
  await store.close()
}

@Test func providerTierIsReadOnlyFromTerminalEventsAndValidated() throws {
  let model = try JSONDecoder().decode(
    SingleIdentityConfiguration.Model.self,
    from: Data(
      #"{"id":"synthetic-text","inputMicrosPerMillion":0,"outputMicrosPerMillion":0}"#.utf8))
  for type in ["response.created", "response.completed", "response.failed", "response.incomplete"] {
    for value in [nil, JSONValue.string("priority"), .string("INVALID"), .number(3)] {
      var response: [String: JSONValue] = ["id": .string("resp_synthetic")]
      response["service_tier"] = value
      let observation = try ProviderObservation(
        event: .object([
          "type": .string(type), "response": .object(response),
        ]), model: model)
      #expect(
        observation.actualServiceTier
          == (type == "response.created" ? nil : requestMetadataValue(value)))
    }
  }
}
