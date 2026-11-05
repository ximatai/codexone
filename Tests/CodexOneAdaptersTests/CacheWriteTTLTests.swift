import Foundation
import Testing

@testable import CodexOneAdapters

@Test func cacheWriteTTLPreservesExtensionsInReceivedOrder() throws {
  let raw =
    #"{"response":{"usage":{"input_tokens_details":{"cache_write_tokens_details":{"ttl_12h_tokens":12,"unknown":7,"ttl_30m_tokens":3},"cached_tokens":2,"cache_write_tokens":15,"unknown":9},"output_tokens_details":{"cache_write_tokens_details":{"ttl_30m_tokens":8},"reasoning_tokens":1},"unknown":6,"input_tokens":20}}}"#
  let expected =
    raw
  let value = try JSONValue.decode(Data(raw.utf8))
  #expect(try ProviderObservation.clientOutput(value).data() == Data(expected.utf8))
}

@Test func cacheWriteTTLRejectsMalformedCountersAndContainersWithoutChangingEvidence() throws {
  let invalid: [JSONValue] = [
    .number(-1), .number(1.5), .string("3"), .bool(true), .null, .array([]), .object([:]),
  ]
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)
  for bad in invalid {
    let usage: JSONValue = .object([
      "input_tokens": .number(20), "output_tokens": .number(3),
      "input_tokens_details": .object([
        "cached_tokens": .number(2), "cache_write_tokens": .number(15),
        "cache_write_tokens_details": .object([
          "ttl_30m_tokens": bad, "ttl_12h_tokens": .number(0), "unknown": .number(7),
        ]),
      ]),
    ])
    let result = ProviderObservation.clientOutput(.object(["usage": usage]))
    #expect(
      result["usage"]?["input_tokens_details"]?["cache_write_tokens_details"]
        == .object(["ttl_12h_tokens": .number(0), "unknown": .number(7)]))
    #expect(
      ProviderObservation.usage(usage, model: model)
        == ProviderObservation.usage(result["usage"], model: model))

  }
  for bad in invalid + [.number(0), .number(3)] {
    let malformed: JSONValue = .object([
      "usage": .object(["input_tokens_details": .object(["cache_write_tokens_details": bad])])
    ])
    let projected = ProviderObservation.clientOutput(malformed)["usage"]?["input_tokens_details"]
    if bad.object != nil {
      #expect(projected?["cache_write_tokens_details"] == .object([:]))
    } else {
      #expect(projected?["cache_write_tokens_details"] == nil)
    }
  }
}
