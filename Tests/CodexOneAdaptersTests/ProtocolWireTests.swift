import Foundation
import Testing

@testable import CodexOneAdapters

@Test func sseHandlesFragmentedUTF8AndCRLFWithoutTreatingEOFAsCompletion() throws {
  var decoder = SSEDecoder()
  let wire = Data(
    "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"合成文本\"}\r\n\r\n"
      .utf8)
  var events: [JSONValue] = []
  for byte in wire { events += try decoder.append(Data([byte])) }
  #expect(events.count == 1)
  #expect(events[0]["delta"]?.string == "合成文本")
  try decoder.finish()
  #expect(!decoder.sawDone)
  _ = try decoder.append(Data("data: [DONE]\n\n".utf8))
  #expect(decoder.sawDone)
  #expect(throws: (any Error).self) { try decoder.append(Data("data: {}\n\n".utf8)) }
}

@Test func incompleteAndOversizedEventsAreRejected() throws {
  var incomplete = SSEDecoder()
  _ = try incomplete.append(Data("data: {\"type\":\"response.completed\"}".utf8))
  #expect(throws: (any Error).self) { try incomplete.finish() }
  var oversized = SSEDecoder()
  #expect(throws: (any Error).self) { try oversized.append(Data(repeating: 65, count: 262_145)) }
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
