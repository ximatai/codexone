import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func poolConfigurationRejectsRoutingOverridesAndPreservesExplicitProfileContract() throws {
  let base: [String: Any] = [
    "models": [["id": "synthetic-text", "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1]],
    "reservedMicros": 1,
  ]
  let valid = try JSONDecoder().decode(
    AccountPoolConfiguration.self, from: JSONSerialization.data(withJSONObject: base))
  try valid.validate()
  #expect(valid.responses.upstreamBaseURL == "https://chatgpt.com/backend-api/codex")
  #expect(valid.responses.upstreamTransport == "http")
  for field in [
    "upstreamBaseURL", "upstreamTokenFile", "namespace", "identity", "principal",
    "upstreamTransport", "headers",
  ] {
    var invalid = base
    invalid[field] = "synthetic-override"
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        AccountPoolConfiguration.self, from: JSONSerialization.data(withJSONObject: invalid))
    }
  }
  for models in [
    [],
    [
      [
        "id": "synthetic-text", "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1,
        "catalog": ["baseInstructions": " "],
      ]
    ],
  ] as [[Any]] {
    var invalid = base
    invalid["models"] = models
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        AccountPoolConfiguration.self, from: JSONSerialization.data(withJSONObject: invalid))
    }
  }
}
