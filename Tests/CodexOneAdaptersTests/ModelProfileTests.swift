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
  let loaded = try ModelProfileSnapshot.apply(
    path: file.path, models: [original], now: testUnixSeconds)
  #expect(loaded.count == 1 && loaded[0].inputMicrosPerMillion == 123)
  #expect(loaded[0].visionInput == false && loaded[0].imageGeneration == false)
  let catalog = try modelCatalog(loaded, requireCodexProfile: true, now: testUnixSeconds)
  #expect(catalog["models"]?.array?.first?["context_window"]?.integer == 272000)
  #expect(catalog["models"]?.array?.first?["max_context_window"]?.integer == 872000)
  #expect(catalog["models"]?.array?.first?["codexone_profile"]?["stale"]?.bool == true)
  // A running snapshot remains usable after the source becomes invalid; a new import must fail.
  try Data("{}".utf8).write(to: file)
  #expect(
    try modelCatalog(loaded, requireCodexProfile: true, now: testUnixSeconds)["models"]?.array?
      .count == 1)
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: file.path, models: [original], now: testUnixSeconds)
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
  let result = try ModelProfileSnapshot.apply(
    path: file.path, models: [model], now: testUnixSeconds)[0]
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
    try ModelProfileSnapshot.apply(path: file.path, models: [missing], now: testUnixSeconds)
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
      try ModelProfileSnapshot.apply(path: file.path, models: [model], now: testUnixSeconds)
    }
  }
  try writeProfile(file)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: file.path, models: [model], now: testUnixSeconds)
  }
  try writeProfile(file)
  let link = root.appendingPathComponent("link.json")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: link.path, models: [model], now: testUnixSeconds)
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

@Test func rawConfigurationCannotInjectProfileProvenance() throws {
  let raw: [String: Any] = [
    "id": "synthetic", "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1,
    "catalog": ["baseInstructions": "Synthetic guidance"],
    "profileProvenance": [
      "source": "unverified", "revision": "v1", "capturedAtUnixSeconds": Int64.min,
      "clientVersions": ["0.163.0"], "sha256": "unverified", "overridden": false,
    ],
  ]
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(
      SingleIdentityConfiguration.Model.self,
      from: JSONSerialization.data(withJSONObject: raw))
  }
}

@Test func upstreamProfilesPreserveUnknownMembersAndEnforceGatewayOverrides() throws {
  let (root, file) = try profileFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let upstream: [String: Any] = [
    "slug": "synthetic", "base_instructions": "Synthetic guidance",
    "priority": 99, "input_modalities": ["text", "image"], "prefer_websockets": true,
    "unknown": ["nested": [true, false]], "shell_type": "synthetic-shell",
  ]
  try writeProfile(file) { $0["models"] = [["id": "synthetic", "upstream": upstream]] }
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 1, outputMicrosPerMillion: 2)
  let loaded = try ModelProfileSnapshot.apply(
    path: file.path, models: [model], now: testUnixSeconds)
  for vision in [false, true] {
    for transport in ["http", "websocket"] {
      var effective = loaded
      effective[0].visionInput = vision
      let directory = try modelCatalog(
        effective, requireCodexProfile: true, upstreamTransport: transport, now: testUnixSeconds)
      var actual = try #require(directory["models"]?.array?.first?.object)
      #expect(actual.removeValue(forKey: "codexone_profile") != nil)
      var expected = try #require(
        JSONValue.decode(JSONSerialization.data(withJSONObject: upstream)).object)
      expected["priority"] = .number(0)
      if !vision { expected["input_modalities"] = .array([.string("text")]) }
      if transport != "websocket" { expected["prefer_websockets"] = .bool(false) }
      #expect(actual == expected)
    }
  }
  var override = model
  override.catalog = .init(
    displayName: nil, description: nil, contextWindow: nil,
    maxContextWindow: nil, reasoningEfforts: nil, defaultReasoningEffort: nil,
    baseInstructions: "Synthetic override")
  let overridden = try ModelProfileSnapshot.apply(
    path: file.path, models: [override], now: testUnixSeconds)
  #expect(overridden[0].upstream == nil)
  #expect(
    try modelCatalog(overridden, now: testUnixSeconds)["models"]?.array?.first?["shell_type"]
      == .string("unified_exec"))
  #expect(overridden[0].profileProvenance?.overridden == true)
}

