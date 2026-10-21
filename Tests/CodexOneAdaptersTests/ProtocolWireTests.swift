import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func sseHandlesFragmentedUTF8AndCRLFWithoutTreatingEOFAsCompletion() throws {
  var decoder = SSEDecoder()
  let wire = Data(
    "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"合成文本\"}\r\n\r\n"
      .utf8)
  var events: [JSONValue] = []
  for byte in wire { if let event = try decoder.append(byte) { events.append(event) } }
  try #require(events.count == 1)
  #expect(events[0]["delta"]?.string == "合成文本")
  try decoder.finish()
  #expect(!decoder.sawDone)
  for byte in "data: [DONE]\n\n".utf8 { _ = try decoder.append(byte) }
  #expect(decoder.sawDone)
  #expect(throws: (any Error).self) {
    for byte in "data: {}\n\n".utf8 { _ = try decoder.append(byte) }
  }
}

@Test func incompleteAndOversizedEventsAreRejected() throws {
  var incomplete = SSEDecoder()
  for byte in "data: {\"type\":\"response.completed\"}".utf8 { _ = try incomplete.append(byte) }
  #expect(throws: (any Error).self) { try incomplete.finish() }
  var oversized = SSEDecoder()
  #expect(throws: (any Error).self) { for _ in 0..<262_149 { _ = try oversized.append(65) } }
}

@Test func deepJSONAndUnverifiedExecutionControlsFailBeforeDispatch() throws {
  let deep = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
  #expect(throws: (any Error).self) { try JSONValue.decode(Data(deep.utf8)) }
  for raw in [
    #"{"model":"synthetic","input":"text","background":true}"#,
    #"{"model":"synthetic","input":"text","tool_choice":{"type":"web_search"}}"#,
    #"{"model":"synthetic","input":[{"type":"message","role":"user","content":[{"type":"input_image","image_url":"https://example.invalid/private"}]}]}"#,
    #"{"model":"synthetic","input":"text","conversation":"unknown"}"#,
  ] {
    #expect(throws: (any Error).self) { try ResponseRequest(data: Data(raw.utf8)) }
  }
}

@Test func configurationFingerprintsSeparateOriginsCredentialsAndPricing() throws {
  func configuration(port: Int = 12345, inputRate: Int = 2) throws -> SingleIdentityConfiguration {
    let value: [String: Any] = [
      "principal": "p", "keyID": "k", "namespace": "synthetic", "identity": "i",
      "keySHA256": String(repeating: "a", count: 64), "reservedMicros": 10,
      "models": [
        ["id": "synthetic", "inputMicrosPerMillion": inputRate, "outputMicrosPerMillion": 3]
      ],
      "upstreamBaseURL": "http://127.0.0.1:\(port)/v1",
    ]
    let configuration = try JSONDecoder().decode(
      SingleIdentityConfiguration.self, from: JSONSerialization.data(withJSONObject: value))
    try configuration.validate()
    return configuration
  }
  let first = try configuration().makePolicy(token: "synthetic-token1")
  let same = try configuration().makePolicy(token: "synthetic-token1")
  #expect(first.owner == same.owner)
  #expect(first.policyVersion == same.policyVersion)
  #expect(first.pricingVersion == same.pricingVersion)
  #expect(
    first.owner.namespace
      != (try configuration(port: 12346).makePolicy(token: "synthetic-token1")).owner.namespace)
  #expect(
    first.owner.namespace
      != (try configuration().makePolicy(token: "synthetic-token2")).owner.namespace)
  #expect(
    first.pricingVersion
      != (try configuration(inputRate: 5).makePolicy(token: "synthetic-token1")).pricingVersion)
  #expect(!first.owner.namespace.contains("synthetic-token1"))
}

@Test func partialProviderUsageKeepsObservedLowerBoundsWithoutClaimingCompletion() throws {
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 1_000_000, outputMicrosPerMillion: 1_000_000)
  let partial = try ProviderObservation.usage(.object(["input_tokens": .number(5)]), model: model)
  #expect(partial?.inputTokens == 5)
  #expect(partial?.completeness == .partial)
  #expect(partial?.estimatedMicros == 5)
  #expect(try ProviderObservation.usage(.null, model: model) == nil)
  let cachedOnly = try ProviderObservation.usage(
    .object(["input_tokens_details": .object(["cached_tokens": .number(3)])]), model: model)
  #expect(cachedOnly?.inputTokens == 3)
  #expect(cachedOnly?.cachedTokens == 3)
  #expect(cachedOnly?.completeness == .partial)
}

@Test func streamingAndTerminalPartsRejectUnboundNestedReferences() throws {
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)
  for eventType in [
    "response.content_part.added", "response.content_part.done",
    "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
  ] {
    for nested in ["annotations", "logprobs", "private_object"] {
      let part: JSONValue = .object([
        "type": .string("output_text"), "text": .string("synthetic"),
        nested: .array([.object(["file_id": .string("synthetic-private-file")])]),
      ])
      let event: JSONValue = .object([
        "type": .string(eventType), "item_id": .string("synthetic-item"), "part": part,
      ])
      #expect(throws: (any Error).self) {
        try ProviderObservation(event: event, model: model, functionNames: [])
      }
    }
  }
}

