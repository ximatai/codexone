import Foundation

public struct KeyPolicy: Sendable, Equatable, Codable {
  public let models: [String]?
  public let limits: ExecutionLimits
  public let visionInput: Bool
  public let imageGeneration: Bool
  public let imageModels: [String]?
  public let reasoningEfforts: [String: [String]]?
  public static let knownReasoningEfforts: Set<String> = [
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
  ]
  public init(
    models: [String]?, limits: ExecutionLimits, visionInput: Bool = false,
    imageGeneration: Bool = false, imageModels: [String]? = [],
    reasoningEfforts: [String: [String]]? = nil
  ) throws {
    guard models == nil || !models!.isEmpty || imageGeneration,
      models.map({ $0.count <= 32 && Set($0).count == $0.count }) ?? true,
      imageModels.map({ $0.count <= 16 && Set($0).count == $0.count }) ?? true,
      !imageGeneration || imageModels == nil || !imageModels!.isEmpty,
      (imageModels ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }
      ),
      (models ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }),
      (reasoningEfforts?.count ?? 0) <= 32,
      (reasoningEfforts ?? [:]).allSatisfy({ model, efforts in
        !model.isEmpty && model.utf8.count <= 128 && !model.utf8.contains(0)
          && !efforts.isEmpty && Set(efforts).count == efforts.count
          && Set(efforts).isSubset(of: Self.knownReasoningEfforts)
      }),
      [
        limits.tokens, limits.active,
      ]
      .allSatisfy({ $0.map { (1...1_000_000_000_000).contains($0) } ?? true })
    else { throw ExecutionError.invalidCommand }
    self.models = models
    self.limits = ExecutionLimits(
      requests: nil, active: limits.active, unresolved: nil, budgetMicros: nil,
      unresolvedMicros: nil, tokens: limits.tokens)
    self.visionInput = visionInput
    self.imageGeneration = imageGeneration
    self.imageModels = imageModels
    self.reasoningEfforts = reasoningEfforts
  }
  public func validate() throws {
    _ = try Self(
      models: models, limits: limits, visionInput: visionInput,
      imageGeneration: imageGeneration, imageModels: imageModels, reasoningEfforts: reasoningEfforts
    )
  }
  private enum TokenLimitKeys: String, CodingKey { case tokens, active }
  private enum CodingKeys: String, CodingKey {
    case models, limits, visionInput, imageGeneration, imageModels, reasoningEfforts
  }
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      models: fields.decode([String]?.self, forKey: .models),
      limits: fields.decode(ExecutionLimits.self, forKey: .limits),
      visionInput: fields.decodeIfPresent(Bool.self, forKey: .visionInput) ?? false,
      imageGeneration: fields.decodeIfPresent(Bool.self, forKey: .imageGeneration) ?? false,
      imageModels: fields.contains(.imageModels)
        ? fields.decode([String]?.self, forKey: .imageModels) : [],
      reasoningEfforts: fields.decodeIfPresent([String: [String]].self, forKey: .reasoningEfforts))
  }
  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(models, forKey: .models)
    var limitFields = fields.nestedContainer(keyedBy: TokenLimitKeys.self, forKey: .limits)
    try limitFields.encode(limits.tokens, forKey: .tokens)
    try limitFields.encode(limits.active, forKey: .active)
    try fields.encode(visionInput, forKey: .visionInput)
    try fields.encode(imageGeneration, forKey: .imageGeneration)
    try fields.encode(imageModels, forKey: .imageModels)
    try fields.encodeIfPresent(reasoningEfforts, forKey: .reasoningEfforts)
  }
  public func retainingReasoningEfforts(from previous: Self) throws -> Self {
    guard reasoningEfforts == nil, let retained = previous.reasoningEfforts else { return self }
    return try Self(
      models: models, limits: limits, visionInput: visionInput, imageGeneration: imageGeneration,
      imageModels: imageModels, reasoningEfforts: retained)
  }
  public func allowsReasoning(_ effort: String?, model: String, mode: ExecutionMode) -> Bool {
    guard mode != .warmup, let allowed = reasoningEfforts?[model] else { return true }
    return effort.map(allowed.contains) ?? false
  }
  public func allowsConversationModel(_ model: String) -> Bool {
    models?.contains(model) ?? true
  }
  public func allowsImageModel(_ model: String) -> Bool {
    imageGeneration && (imageModels?.contains(model) ?? true)
  }
  public func allowsConfiguredModel(_ model: String) -> Bool {
    allowsConversationModel(model) || allowsImageModel(model)
  }
  public func allows(model: String, requirements: ExecutionRequirements) -> Bool {
    guard (try? requirements.validate()) != nil else { return false }
    switch requirements.route {
    case .conversation:
      guard allowsConversationModel(model), !requirements.visionInput || visionInput else {
        return false
      }
    case .images:
      guard requirements.imageModel == model else { return false }
    }
    if let image = requirements.imageModel {
      return allowsImageModel(image)
    }
    return true
  }
}

/// Safe metadata. Verification material is deliberately absent from list/update responses.
public struct ManagedKey: Sendable, Equatable, Codable {
  public let id: String
  public let displayName: String?
  public let principal: String
  public let revision: Int64
  public let enabled: Bool
  public let policy: KeyPolicy
  public let createdAtUnixSeconds: Int64
  public let archivedAtUnixSeconds: Int64?
  public let expiresAtUnixSeconds: Int64?
  public init(
    id: String, principal: String, revision: Int64, enabled: Bool, policy: KeyPolicy,
    createdAtUnixSeconds: Int64, expiresAtUnixSeconds: Int64? = nil, displayName: String? = nil,
    archivedAtUnixSeconds: Int64? = nil
  ) {
    self.archivedAtUnixSeconds = archivedAtUnixSeconds
    self.displayName = displayName
    self.expiresAtUnixSeconds = expiresAtUnixSeconds
    self.id = id
    self.principal = principal
    self.revision = revision
    self.enabled = enabled
    self.policy = policy
    self.createdAtUnixSeconds = createdAtUnixSeconds
  }
}

/// All mutations are local atomic commands. Raw secrets never cross this port.
public protocol KeyGovernanceStore: Sendable {
  func authenticateKey(digest: String) async throws -> ManagedKey
  func createKey(
    id: String, principal: String, digest: String, policy: KeyPolicy,
    catalogRevision: Int64?
  ) async throws -> ManagedKey
  func updateKey(
    id: String, revision: Int64, enabled: Bool, policy: KeyPolicy,
    catalogRevision: Int64?
  ) async throws -> ManagedKey
  func setKeyDisplayName(id: String, revision: Int64, displayName: String?) async throws
    -> ManagedKey
  func setKeyExpiration(id: String, revision: Int64, expiresAtUnixSeconds: Int64?) async throws
    -> ManagedKey
  func rotateKey(id: String, revision: Int64, digest: String) async throws
    -> ManagedKey
  func setKeyArchived(id: String, revision: Int64, archived: Bool) async throws -> ManagedKey
  func listKeys(after: String?, archived: Bool) async throws -> [ManagedKey]
}

public enum KeyGovernanceError: Error, Sendable {
  case keyEnabled, keyArchived, keyNotArchived
}
