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
  #expect(valid.responses.requestContract == .codexSubscription)
  for field in [
    "upstreamBaseURL", "upstreamTokenFile", "namespace", "identity", "principal",
    "headers", "upstreamContract",
  ] {
    var invalid = base
    invalid[field] = "synthetic-override"
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        AccountPoolConfiguration.self, from: JSONSerialization.data(withJSONObject: invalid))
    }
  }
  var invalidTransport = base
  invalidTransport["upstreamTransport"] = "unsupported"
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(
      AccountPoolConfiguration.self, from: JSONSerialization.data(withJSONObject: invalidTransport))
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

@Test func poolCatalogOrderAndGuidanceChangePolicyWithoutChangingPricing() throws {
  let ids = ["synthetic-a", "synthetic-b"]
  let key = ManagedKey(
    id: "key", principal: "p", revision: 1, enabled: true,
    policy: try KeyPolicy(models: ids, limits: syntheticLimits), createdAtUnixSeconds: 1)
  func configuration(_ ids: [String], guidance: String = "Synthetic approved guidance") throws
    -> AccountPoolConfiguration
  {
    try JSONDecoder().decode(
      AccountPoolConfiguration.self,
      from: JSONSerialization.data(withJSONObject: [
        "reservedMicros": 1,
        "models": ids.map {
          [
            "id": $0, "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1,
            "catalog": ["baseInstructions": guidance],
          ]
        },
      ]))
  }
  let first = try configuration(ids)
  let reversed = try configuration(ids.reversed())
  let changed = try configuration(ids, guidance: "Changed synthetic guidance")
  let originalPolicy = try first.policy(key: key)
  for alternative in [reversed, changed] {
    let policy = try alternative.policy(key: key)
    #expect(policy.policyVersion != originalPolicy.policyVersion)
    #expect(policy.pricingVersion == originalPolicy.pricingVersion)
    #expect(policy.models == originalPolicy.models)
  }
  let originalCatalog = try modelCatalog(
    first.models, requireCodexProfile: true, now: testUnixSeconds)
  let reversedCatalog = try modelCatalog(
    reversed.models, requireCodexProfile: true, now: testUnixSeconds)
  #expect(originalCatalog["data"]?.array?.first?["id"]?.string == ids[0])
  #expect(reversedCatalog["data"]?.array?.first?["id"]?.string == ids[1])
  #expect(try configuration(ids).policy(key: key).policyVersion == originalPolicy.policyVersion)
}

@Test func poolTransportIsExplicitAndChangesPolicyButNotPricing() throws {
  let key = ManagedKey(
    id: "key", principal: "p", revision: 1, enabled: true,
    policy: try KeyPolicy(models: ["synthetic-text"], limits: syntheticLimits),
    createdAtUnixSeconds: 1)
  func configuration(_ transport: String?) throws -> AccountPoolConfiguration {
    var document: [String: Any] = [
      "models": [
        ["id": "synthetic-text", "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1]
      ], "reservedMicros": 1,
    ]
    document["upstreamTransport"] = transport
    return try JSONDecoder().decode(
      AccountPoolConfiguration.self, from: JSONSerialization.data(withJSONObject: document))
  }
  let omitted = try configuration(nil)
  let http = try configuration("http")
  let websocket = try configuration("websocket")
  #expect(omitted.responses.upstreamTransport == "http")
  #expect(websocket.responses.upstreamTransport == "websocket")
  #expect(try omitted.policy(key: key).policyVersion == http.policy(key: key).policyVersion)
  #expect(try websocket.policy(key: key).policyVersion != http.policy(key: key).policyVersion)
  #expect(try websocket.policy(key: key).pricingVersion == http.policy(key: key).pricingVersion)
}
