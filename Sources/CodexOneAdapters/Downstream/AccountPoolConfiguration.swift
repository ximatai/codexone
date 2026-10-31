import CodexOneCore
import Dispatch
import Foundation

public struct AccountPoolConfiguration: Sendable, Decodable {
  public let clientFingerprint: ClientFingerprint?
  public let dataConnections: Int?
  public let imageConcurrency: Int?
  public let imageGeneration: ImageConfiguration?
  public var models: [SingleIdentityConfiguration.Model]
  public let reservedMicros: Int64
  public let executionTimeoutSeconds: Int?
  public let firstResponseTimeoutSeconds: Int?
  public let progressTimeoutSeconds: Int?
  public let modelProfilesFile: String?
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
        [
          "models", "reservedMicros", "executionTimeoutSeconds", "upstreamTransport",
          "imageGeneration", "firstResponseTimeoutSeconds", "progressTimeoutSeconds",
          "modelProfilesFile", "imageConcurrency", "clientFingerprint", "dataConnections",
        ].contains(
          $0.stringValue)
      })
    else { throw ExecutionError.invalidCommand }
    clientFingerprint = try values.decodeIfPresent(
      ClientFingerprint.self, forKey: Field(stringValue: "clientFingerprint")!)
    dataConnections = try values.decodeIfPresent(
      Int.self, forKey: Field(stringValue: "dataConnections")!)
    imageConcurrency = try values.decodeIfPresent(
      Int.self, forKey: Field(stringValue: "imageConcurrency")!)
    imageGeneration = try values.decodeIfPresent(
      ImageConfiguration.self, forKey: Field(stringValue: "imageGeneration")!)
    models = try values.decode(
      [SingleIdentityConfiguration.Model].self, forKey: Field(stringValue: "models")!)
    reservedMicros = try values.decode(Int64.self, forKey: Field(stringValue: "reservedMicros")!)
    executionTimeoutSeconds = try values.decodeIfPresent(
      Int.self, forKey: Field(stringValue: "executionTimeoutSeconds")!)
    firstResponseTimeoutSeconds = try values.decodeIfPresent(
      Int.self, forKey: Field(stringValue: "firstResponseTimeoutSeconds")!)
    progressTimeoutSeconds = try values.decodeIfPresent(
      Int.self, forKey: Field(stringValue: "progressTimeoutSeconds")!)
    modelProfilesFile = try values.decodeIfPresent(
      String.self, forKey: Field(stringValue: "modelProfilesFile")!)
    upstreamTransport = try values.decodeIfPresent(
      String.self, forKey: Field(stringValue: "upstreamTransport")!)
    try validate()
  }
  public static func load(path: String) async throws -> Self {
    try await withCheckedThrowingContinuation { result in
      DispatchQueue.global(qos: .utility).async {
        do {
          var configuration = try JSONDecoder().decode(
            Self.self, from: readPrivateData(path, maximum: 65_536))
          configuration.models = try ModelProfileSnapshot.apply(
            path: configuration.modelProfilesFile, models: configuration.models)
          try configuration.validate()
          result.resume(returning: configuration)
        } catch { result.resume(throwing: ExecutionError.invalidCommand) }
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
    guard (0...1_000_000_000_000).contains(reservedMicros),
      ["http", "websocket"].contains(upstreamTransport ?? "http")
    else { throw ExecutionError.invalidCommand }
  }
  var responses: ResponsesConfiguration {
    .init(
      models: models, upstreamBaseURL: SubscriptionOAuthProvider.dataOrigin,
      executionTimeoutSeconds: executionTimeoutSeconds,
      upstreamTransport: upstreamTransport ?? "http",
      firstResponseTimeoutSeconds: firstResponseTimeoutSeconds,
      progressTimeoutSeconds: progressTimeoutSeconds, requestContract: .codexSubscription,
      imageGeneration: imageGeneration,
      clientFingerprint: (clientFingerprint ?? .init()).resolved(models: models),
      dataConnections: dataConnections ?? 128)
  }
  func policy(key: ManagedKey) throws -> AccountPoolPolicy {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let effective = models.filter { key.policy.allowsConversationModel($0.id) }
    let imageModels = imageGeneration?.effective(for: key.policy) ?? []
    var prices = effective.sorted { $0.id < $1.id }.map {
      JSONValue.object([
        "id": .string($0.id), "inputMicrosPerMillion": .number(Decimal($0.inputMicrosPerMillion)),
        "outputMicrosPerMillion": .number(Decimal($0.outputMicrosPerMillion)),
      ])
    }
    prices += imageModels.sorted { $0.id < $1.id }.map { image in
      return JSONValue.object([
        "id": .string(image.id),
        "inputMicrosPerMillion": .number(Decimal(image.inputMicrosPerMillion)),
        "outputMicrosPerMillion": .number(Decimal(image.outputMicrosPerMillion)),
      ])
    }
    let pricing = keyDigest(String(decoding: try encoder.encode(prices), as: UTF8.self))
    let policy = keyDigest(
      String(
        decoding: try encoder.encode(
          JSONValue.object([
            "protocolVersion": .string("m4-image-capabilities-1"), "key": .string(key.id),
            "principal": .string(key.principal),
            "keyRevision": .number(Decimal(key.revision)),
            "keyPolicy": .string(
              keyDigest(String(decoding: try encoder.encode(key.policy), as: UTF8.self))),
            "imageConfiguration": .string(
              keyDigest(String(decoding: try encoder.encode(imageGeneration), as: UTF8.self))),
            "catalog": .string(
              keyDigest(String(decoding: try encoder.encode(effective), as: UTF8.self))),
            "pricing": .string(pricing),
            "reservation": .number(Decimal(reservedMicros)),
            "transport": .string(upstreamTransport ?? "http"),
            "timeout": .number(Decimal(responses.budget.total)),
            "firstResponseTimeout": .number(Decimal(responses.budget.first)),
            "progressTimeout": .number(Decimal(responses.budget.idle)),
          ])), as: UTF8.self))
    return try .init(
      key: key, models: Set(effective.map(\.id) + imageModels.map(\.id)),
      reservedMicros: reservedMicros,
      policyVersion: policy, pricingVersion: pricing)
  }
}
