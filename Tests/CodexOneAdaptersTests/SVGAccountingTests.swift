import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func authorDocument(_ extra: JSONObject = [:]) -> JSONValue {
  var value: JSONObject = [
    "model": .string("synthetic-author"), "input_tokens": .number(10),
    "output_tokens": .number(20), "reasoning_tokens": .number(5), "total_tokens": .number(30),
  ]
  for (key, member) in extra { value[key] = member }
  return .object(value)
}

@Test func svgCountersAndPriceCoverageAreIndependentAndRootIsNotAddedTwice() throws {
  let root: JSONValue = .object(["svg_usage": authorDocument()])
  let item: JSONValue = .object(["svg_usage": authorDocument(["input_tokens": .number(99)])])
  let unknownPrice = SVGUsage(root, items: [item], expected: true)
  #expect(unknownPrice.input == 10 && unknownPrice.output == 20 && unknownPrice.reasoning == 5)
  #expect(unknownPrice.complete && unknownPrice.cost == nil)
  #expect(unknownPrice.reasons == ["svg_price_unavailable"])
  let mapping = SingleIdentityConfiguration.Model(
    id: "synthetic-author", inputMicrosPerMillion: 1_000_000, outputMicrosPerMillion: 2_000_000)
  let knownPrice = SVGUsage(root, items: [item], expected: true, models: [mapping])
  #expect(knownPrice.cost == 50 && knownPrice.complete)
  let missing = SVGUsage(.object([:]), items: [], expected: true)
  #expect(missing.input == nil && !missing.complete)
  let ambiguous = SVGUsage(
    .object([:]),
    items: [.object(["svg_usage": authorDocument()]), .object(["svg_usage": authorDocument()])],
    expected: true)
  #expect(ambiguous.input == 10 && ambiguous.output == 20 && !ambiguous.complete)
  #expect(ambiguous.reasons.contains("svg_usage_ambiguous"))
  let invalid = SVGUsage(
    .object(["svg_usage": authorDocument(["output_tokens": .number(-1)])]), items: [],
    expected: true)
  #expect(invalid.input == 10 && invalid.output == nil && !invalid.complete)
}

@Test func svgZeroAndMissingValuesSurviveEvidenceValidationAndRevisions() throws {
  let old = UsageEvidence(
    revision: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0, images: 1, estimatedMicros: 13,
    completeness: .complete,
    svgInputTokens: 0, svgOutputTokens: 0, priceCompleteness: .partial)
  try old.validate()
  let erased = UsageEvidence(
    revision: 2, inputTokens: 0, outputTokens: 0, cachedTokens: 0, images: 1, estimatedMicros: 13,
    completeness: .complete)
  #expect(!erased.isAtLeast(old))
  let encoded = try JSONEncoder().encode(old)
  #expect(try JSONDecoder().decode(UsageEvidence.self, from: encoded) == old)
}

@Test func v11AuthorMigrationPreservesOldEvidenceAndRequiresExplicitUpgrade() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let limits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 1000)
  let store = try await SQLiteExecutionStore.open(path: path, limits: limits)
  try await store.admit(admission("legacy-author"))
  try await store.finalize(attempt: "legacy-author", evidence: usage())
  await store.close()
  try rawSQL(
    path,
    removeOutputRateSchema
      + "ALTER TABLE usage_daily DROP COLUMN svg_input_tokens; ALTER TABLE usage_daily DROP COLUMN svg_output_tokens; ALTER TABLE usage_daily DROP COLUMN svg_reasoning_tokens; ALTER TABLE usage_daily DROP COLUMN price_unknown; PRAGMA user_version=11"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: limits)
  }
  try await SQLiteExecutionStore.migrate(path: path)
  let upgraded = try await SQLiteExecutionStore.open(path: path, limits: limits)
  do {
    #expect(try await upgraded.perform { try $0.scalar("PRAGMA user_version") } == 14)
    let restored = try await upgraded.snapshot(attempt: "legacy-author")
    #expect(restored.state == .settled && restored.usage == usage())
    #expect(restored.usage?.svgInputTokens == nil)
  } catch {
    await upgraded.close()
    throw error
  }
  await upgraded.close()
  let backups = try FileManager.default.contentsOfDirectory(
    atPath: (path as NSString).deletingLastPathComponent)
  #expect(backups.filter { $0.contains(".pre-v13-") }.count == 1)
}

@Test func svgSnapshotsRetainCumulativeFactsAndMissingItemDoesNotProveCoverage() throws {
  let initial: JSONValue = .object(["svg_usage": authorDocument()])
  let value = SVGUsage.mergingSnapshot(nil, initial["svg_usage"])
  #expect(SVGUsage.mergingSnapshot(value, nil) == value)
  let smaller = SVGUsage.mergingSnapshot(
    value, authorDocument(["input_tokens": .number(1), "total_tokens": .number(21)]))
  let parsed = SVGUsage(.object(["svg_usage": smaller!]), items: [], expected: true)
  #expect(parsed.input == 10 && parsed.output == 20)
  let partial = SVGUsage(
    .object([:]), items: [.object(["svg_usage": authorDocument()]), .object([:])], expected: true)
  #expect(!partial.complete && partial.reasons.contains("svg_usage_ambiguous"))
  let model = try #require(syntheticImageConfiguration().models.first)
  let actualSVG: JSONValue = .object([
    "data": .array([.object(["output_format": .string("svg")])]),
    "usage": .object(["input_tokens": .number(2), "output_tokens": .number(3)]),
  ])
  #expect(NativeImageObservation(actualSVG, model: model).usage?.completeness == .partial)
}

@Test func imagePriceSaturationRetainsMonotonicLowerBound() throws {
  #expect(
    imageCost(
      input: 1_000_000_000, output: 1_000_000_000, inputRate: 1_000_000_000,
      outputRate: 1_000_000_000) == 1_000_000_000_000)
}
