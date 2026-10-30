import CodexOneCore
import Crypto
import Foundation

public struct ModelProfileProvenance: Sendable, Codable {
  public let source: String
  public let revision: String
  public let capturedAtUnixSeconds: Int64
  public let clientVersions: [String]
  public let sha256: String
  public let overridden: Bool
}

/// Administrator-owned offline snapshot. Import never adds a routable model or permission.
struct ModelProfileSnapshot: Decodable {
  struct Entry: Decodable {
    let id: String
    let catalog: SingleIdentityConfiguration.Catalog?
    let upstream: JSONValue?
  }
  let version: Int
  let source: String
  let revision: String
  let capturedAtUnixSeconds: Int64
  let clientVersions: [String]
  let models: [Entry]

  static func apply(
    path: String?, models: [SingleIdentityConfiguration.Model]
  ) throws -> [SingleIdentityConfiguration.Model] {
    guard let path else { return models }
    let data = try readPrivateData(path, maximum: 4_194_304)
    let json = try JSONValue.decode(data)
    guard
      json.object?.keys.allSatisfy({
        ["version", "source", "revision", "capturedAtUnixSeconds", "clientVersions", "models"]
          .contains($0)
      }) == true,
      json["models"]?.array?.allSatisfy({ entry in
        entry.object?.keys.allSatisfy({ ["id", "catalog", "upstream"].contains($0) }) == true
          && (entry["catalog"] == nil
            || entry["catalog"]?.object?.keys.allSatisfy({
              [
                "displayName", "description", "contextWindow", "maxContextWindow",
                "reasoningEfforts",
                "defaultReasoningEffort", "baseInstructions",
              ].contains($0)
            }) == true)
          && ((entry["catalog"] != nil) != (entry["upstream"] != nil))
      }) == true
    else { throw ExecutionError.invalidCommand }
    let snapshot = try JSONDecoder().decode(Self.self, from: data)
    func identifier(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.count <= 64
        && value.utf8.allSatisfy {
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || [45, 46, 95].contains($0)
        }
    }
    guard snapshot.version == 1, identifier(snapshot.source), identifier(snapshot.revision),
      snapshot.capturedAtUnixSeconds > 0,
      snapshot.capturedAtUnixSeconds <= Int64(Date().timeIntervalSince1970) + 60,
      !snapshot.clientVersions.isEmpty, snapshot.clientVersions.count <= 8,
      Set(snapshot.clientVersions).count == snapshot.clientVersions.count,
      snapshot.clientVersions.allSatisfy(identifier),
      !snapshot.models.isEmpty, snapshot.models.count <= 32,
      Set(snapshot.models.map(\.id)).count == snapshot.models.count
    else { throw ExecutionError.invalidCommand }
    // Validate the whole snapshot, including entries not selected by this deployment.
    let validationModels = snapshot.models.map { entry in
      SingleIdentityConfiguration.Model(
        id: entry.id, inputMicrosPerMillion: 0, outputMicrosPerMillion: 0, catalog: entry.catalog,
        upstream: entry.upstream)
    }
    try validateResponseModels(validationModels)
    guard
      snapshot.models.allSatisfy({
        $0.upstream != nil
          || !($0.catalog?.baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true)
      })
    else { throw ExecutionError.invalidCommand }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return try models.map { model in
      guard let entry = snapshot.models.first(where: { $0.id == model.id }) else {
        throw ExecutionError.invalidCommand
      }
      if let override = model.catalog,
        override.baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      {
        throw ExecutionError.invalidCommand
      }
      var result = model
      result.profileProvenance = .init(
        source: snapshot.source, revision: snapshot.revision,
        capturedAtUnixSeconds: snapshot.capturedAtUnixSeconds,
        clientVersions: snapshot.clientVersions, sha256: digest, overridden: model.catalog != nil)
      result.catalog = model.catalog ?? entry.catalog
      result.upstream = model.catalog == nil ? entry.upstream : nil
      return result
    }
  }
}

private enum ModelConfigurationKey: String, CodingKey {
  case id, inputMicrosPerMillion, outputMicrosPerMillion, catalog, profileProvenance
  case visionInput, imageGeneration, upstream
}

extension SingleIdentityConfiguration.Model {
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: ModelConfigurationKey.self)
    // Provenance is an output of the validated importer, never a configuration assertion.
    guard !fields.contains(.profileProvenance), !fields.contains(.upstream) else {
      throw ExecutionError.invalidCommand
    }
    self.init(
      id: try fields.decode(String.self, forKey: .id),
      inputMicrosPerMillion: try fields.decode(Int64.self, forKey: .inputMicrosPerMillion),
      outputMicrosPerMillion: try fields.decode(Int64.self, forKey: .outputMicrosPerMillion),
      catalog: try fields.decodeIfPresent(
        SingleIdentityConfiguration.Catalog.self, forKey: .catalog),
      visionInput: try fields.decodeIfPresent(Bool.self, forKey: .visionInput),
      imageGeneration: try fields.decodeIfPresent(Bool.self, forKey: .imageGeneration))
  }
}
