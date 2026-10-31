import CodexOneCore
import Foundation
import Testing

private let imageLimits = ExecutionLimits(
  requests: 100, active: 2, unresolved: 4, budgetMicros: 1000)

@Test func imageAuthorizationSeparatesVisionConversationAndSharedGenerationPermission() throws {
  let vision = try ExecutionRequirements(route: .conversation, visionInput: true)
  let tool = try ExecutionRequirements(route: .conversation, imageModel: "synthetic-image")
  let images = try ExecutionRequirements(route: .images, imageModel: "synthetic-image")
  let seeOnly = try KeyPolicy(models: ["synthetic-chat"], limits: imageLimits, visionInput: true)
  #expect(seeOnly.allows(model: "synthetic-chat", requirements: vision))
  #expect(!seeOnly.allows(model: "synthetic-chat", requirements: tool))
  #expect(!seeOnly.allows(model: "synthetic-image", requirements: images))
  let imagesOnly = try KeyPolicy(
    models: [], limits: imageLimits, imageGeneration: true, imageModels: ["synthetic-image"])
  #expect(imagesOnly.allows(model: "synthetic-image", requirements: images))
  #expect(!imagesOnly.allows(model: "synthetic-chat", requirements: tool))
  #expect(!imagesOnly.allows(model: "synthetic-image", requirements: .init()))
  let both = try KeyPolicy(
    models: ["synthetic-chat"], limits: imageLimits, imageGeneration: true,
    imageModels: ["synthetic-image"])
  #expect(both.allows(model: "synthetic-chat", requirements: tool))
  #expect(both.allows(model: "synthetic-image", requirements: images))
  #expect(!both.allows(model: "synthetic-chat", requirements: vision))
  #expect(!both.allows(model: "different-image", requirements: images))
  #expect(
    !both.allows(
      model: "synthetic-chat",
      requirements: try .init(route: .conversation, imageModel: "different-image")))
  #expect(throws: ExecutionError.invalidCommand) { try ExecutionRequirements(route: .images) }
  #expect(throws: ExecutionError.invalidCommand) {
    try ExecutionRequirements(route: .images, visionInput: true, imageModel: "synthetic-image")
  }
}

@Test func legacyKeyMetadataDoesNotGrantNewImageAbilitiesAndRoundTripPreservesExplicitGrants()
  throws
{
  let old: [String: Any] = [
    "models": ["synthetic-chat"],
    "limits": [
      "requests": 100, "active": 2, "unresolved": 4, "budgetMicros": 1000, "unresolvedMicros": 1000,
    ],
  ]
  let legacy = try JSONDecoder().decode(
    KeyPolicy.self, from: JSONSerialization.data(withJSONObject: old))
  #expect(!legacy.visionInput && !legacy.imageGeneration && legacy.imageModels?.isEmpty == true)
  let policy = try KeyPolicy(
    models: [], limits: imageLimits, imageGeneration: true, imageModels: ["synthetic-image"])
  #expect(try JSONDecoder().decode(KeyPolicy.self, from: JSONEncoder().encode(policy)) == policy)
  #expect(throws: ExecutionError.invalidCommand) { try KeyPolicy(models: [], limits: imageLimits) }
  #expect(throws: ExecutionError.invalidCommand) {
    try KeyPolicy(models: ["chat"], limits: imageLimits, imageGeneration: true)
  }
}