@Test func webSocketTurnStateRejectsUncorrelatedAndRepeatedProviderEvents() throws {
  func event(_ type: String, id: String) throws -> Data {
    try JSONValue.object(["type": .string(type), "response": .object(["id": .string(id)])]).data()
  }
  let turns = WebSocketTurns()
  try turns.begin()
  #expect(throws: (any Error).self) {
    try turns.observe(event("response.completed", id: "synthetic-first"))
  }
  try turns.observe(event("response.created", id: "synthetic-first"))
  #expect(throws: (any Error).self) {
    try turns.observe(event("response.completed", id: "synthetic-other"))
  }
  #expect(throws: (any Error).self) {
    try turns.observe(
      JSONValue.object([
        "type": .string("response.output_text.delta"), "delta": .string("synthetic-unbound"),
      ]).data())
  }
  try turns.observe(event("response.completed", id: "synthetic-first"))
  #expect(throws: (any Error).self) {
    try turns.observe(event("response.completed", id: "synthetic-first"))
  }
  try turns.begin()
  #expect(throws: (any Error).self) {
    try turns.observe(event("response.created", id: "synthetic-first"))
  }
  try turns.observe(event("response.created", id: "synthetic-second"))
  turns.close()
  #expect(throws: (any Error).self) { try turns.begin() }
}

@Test func namedWebSocketLanesAreIsolatedAndBounded() throws {
  let turns = WebSocketTurns()
  func observe(_ type: String, lane: String, id: String) throws {
    try turns.observe(
      JSONValue.object([
        "type": .string(type), "stream_id": .string(lane), "response": .object(["id": .string(id)]),
      ]).data())
  }
  for index in 0..<16 { try turns.begin(lane: "lane_\(index)") }
  #expect(throws: (any Error).self) { try turns.begin(lane: "lane_16") }
  try observe("response.created", lane: "lane_0", id: "synthetic_0")
  #expect(throws: (any Error).self) {
    try observe("response.completed", lane: "lane_1", id: "synthetic_0")
  }
  try observe("response.completed", lane: "lane_0", id: "synthetic_0")
  try turns.begin(lane: "lane_16")
  for invalid in ["", "bad lane", "é", String(repeating: "a", count: 257)] {
    #expect(throws: (any Error).self) {
      try webSocketLane(.object(["stream_id": .string(invalid)]))
    }
  }
  let names = WebSocketTurns()
  for index in 0..<32 {
    try names.begin(lane: "lane_\(index)")
    let id = "synthetic_\(index)"
    try names.observe(
      JSONValue.object([
        "type": .string("response.created"), "stream_id": .string("lane_\(index)"),
        "response": .object(["id": .string(id)]),
      ]).data())
    try names.observe(
      JSONValue.object([
        "type": .string("response.completed"), "stream_id": .string("lane_\(index)"),
        "response": .object(["id": .string(id)]),
      ]).data())
  }
  #expect(throws: (any Error).self) { try names.begin(lane: "lane_32") }
}

@Test func webSocketQueuesShareByteCapacityAndCancellationWakesAllLanes() async throws {
  let inbox = WebSocketInbox()
  let block = Data(repeating: 65, count: 524_288)
  try await inbox.push(block, lane: "first")
  try await inbox.push(block, lane: "second")
  try await withExecutionDeadline(seconds: 2) {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { try await inbox.push(block, lane: "third") }
      #expect(try await inbox.next(lane: "second") == block)
      try await tasks.waitForAll()
    }
  }
  #expect(try await inbox.next(lane: "first") == block)
  #expect(try await inbox.next(lane: "third") == block)
  try await withExecutionDeadline(seconds: 2) {
    await withTaskGroup(of: Bool.self) { tasks in
      for lane in ["first", "second"] {
        tasks.addTask {
          do {
            _ = try await inbox.next(lane: lane)
            return false
          } catch { return true }
        }
      }
      tasks.cancelAll()
      for await cancelled in tasks { #expect(cancelled) }
    }
  }
}

@Test func inlineClientLabelsAreNormalizedWhilePrivateReferencesRemainExplicit() throws {
  let request = try ResponseRequest(
    data: Data(
      #"{"model":"synthetic","input":[{"type":"message","id":"local-new-message","role":"user","content":"synthetic"},{"type":"function_call_output","id":"local-new-result","call_id":"owned-call","output":"synthetic"},{"type":"item_reference","id":"owned-item"}]}"#
        .utf8))
  #expect(request.document["input"]?.array?[0]["id"] == nil)
  #expect(request.document["input"]?.array?[1]["id"] == nil)
  #expect(request.references.contains(.init(type: "function_call", rawID: "owned-call")))
  #expect(request.references.contains(.init(type: "item", rawID: "owned-item")))
  #expect(!request.references.contains(.init(type: "item", rawID: "local-new-message")))
  for raw in [
    #"{"model":"synthetic","input":[{"role":"user","content":"synthetic","encrypted_content":"unverified-private"}]}"#,
    #"{"model":"synthetic","input":[{"type":"reasoning","encrypted_content":"synthetic","file_id":"unverified-private"}]}"#,
    #"{"model":"synthetic","input":"synthetic","tools":[{"type":"namespace","name":"ns","tools":[{"type":"web_search"}]}]}"#,
  ] { #expect(throws: (any Error).self) { try ResponseRequest(data: Data(raw.utf8)) } }
}

@Test func clientExecutionModesAreExplicitAndLegacyAdmissionsRemainGeneration() throws {
  let warmup = try webSocketCreate(
    Data(#"{"type":"response.create","model":"synthetic","input":[],"generate":false}"#.utf8))
  #expect(warmup.mode == .warmup)
  #expect(warmup.document["generate"] == nil)
  #expect(throws: (any Error).self) {
    try ResponseRequest(data: Data(#"{"model":"synthetic","input":[],"generate":false}"#.utf8))
  }
  let admission = try JSONDecoder().decode(
    CodexOneCore.ExecutionAdmission.self,
    from: Data(
      #"{"attempt":"legacy","owner":{"principal":"p","key":"k","namespace":"n","identity":"i"},"window":"w","policyVersion":"p","pricingVersion":"p","reservedMicros":0}"#
        .utf8))
  #expect(admission.executionMode == .generation && admission.mode == nil)
}
