import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func imagePool(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws
  -> AccountPoolConfiguration
{
  var value: [String: Any] = [
    "models": [
      [
        "id": "synthetic-host", "imageGeneration": true, "visionInput": true,
        "inputMicrosPerMillion": 3, "outputMicrosPerMillion": 4,
      ]
    ],
    "reservedMicros": 1,
    "imageGeneration": [
      "defaultModel": "synthetic-image",
      "models": [
        [
          "id": "synthetic-image", "hostModel": "synthetic-host", "sizePolicy": "flexible3840",
          "supportsTransparency": false, "supportsInputFidelity": false,
          "inputMicrosPerMillion": 10, "outputMicrosPerMillion": 20,
        ]
      ],
    ],
  ]
  mutate(&value)
  return try JSONDecoder().decode(
    AccountPoolConfiguration.self, from: JSONSerialization.data(withJSONObject: value))
}
@Test func imageDeploymentDoesNotBorrowConversationGrantsOrRequireHostCapabilities()
  throws
{
  let config = try imagePool()
  let limits = ExecutionLimits(requests: 10, active: 2, unresolved: 4, budgetMicros: 100)
  let imagesOnly = ManagedKey(
    id: "images", principal: "team", revision: 1, enabled: true,
    policy: try .init(
      models: [], limits: limits, imageGeneration: true, imageModels: ["synthetic-image"]),
    createdAtUnixSeconds: 1)
  let route = try config.policy(key: imagesOnly)
  #expect(route.models == ["synthetic-image"])
  #expect(!route.key.policy.allows(model: "synthetic-host", requirements: .init()))
  #expect(
    route.key.policy.allows(
      model: "synthetic-image",
      requirements: try .init(route: .images, imageModel: "synthetic-image")))
  let chatOnly = ManagedKey(
    id: "chat", principal: "team", revision: 1, enabled: true,
    policy: try .init(models: ["synthetic-host"], limits: limits), createdAtUnixSeconds: 1)
  #expect(try config.policy(key: chatOnly).models == ["synthetic-host"])
  #expect(config.imageGeneration?.effective(for: chatOnly.policy).isEmpty == true)
  _ = try imagePool {
    $0["models"] = [
      ["id": "synthetic-host", "inputMicrosPerMillion": 3, "outputMicrosPerMillion": 4]
    ]
  }
  #expect(throws: (any Error).self) {
    try imagePool {
      $0["imageGeneration"] = [
        "defaultModel": "synthetic-image", "models": [], "url": "https://example.invalid",
      ]
    }
  }
  let changedHostPrice = try imagePool {
    $0["models"] = [
      [
        "id": "synthetic-host", "imageGeneration": true, "inputMicrosPerMillion": 5,
        "outputMicrosPerMillion": 4,
      ]
    ]
  }
  #expect(try changedHostPrice.policy(key: imagesOnly).pricingVersion == route.pricingVersion)
}
@Test func imageConcurrencyAndLegacyFieldsAreStrictAndOptional() throws {
  #expect(try imagePool().imageConcurrency == nil)
  for limit in [0, 9, -1] {
    #expect(throws: (any Error).self) { try imagePool { $0["imageConcurrency"] = limit } }
  }
  for limit in [1, 8] {
    #expect(try imagePool { $0["imageConcurrency"] = limit }.imageConcurrency == limit)
  }
  _ = try imagePool {
    $0["imageGeneration"] = [
      "defaultModel": "synthetic-image",
      "models": [
        ["id": "synthetic-image", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0]
      ],
    ]
  }
  #expect(throws: (any Error).self) { try imagePool { $0["unknown"] = 1 } }
}

@Test func singleIdentityImageConcurrencyRejectsOutOfRangeAndUnknownConfiguration() throws {
  var fields: [String: Any] = [
    "managedKeys": true, "namespace": "synthetic", "identity": "synthetic",
    "upstreamBaseURL": "http://127.0.0.1:12345/v1", "reservedMicros": 1,
    "models": [["id": "synthetic-host", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0]],
  ]
  func decode(_ value: [String: Any]) throws -> SingleIdentityConfiguration {
    let config = try JSONDecoder().decode(
      SingleIdentityConfiguration.self, from: JSONSerialization.data(withJSONObject: value))
    try config.validate()
    return config
  }
  #expect(try decode(fields).imageConcurrency == nil)
  for limit in [0, 9, -1] {
    fields["imageConcurrency"] = limit
    #expect(throws: (any Error).self) { try decode(fields) }
  }
  fields["imageConcurrency"] = 8
  #expect(try decode(fields).imageConcurrency == 8)
  fields["unknown"] = 1
  #expect(throws: (any Error).self) { try decode(fields) }
}

