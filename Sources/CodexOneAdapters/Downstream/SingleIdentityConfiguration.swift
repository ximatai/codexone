import CodexOneCore
import Crypto
import Dispatch
import Foundation

/// Local, trusted configuration. It is not accepted from management or data-plane requests.
public struct SingleIdentityConfiguration: Sendable, Decodable {
  public struct Model: Sendable, Codable {
    public let id: String
    public let inputMicrosPerMillion: Int64
    public let outputMicrosPerMillion: Int64
    public var catalog: Catalog? = nil
    var upstream: JSONValue? = nil
    public internal(set) var profileProvenance: ModelProfileProvenance? = nil
    public var visionInput: Bool? = nil
    public var imageGeneration: Bool? = nil
  }
  public struct Catalog: Sendable, Codable {
    public let displayName: String?
    public let description: String?
    public let contextWindow: Int?
    public let maxContextWindow: Int?
    public let reasoningEfforts: [String]?
    public let defaultReasoningEffort: String?
    public let baseInstructions: String?
  }
  public let principal: String?
  public let keyID: String?
  public let keySHA256: String?
  public let clientFingerprint: ClientFingerprint?
  public let dataConnections: Int?
  public let imageConcurrency: Int?
  public let imageGeneration: ImageConfiguration?
  public let managedKeys: Bool?
  public let namespace: String
  public let identity: String
  public var models: [Model]
  public let upstreamBaseURL: String
  public let upstreamTokenFile: String?
  public let reservedMicros: Int64
  public let executionTimeoutSeconds: Int?
  public let firstResponseTimeoutSeconds: Int?
  public let progressTimeoutSeconds: Int?
  public let modelProfilesFile: String?
  public let upstreamTransport: String?
  public let upstreamContract: String?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case clientFingerprint, dataConnections, principal, keyID, keySHA256, imageConcurrency,
      imageGeneration, managedKeys, namespace,
      identity, models, upstreamBaseURL, upstreamTokenFile, reservedMicros, executionTimeoutSeconds,
      firstResponseTimeoutSeconds, progressTimeoutSeconds, modelProfilesFile, upstreamTransport,
      upstreamContract
  }
  public init(from decoder: any Decoder) throws {
    try rejectUnknownImageFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    clientFingerprint = try fields.decodeIfPresent(
      ClientFingerprint.self, forKey: .clientFingerprint)
    dataConnections = try fields.decodeIfPresent(Int.self, forKey: .dataConnections)
    principal = try fields.decodeIfPresent(String.self, forKey: .principal)
    keyID = try fields.decodeIfPresent(String.self, forKey: .keyID)
    keySHA256 = try fields.decodeIfPresent(String.self, forKey: .keySHA256)
    imageConcurrency = try fields.decodeIfPresent(Int.self, forKey: .imageConcurrency)
    imageGeneration = try fields.decodeIfPresent(ImageConfiguration.self, forKey: .imageGeneration)
    managedKeys = try fields.decodeIfPresent(Bool.self, forKey: .managedKeys)
    namespace = try fields.decode(String.self, forKey: .namespace)
    identity = try fields.decode(String.self, forKey: .identity)
    models = try fields.decode([Model].self, forKey: .models)
    upstreamBaseURL = try fields.decode(String.self, forKey: .upstreamBaseURL)
    upstreamTokenFile = try fields.decodeIfPresent(String.self, forKey: .upstreamTokenFile)
    reservedMicros = try fields.decode(Int64.self, forKey: .reservedMicros)
    executionTimeoutSeconds = try fields.decodeIfPresent(Int.self, forKey: .executionTimeoutSeconds)
    firstResponseTimeoutSeconds = try fields.decodeIfPresent(
      Int.self, forKey: .firstResponseTimeoutSeconds)
    progressTimeoutSeconds = try fields.decodeIfPresent(Int.self, forKey: .progressTimeoutSeconds)
    modelProfilesFile = try fields.decodeIfPresent(String.self, forKey: .modelProfilesFile)
    upstreamTransport = try fields.decodeIfPresent(String.self, forKey: .upstreamTransport)
    upstreamContract = try fields.decodeIfPresent(String.self, forKey: .upstreamContract)
  }

  public static func load(path: String, clock: WallClock = .system) async throws
    -> SingleIdentityConfiguration
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let data = try readPrivateData(path, maximum: 65_536)
          var configuration = try JSONDecoder().decode(Self.self, from: data)
          configuration.models = try ModelProfileSnapshot.apply(
            path: configuration.modelProfilesFile, models: configuration.models,
            now: clock.unixSeconds)
          try configuration.validate()
          if let tokenPath = configuration.upstreamTokenFile {
            _ = try readRuntimeSecret(tokenPath)
          }
          continuation.resume(returning: configuration)
        } catch { continuation.resume(throwing: ExecutionError.invalidCommand) }
      }
    }
  }

  public func validate() throws {
    try clientFingerprint?.validate()
    guard (8...1024).contains(dataConnections ?? 128) else { throw ExecutionError.invalidCommand }
    _ = try ExecutionBudget(
      total: executionTimeoutSeconds, first: firstResponseTimeoutSeconds,
      idle: progressTimeoutSeconds)
    try validateResponseModels(models)
    try imageGeneration?.validate(hosts: models)
    guard (1...8).contains(imageConcurrency ?? 2) else { throw ExecutionError.invalidCommand }
    guard
      [namespace, identity].allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
      }),
      namespace.utf8.count <= 128,

      (0...1_000_000_000_000).contains(reservedMicros),
      ["http", "websocket"].contains(upstreamTransport ?? "http"),
      let url = URLComponents(string: upstreamBaseURL), url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil,
      url.path == "/v1" || url.path == "/backend-api/codex"
    else { throw ExecutionError.invalidCommand }
    if managedKeys == true {
      guard principal == nil, keyID == nil, keySHA256 == nil else {
        throw ExecutionError.invalidCommand
      }
    } else {
      guard let principal, let keyID, let keySHA256,
        [principal, keyID].allSatisfy({
          !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
        }),
        keySHA256.utf8.count == 64, keySHA256.allSatisfy({ "0123456789abcdef".contains($0) })
      else { throw ExecutionError.invalidCommand }
    }
    let synthetic =
      url.scheme == "http" && url.host == "127.0.0.1" && (1...65535).contains(url.port ?? 0)
    let subscription =
      url.scheme == "https" && url.host == "chatgpt.com" && (url.port == nil || url.port == 443)
      && url.path == "/backend-api/codex"
    guard upstreamContract == nil || ResponseRequestContract(rawValue: upstreamContract!) != nil,
      !subscription || upstreamContract == nil || upstreamContract == "codex-subscription",
      synthetic || subscription
    else { throw ExecutionError.invalidCommand }
    if let path = upstreamTokenFile {
      guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else {
        throw ExecutionError.invalidCommand
      }
    }
    guard synthetic || upstreamTokenFile != nil else { throw ExecutionError.invalidCommand }
  }
  func accepts(_ authorization: [String]) -> Bool {
    guard let keySHA256, keySHA256.utf8.count == 64, authorization.count == 1,
      authorization[0].hasPrefix("Bearer ")
    else { return false }
    let token = String(authorization[0].dropFirst(7))
    guard (24...512).contains(token.utf8.count) else { return false }
    let hex = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    return zip(hex.utf8, keySHA256.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
  func makePolicy(token: String?, key: ManagedKey? = nil) throws -> SingleIdentityPolicy {
    guard (managedKeys == true) == (key != nil),
      let principal = key?.principal ?? principal, let keyID = key?.id ?? keyID
    else { throw ExecutionError.unauthorized }
    let allModels = models
    let models = models.filter { key == nil || key!.policy.allowsConversationModel($0.id) }
    let capabilities =
      try key?.policy
      ?? KeyPolicy(
        models: allModels.map(\.id),
        limits: .init(
          requests: 1_000_000, active: 16, unresolved: 16, budgetMicros: 1_000_000_000_000),
        visionInput: allModels.contains { $0.visionInput == true },
        imageGeneration: imageGeneration != nil,
        imageModels: imageGeneration?.models.map(\.id) ?? [])
    let imageModels = imageGeneration?.effective(for: capabilities) ?? []
    // M2 cannot attest credential equivalence yet: token/origin changes get a fresh namespace.
    // M3 will preserve stable identity only after provider-verified refresh equivalence.
    func digest(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    let scope = digest(
      try JSONEncoder().encode([upstreamBaseURL, "responses", identity, token ?? "synthetic"]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let pricing = try encoder.encode(
      models.sorted { $0.id < $1.id }.map { model in
        JSONValue.object([
          "id": .string(model.id),
          "inputMicrosPerMillion": .number(Decimal(model.inputMicrosPerMillion)),
          "outputMicrosPerMillion": .number(Decimal(model.outputMicrosPerMillion)),
        ])
      })
    let keyPolicyVersion = try key.map { digest(try encoder.encode($0.policy)) }
    let policy = digest(
      try encoder.encode(
        JSONValue.object([
          "protocolVersion": .string("m4-image-capabilities-1"),
          "images": .string(digest(try encoder.encode(imageGeneration))),
          "keyPolicyVersion": keyPolicyVersion.map { .string($0) } ?? .null,
          "keyRevision": key.map { .number(Decimal($0.revision)) } ?? .null,
          "principal": .string(principal), "namespace": .string(namespace), "scope": .string(scope),
          "identity": .string(identity),
          "models": .array(models.map(\.id).sorted().map { .string($0) }),
          "catalogVersion": .string(digest(try encoder.encode(models))),
          "reservation": .number(Decimal(reservedMicros)),
          "executionTimeoutSeconds": .number(Decimal(responses.budget.total)),
          "firstResponseTimeoutSeconds": .number(Decimal(responses.budget.first)),
          "progressTimeoutSeconds": .number(Decimal(responses.budget.idle)),
          "transport": .string(upstreamTransport ?? "http"),
          "requestContract": .string(responses.requestContract.rawValue),
        ])))
    return try .init(
      owner: .init(
        principal: principal, key: keyID, namespace: namespace + ":" + scope, identity: identity),
      models: Set(models.map(\.id) + imageModels.map(\.id)), reservedMicros: reservedMicros,
      policyVersion: policy,
      pricingVersion: digest(pricing + (try encoder.encode(imageGeneration))),
      keyRevision: key?.revision, capabilities: capabilities)
  }
}
