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
    let catalog: SingleIdentityConfiguration.Catalog
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
    let data = try readPrivateData(path, maximum: 1_048_576)
    let json = try JSONValue.decode(data)
    guard
      json.object?.keys.allSatisfy({
        ["version", "source", "revision", "capturedAtUnixSeconds", "clientVersions", "models"]
          .contains($0)
      }) == true,
      json["models"]?.array?.allSatisfy({ entry in
        entry.object?.keys.allSatisfy({ ["id", "catalog"].contains($0) }) == true
          && entry["catalog"]?.object?.keys.allSatisfy({
            [
              "displayName", "description", "contextWindow", "maxContextWindow", "reasoningEfforts",
              "defaultReasoningEffort", "baseInstructions",
            ].contains($0)
          }) == true
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
        id: entry.id, inputMicrosPerMillion: 0, outputMicrosPerMillion: 0, catalog: entry.catalog)
    }
    try validateResponseModels(validationModels)
    guard
      snapshot.models.allSatisfy({
        !($0.catalog.baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
      return result
    }
  }
}
