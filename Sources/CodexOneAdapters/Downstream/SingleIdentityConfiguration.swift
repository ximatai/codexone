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
  }
  public struct Catalog: Sendable, Codable {
    public let displayName: String?
    public let description: String?
    public let contextWindow: Int?
    public let reasoningEfforts: [String]?
    public let defaultReasoningEffort: String?
    public let baseInstructions: String?
  }
  public let principal: String?
  public let keyID: String?
  public let keySHA256: String?
  public let managedKeys: Bool?
  public let namespace: String
  public let identity: String
  public let models: [Model]
  public let upstreamBaseURL: String
  public let upstreamTokenFile: String?
  public let reservedMicros: Int64
  public let executionTimeoutSeconds: Int?
  public let upstreamTransport: String?

  public static func load(path: String) async throws -> SingleIdentityConfiguration {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let data = try readPrivateData(path, maximum: 65_536)
          let configuration = try JSONDecoder().decode(Self.self, from: data)
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
    guard
      [namespace, identity].allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
      }),
      namespace.utf8.count <= 128,

      !models.isEmpty, models.count <= 32, Set(models.map(\.id)).count == models.count,
      models.allSatisfy({
        !$0.id.isEmpty && $0.id.utf8.count <= 128
          && (0...500_000_000).contains($0.inputMicrosPerMillion)
          && (0...500_000_000).contains($0.outputMicrosPerMillion)
      }),
      models.allSatisfy({ model in
        guard let catalog = model.catalog else { return true }
        let efforts = catalog.reasoningEfforts ?? []
        return (catalog.displayName?.utf8.count ?? 1) > 0
          && (catalog.displayName?.utf8.count ?? 0) <= 128
          && (catalog.description?.utf8.count ?? 0) <= 1024
          && (catalog.baseInstructions == nil
            || (!(catalog.baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ?? true)
              && (catalog.baseInstructions?.utf8.count ?? 0) <= 32_768))
          && (4096...131_072).contains(catalog.contextWindow ?? 32_768)
          && efforts.count <= 8 && Set(efforts).count == efforts.count
          && efforts.allSatisfy({
            ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains($0)
          })
          && (catalog.defaultReasoningEffort == nil
            || efforts.contains(catalog.defaultReasoningEffort!))
      }),
      (0...1_000_000_000_000).contains(reservedMicros),
      (1...120).contains(executionTimeoutSeconds ?? 120),
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
    guard synthetic || subscription else { throw ExecutionError.invalidCommand }
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
    let models = models.filter { key == nil || key!.policy.models.contains($0.id) }
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
          "protocolVersion": .string("m2-compaction-v2-1"),
          "keyPolicyVersion": keyPolicyVersion.map { .string($0) } ?? .null,
          "keyRevision": key.map { .number(Decimal($0.revision)) } ?? .null,
          "principal": .string(principal), "namespace": .string(namespace), "scope": .string(scope),
          "identity": .string(identity),
          "models": .array(models.map(\.id).sorted().map { .string($0) }),
          "catalogVersion": .string(digest(try encoder.encode(models))),
          "reservation": .number(Decimal(reservedMicros)),
          "executionTimeoutSeconds": .number(Decimal(executionTimeoutSeconds ?? 120)),
          "transport": .string(upstreamTransport ?? "http"),
        ])))
    return try .init(
      owner: .init(
        principal: principal, key: keyID, namespace: namespace + ":" + scope, identity: identity),
      models: Set(models.map(\.id)), reservedMicros: reservedMicros, policyVersion: policy,
      pricingVersion: digest(pricing), keyRevision: key?.revision)
  }
}
