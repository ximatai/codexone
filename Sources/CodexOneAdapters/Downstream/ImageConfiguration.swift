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
      hostModel = try fields.decode(String.self, forKey: .hostModel)
      sizePolicy = try fields.decode(SizePolicy.self, forKey: .sizePolicy)
      supportsTransparency = try fields.decode(Bool.self, forKey: .supportsTransparency)
      supportsInputFidelity = try fields.decode(Bool.self, forKey: .supportsInputFidelity)
      inputMicrosPerMillion = try fields.decode(Int64.self, forKey: .inputMicrosPerMillion)
      outputMicrosPerMillion = try fields.decode(Int64.self, forKey: .outputMicrosPerMillion)
    }
    func accepts(size: String) -> Bool {
      if size == "auto" { return true }
      switch sizePolicy {
      case .fixed1536:
        return ["1024x1024", "1536x1024", "1024x1536"].contains(size)
      case .flexible3840:
        let parts = size.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
          String(width) == parts[0], String(height) == parts[1],
          (16...3840).contains(width), (16...3840).contains(height),
          width % 16 == 0, height % 16 == 0,
          max(width, height) <= 3 * min(width, height),
          (655_360...8_294_400).contains(width * height)
        else { return false }
        return true
      }
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
          && hosts.contains(where: { $0.id == model.hostModel && $0.imageGeneration == true })
          && (0...500_000_000).contains(model.inputMicrosPerMillion)
          && (0...500_000_000).contains(model.outputMicrosPerMillion)
      })
    else { throw ExecutionError.invalidCommand }
  }
  func effective(for policy: KeyPolicy) -> [Model] {
    policy.imageGeneration ? models.filter { policy.imageModels.contains($0.id) } : []
  }
}
private struct ImageField: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
private func rejectUnknownImageFields(_ decoder: any Decoder, allowed: Set<String>) throws {
  let fields = try decoder.container(keyedBy: ImageField.self)
  guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
    throw ExecutionError.invalidCommand
  }
}