@Test func nullModelScopesFollowCurrentConfigurationWithoutExpandingExplicitPolicies() throws {
  let policy = try KeyPolicy(
    models: nil, limits: syntheticLimits, imageGeneration: true, imageModels: nil)
  let encoder = JSONEncoder()
  let encoded = try encoder.encode(policy)
  let json = try JSONValue.decode(encoded)
  #expect(json["models"] == .null && json["imageModels"] == .null)
  #expect(try JSONDecoder().decode(KeyPolicy.self, from: encoded) == policy)
  var missing = try #require(json.object)
  missing.removeValue(forKey: "models")
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(KeyPolicy.self, from: JSONValue.object(missing).data())
  }
  let key = ManagedKey(
    id: "dynamic", principal: "p", revision: 1, enabled: true, policy: policy,
    createdAtUnixSeconds: 1)
  let first = try imagePool()
  let changed = try imagePool {
    $0["models"] = [
      [
        "id": "synthetic-added", "imageGeneration": true, "inputMicrosPerMillion": 3,
        "outputMicrosPerMillion": 4,
      ]
    ]
    $0["imageGeneration"] = [
      "defaultModel": "synthetic-image-added",
      "models": [
        ["id": "synthetic-image-added", "inputMicrosPerMillion": 10, "outputMicrosPerMillion": 20]
      ],
    ]
  }
  let original = try first.policy(key: key)
  let current = try changed.policy(key: key)
  #expect(original.models == ["synthetic-host", "synthetic-image"])
  #expect(current.models == ["synthetic-added", "synthetic-image-added"])
  #expect(original.policyVersion != current.policyVersion)
  let catalog = try modelCatalog(
    changed.models.filter { current.models.contains($0.id) },
    images: changed.imageGeneration!.effective(for: policy))
  #expect(Set(catalog["data"]!.array!.compactMap { $0["id"]?.string }) == current.models)
  let explicit = ManagedKey(
    id: key.id, principal: key.principal, revision: 1, enabled: true,
    policy: try .init(
      models: ["synthetic-host"], limits: syntheticLimits, imageGeneration: true,
      imageModels: ["synthetic-image"]), createdAtUnixSeconds: 1)
  #expect(try first.policy(key: explicit).models == original.models)
  #expect(try first.policy(key: explicit).policyVersion != original.policyVersion)
  #expect(try changed.policy(key: explicit).models.isEmpty)
  let tools = try ExecutionRequirements(route: .conversation, imageModel: "synthetic-image-added")
  #expect(policy.allows(model: "synthetic-added", requirements: tools))
  #expect(!explicit.policy.allows(model: "synthetic-added", requirements: tools))
  let images = try ExecutionRequirements(route: .images, imageModel: "synthetic-image-added")
  #expect(policy.allows(model: "synthetic-image-added", requirements: images))
  #expect(!explicit.policy.allows(model: "synthetic-image-added", requirements: images))
  let disabledImages = try KeyPolicy(models: nil, limits: syntheticLimits, imageModels: nil)
  #expect(!disabledImages.allows(model: "synthetic-image-added", requirements: images))
  let imagesOnly = try KeyPolicy(
    models: [], limits: syntheticLimits, imageGeneration: true, imageModels: nil)
  #expect(!imagesOnly.allows(model: "synthetic-added", requirements: .init()))
  #expect(imagesOnly.allows(model: "synthetic-image-added", requirements: images))
  func single(_ ids: [String]) throws -> SingleIdentityConfiguration {
    try JSONDecoder().decode(
      SingleIdentityConfiguration.self,
      from: JSONSerialization.data(withJSONObject: [
        "managedKeys": true, "namespace": "synthetic", "identity": "i", "reservedMicros": 1,
        "upstreamBaseURL": "http://127.0.0.1:12345/v1",
        "models": ids.map { ["id": $0, "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1] },
      ]))
  }
  #expect(
    try single(["synthetic-a", "synthetic-b"]).makePolicy(token: nil, key: key).models == [
      "synthetic-a", "synthetic-b",
    ])
  #expect(try single(["synthetic-c"]).makePolicy(token: nil, key: key).models == ["synthetic-c"])
}
