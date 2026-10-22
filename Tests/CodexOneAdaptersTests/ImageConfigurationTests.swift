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
@Test func imageDeploymentRequiresExplicitHostCapabilitiesAndDoesNotBorrowConversationGrants()
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
  #expect(throws: (any Error).self) {
    try imagePool {
      $0["models"] = [
        ["id": "synthetic-host", "inputMicrosPerMillion": 3, "outputMicrosPerMillion": 4]
      ]
    }
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
  #expect(try changedHostPrice.policy(key: imagesOnly).pricingVersion != route.pricingVersion)
}
@Test func imageSizeProfilesEnforceIntegerPixelBoundsRatherThanInferringFromModelNames() throws {
  let model = try #require(imagePool().imageGeneration?.models.first)
  for size in ["auto", "1024x1024", "2048x1024", "3840x2160"] { #expect(model.accepts(size: size)) }
  for size in [
    "0x0", "16x16", "-1024x1024", "01024x1024", "1025x1024", "3840x3840", "4096x1024", "3072x768",
    "9223372036854775807x16",
  ] { #expect(!model.accepts(size: size)) }
}
