import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func profileFixture() throws -> (URL, URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let file = root.appendingPathComponent("profiles.json")
  return (root, file)
}
private func writeProfile(_ path: URL, change: (inout [String: Any]) -> Void = { _ in }) throws {
  var value: [String: Any] = [
    "version": 1, "source": "synthetic-approved", "revision": "v1", "capturedAtUnixSeconds": 1,
    "clientVersions": ["0.163.0"],
    "models": [
      [
        "id": "synthetic",
        "catalog": [
          "baseInstructions": "Synthetic approved guidance",
          "contextWindow": 272000, "maxContextWindow": 872000,
        ],
      ]
    ],
  ]
  change(&value)
  try JSONSerialization.data(withJSONObject: value).write(to: path)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}
@Test func profileImportKeepsPricesCapabilitiesAndSelectedModelSet() throws {
  let (root, file) = try profileFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try writeProfile(file)
  let original = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 123,
    outputMicrosPerMillion: 456, visionInput: false, imageGeneration: false)
  let loaded = try ModelProfileSnapshot.apply(path: file.path, models: [original])
  #expect(loaded.count == 1 && loaded[0].inputMicrosPerMillion == 123)
  #expect(loaded[0].visionInput == false && loaded[0].imageGeneration == false)
  let catalog = try modelCatalog(loaded, requireCodexProfile: true)
  #expect(catalog["models"]?.array?.first?["context_window"]?.integer == 272000)
  #expect(catalog["models"]?.array?.first?["max_context_window"]?.integer == 872000)
  #expect(catalog["models"]?.array?.first?["codexone_profile"]?["stale"]?.bool == true)
  // A running snapshot remains usable after the source becomes invalid; a new import must fail.
  try Data("{}".utf8).write(to: file)
  #expect(try modelCatalog(loaded, requireCodexProfile: true)["models"]?.array?.count == 1)
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: file.path, models: [original])
  }
}
@Test func explicitCatalogOverridesAsAWholeAndMissingModelsFailClosed() throws {
  let (root, file) = try profileFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  try writeProfile(file)
  let model = try JSONDecoder().decode(
    SingleIdentityConfiguration.Model.self,
    from: Data(
      #"{"id":"synthetic","inputMicrosPerMillion":1,"outputMicrosPerMillion":1,"catalog":{"baseInstructions":"Explicit override"}}"#
        .utf8))
  let result = try ModelProfileSnapshot.apply(path: file.path, models: [model])[0]
  #expect(result.catalog?.baseInstructions == "Explicit override")
  #expect(result.catalog?.contextWindow == nil)
  #expect(result.profileProvenance?.overridden == true)
  var missing = model
  // Decode a distinct, explicitly selected model; snapshot must not add or substitute models.
  missing = try JSONDecoder().decode(
    SingleIdentityConfiguration.Model.self,
    from: Data(
      #"{"id":"missing","inputMicrosPerMillion":1,"outputMicrosPerMillion":1}"#.utf8))
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: file.path, models: [missing])
  }
}
@Test func profileRejectsLinksPermissionsAmbiguousAndUnsupportedClaims() throws {
  let (root, file) = try profileFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 1, outputMicrosPerMillion: 1)
  for field in ["version", "source", "future", "models", "clientVersions"] {
    try writeProfile(file) { value in
      switch field {
      case "version": value[field] = 2
      case "source": value[field] = "https://example.invalid/private"
      case "models": value[field] = [["id": "synthetic", "catalog": ["baseInstructions": " "]]]
      case "clientVersions": value[field] = []
      default: value[field] = true
      }
    }
    #expect(throws: (any Error).self) {
      try ModelProfileSnapshot.apply(path: file.path, models: [model])
    }
  }
  try writeProfile(file)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: file.path, models: [model])
  }
  try writeProfile(file)
  let link = root.appendingPathComponent("link.json")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: link.path, models: [model])
  }
}
@Test func executionBudgetsRejectUnboundedOrContradictoryValues() throws {
  #expect(try ExecutionBudget().total == 600)
  #expect(try ExecutionBudget(total: 1).first == 1)
  for total in [0, 1801] {
    #expect(throws: (any Error).self) { try ExecutionBudget(total: total) }
  }
  #expect(throws: (any Error).self) { try ExecutionBudget(total: 10, first: 11) }
  #expect(throws: (any Error).self) { try ExecutionBudget(total: 10, idle: 11) }
}
