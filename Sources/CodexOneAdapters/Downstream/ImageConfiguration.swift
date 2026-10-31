import CodexOneCore
import Foundation

/// Trusted deployment mapping. A public image model never implies permission to use a chat model.
public struct ImageConfiguration: Sendable, Codable {
  public struct Model: Sendable, Codable {
    public enum SizePolicy: String, Sendable, Codable { case fixed1536, flexible3840 }
    public let id: String
    public let hostModel: String
    public let sizePolicy: SizePolicy
    public let supportsTransparency: Bool
    public let supportsInputFidelity: Bool
    public let inputMicrosPerMillion: Int64
    public let outputMicrosPerMillion: Int64
    private enum CodingKeys: String, CodingKey, CaseIterable {
      case id, hostModel, sizePolicy, supportsTransparency, supportsInputFidelity
      case inputMicrosPerMillion, outputMicrosPerMillion
    }
    public init(from decoder: any Decoder) throws {
      try rejectUnknownImageFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      id = try fields.decode(String.self, forKey: .id)
      hostModel = try fields.decodeIfPresent(String.self, forKey: .hostModel) ?? ""
      sizePolicy = try fields.decodeIfPresent(SizePolicy.self, forKey: .sizePolicy) ?? .fixed1536
      supportsTransparency =
        try fields.decodeIfPresent(Bool.self, forKey: .supportsTransparency) ?? false
      supportsInputFidelity =
        try fields.decodeIfPresent(Bool.self, forKey: .supportsInputFidelity) ?? false
      inputMicrosPerMillion = try fields.decode(Int64.self, forKey: .inputMicrosPerMillion)
      outputMicrosPerMillion = try fields.decode(Int64.self, forKey: .outputMicrosPerMillion)
    }

  }
  public let defaultModel: String
  public let models: [Model]
  private enum CodingKeys: String, CodingKey, CaseIterable { case defaultModel, models }
  public init(from decoder: any Decoder) throws {
    try rejectUnknownImageFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    defaultModel = try fields.decode(String.self, forKey: .defaultModel)
    models = try fields.decode([Model].self, forKey: .models)
  }
  func validate(hosts: [SingleIdentityConfiguration.Model]) throws {
    let hostIDs = Set(hosts.map(\.id))
    guard (1...16).contains(models.count), Set(models.map(\.id)).count == models.count,
      models.contains(where: { $0.id == defaultModel }),
      models.allSatisfy({ model in
        !model.id.isEmpty && model.id.utf8.count <= 128 && !model.id.utf8.contains(0)
          && !hostIDs.contains(model.id)
          && (0...500_000_000).contains(model.inputMicrosPerMillion)
          && (0...500_000_000).contains(model.outputMicrosPerMillion)
      })
    else { throw ExecutionError.invalidCommand }
  }
  func effective(for policy: KeyPolicy) -> [Model] {
    policy.imageGeneration ? models.filter { policy.allowsImageModel($0.id) } : []
  }
}
private struct ImageField: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
func rejectUnknownImageFields(_ decoder: any Decoder, allowed: Set<String>) throws {
  let fields = try decoder.container(keyedBy: ImageField.self)
  guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
    throw ExecutionError.invalidCommand
  }
}