@Test func upstreamProfilesRejectInvalidAndOversizedEntries() throws {
  let (root, file) = try profileFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)
  for upstream: [String: Any] in [
    ["slug": "different", "base_instructions": "Synthetic guidance"],
    [:], ["base_instructions": " "], ["base_instructions": 1],
    ["base_instructions": String(repeating: "x", count: 262144)],
  ] {
    try writeProfile(file) { $0["models"] = [["id": "synthetic", "upstream": upstream]] }
    #expect(throws: (any Error).self) {
      try ModelProfileSnapshot.apply(path: file.path, models: [model], now: testUnixSeconds)
    }
  }
  try writeProfile(file) {
    $0["models"] = [
      [
        "id": "synthetic", "upstream": ["base_instructions": "Synthetic guidance"],
        "catalog": ["baseInstructions": "Synthetic guidance"],
      ]
    ]
  }
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: file.path, models: [model], now: testUnixSeconds)
  }
  // A valid file above the old 1 MiB limit still imports.
  try writeProfile(file) {
    $0["models"] = [
      [
        "id": "synthetic",
        "upstream": [
          "base_instructions": String(repeating: "x", count: 40_000)
        ],
      ]
    ]
  }
  var padded = try Data(contentsOf: file)
  padded.append(Data(repeating: 32, count: 1_048_576))
  try padded.write(to: file)
  let loaded = try ModelProfileSnapshot.apply(
    path: file.path, models: [model], now: testUnixSeconds)
  #expect(loaded[0].upstream?["base_instructions"]?.string?.count == 40_000)
  try writeProfile(file)
  var oversized = try Data(contentsOf: file)
  oversized.append(Data(repeating: 32, count: 4_194_305))
  try oversized.write(to: file)
  #expect(throws: (any Error).self) {
    try ModelProfileSnapshot.apply(path: file.path, models: [model], now: testUnixSeconds)
  }
}

@Test func upstreamContentAndSnapshotHashChangePolicyButNotPricing() throws {
  let (root, file) = try profileFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 1, outputMicrosPerMillion: 2)
  let key = ManagedKey(
    id: "key", principal: "p", revision: 1, enabled: true,
    policy: try KeyPolicy(models: ["synthetic"], limits: syntheticLimits), createdAtUnixSeconds: 1)
  var pool = try JSONDecoder().decode(
    AccountPoolConfiguration.self,
    from: Data(
      #"{"reservedMicros":1,"models":[{"id":"synthetic","inputMicrosPerMillion":1,"outputMicrosPerMillion":2}]}"#
        .utf8))
  var identity = try JSONDecoder().decode(
    SingleIdentityConfiguration.self,
    from: Data(
      #"{"principal":"p","keyID":"k","namespace":"n","identity":"i","keySHA256":"0000000000000000000000000000000000000000000000000000000000000000","reservedMicros":1,"models":[{"id":"synthetic","inputMicrosPerMillion":1,"outputMicrosPerMillion":2}],"upstreamBaseURL":"http://127.0.0.1:9/v1"}"#
        .utf8))
  var poolVersions: [String] = []
  var identityVersions: [String] = []
  var poolPrices: Set<String> = []
  var identityPrices: Set<String> = []
  for revision in ["v1", "v2", "v3"] {
    try writeProfile(file) {
      $0["revision"] = revision
      $0["models"] = [
        [
          "id": "synthetic",
          "upstream": [
            "base_instructions": "Synthetic guidance", "unknown": revision == "v3",
          ],
        ]
      ]
    }
    pool.models = try ModelProfileSnapshot.apply(
      path: file.path, models: [model], now: testUnixSeconds)
    identity.models = pool.models
    let poolPolicy = try pool.policy(key: key)
    let identityPolicy = try identity.makePolicy(token: nil)
    poolVersions.append(poolPolicy.policyVersion)
    identityVersions.append(identityPolicy.policyVersion)
    poolPrices.insert(poolPolicy.pricingVersion)
    identityPrices.insert(identityPolicy.pricingVersion)
  }
  #expect(Set(poolVersions).count == 3 && Set(identityVersions).count == 3)
  #expect(poolPrices.count == 1 && identityPrices.count == 1)
}
