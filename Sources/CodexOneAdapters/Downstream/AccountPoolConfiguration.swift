import CodexOneCore
import Dispatch
import Foundation

public struct AccountPoolConfiguration: Sendable, Decodable {
  public let models: [SingleIdentityConfiguration.Model]
  public let reservedMicros: Int64
  public let executionTimeoutSeconds: Int?
  public let upstreamTransport: String?
  private struct Field: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Field.self)
    guard
      values.allKeys.allSatisfy({
        ["models", "reservedMicros", "executionTimeoutSeconds", "upstreamTransport"].contains(
          $0.stringValue)
      })
    else { throw ExecutionError.invalidCommand }
    models = try values.decode(
      [SingleIdentityConfiguration.Model].self, forKey: Field(stringValue: "models")!)
    reservedMicros = try values.decode(Int64.self, forKey: Field(stringValue: "reservedMicros")!)
    executionTimeoutSeconds = try values.decodeIfPresent(
      Int.self, forKey: Field(stringValue: "executionTimeoutSeconds")!)
    upstreamTransport = try values.decodeIfPresent(
      String.self, forKey: Field(stringValue: "upstreamTransport")!)
    try validate()
  }
  public static func load(path: String) async throws -> Self {
    try await withCheckedThrowingContinuation { result in
      DispatchQueue.global(qos: .utility).async {
        do {
          let configuration = try JSONDecoder().decode(
            Self.self, from: readPrivateData(path, maximum: 65_536))
          try configuration.validate()
          result.resume(returning: configuration)
        } catch { result.resume(throwing: ExecutionError.invalidCommand) }
      }
    }
  }
  public func validate() throws {
    try validateResponseModels(models)
    guard (0...1_000_000_000_000).contains(reservedMicros),
      (1...120).contains(executionTimeoutSeconds ?? 120),
      ["http", "websocket"].contains(upstreamTransport ?? "http")
    else { throw ExecutionError.invalidCommand }
  }
  var responses: ResponsesConfiguration {
    .init(
      models: models, upstreamBaseURL: SubscriptionOAuthProvider.dataOrigin,
      executionTimeoutSeconds: executionTimeoutSeconds,
      upstreamTransport: upstreamTransport ?? "http")
  }
  func policy(key: ManagedKey) throws -> AccountPoolPolicy {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let effective = models.filter { key.policy.models.contains($0.id) }
    let prices = effective.sorted { $0.id < $1.id }.map {
      JSONValue.object([
        "id": .string($0.id), "inputMicrosPerMillion": .number(Decimal($0.inputMicrosPerMillion)),
        "outputMicrosPerMillion": .number(Decimal($0.outputMicrosPerMillion)),
      ])
    }
    let pricing = keyDigest(String(decoding: try encoder.encode(prices), as: UTF8.self))
    let policy = keyDigest(
      String(
        decoding: try encoder.encode(
          JSONValue.object([
            "protocolVersion": .string("m3-pool-http-1"), "key": .string(key.id),
            "principal": .string(key.principal),
            "keyRevision": .number(Decimal(key.revision)),
            "keyPolicy": .string(
              keyDigest(String(decoding: try encoder.encode(key.policy), as: UTF8.self))),
            "catalog": .string(
              keyDigest(String(decoding: try encoder.encode(effective), as: UTF8.self))),
            "pricing": .string(pricing),
            "reservation": .number(Decimal(reservedMicros)),
            "transport": .string(upstreamTransport ?? "http"),
            "timeout": .number(Decimal(executionTimeoutSeconds ?? 120)),
          ])), as: UTF8.self))
    return try .init(
      key: key, models: Set(effective.map(\.id)), reservedMicros: reservedMicros,
      policyVersion: policy, pricingVersion: pricing)
  }
}
