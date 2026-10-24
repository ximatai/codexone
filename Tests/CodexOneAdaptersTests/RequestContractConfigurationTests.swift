import Foundation
import Testing

@testable import CodexOneAdapters

@Test func subscriptionContractCannotBeDowngradedByTrustedConfigurationMistake() throws {
  let base: [String: Any] = [
    "principal": "synthetic", "keyID": "synthetic", "keySHA256": String(repeating: "a", count: 64),
    "namespace": "synthetic", "identity": "synthetic", "reservedMicros": 1,
    "models": [["id": "synthetic", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0]],
    "upstreamTokenFile": "/synthetic/token",
  ]
  for (origin, expected) in [
    ("http://127.0.0.1:1234/v1", ResponseRequestContract.responses),
    ("https://chatgpt.com/backend-api/codex", .codexSubscription),
  ] {
    var fields = base
    fields["upstreamBaseURL"] = origin
    let normal = try JSONDecoder().decode(
      SingleIdentityConfiguration.self, from: JSONSerialization.data(withJSONObject: fields))
    try normal.validate()
    #expect(normal.responses.requestContract == expected)
    for contract in ["responses", "codex-subscription", "synthetic-unknown"] {
      fields["upstreamContract"] = contract
      let configured = try JSONDecoder().decode(
        SingleIdentityConfiguration.self, from: JSONSerialization.data(withJSONObject: fields))
      if contract == "synthetic-unknown"
        || (expected == .codexSubscription && contract == "responses")
      {
        #expect(throws: (any Error).self) { try configured.validate() }
      } else {
        try configured.validate()
        #expect(configured.responses.requestContract.rawValue == contract)
      }
    }
  }
}
