import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private struct UsageFixture {
  let path: String
  let store: SQLiteExecutionStore
  let reader: SQLiteUsageReader
  let hour: Int64
  static func make() async throws -> Self {
    let path = try temporaryExecutionPath()
    let store = try await SQLiteExecutionStore.open(
      path: path,
      limits: .init(requests: 100000, active: 64, unresolved: 64, budgetMicros: 1_000_000_000_000))
    for (id, digest) in [("alpha", "a"), ("beta", "b")] {
      _ = try await store.createKey(
        id: id, principal: id, digest: String(repeating: digest, count: 64),
        policy: .init(
          models: ["synthetic-text"],
          limits: .init(
            requests: 100000, active: 64, unresolved: 64, budgetMicros: 1_000_000_000_000)))
    }
    try await store.configureHealthModels(["synthetic-text"])
    return Self(
      path: path, store: store, reader: try await store.makeUsageReader(),
      hour: Int64(Date().timeIntervalSince1970) / 3600 * 3600)
  }
  func insert(
    _ id: String, key: String = "alpha", mode: ExecutionMode = .generation, at: Int64?,
    evidence: UsageEvidence?, failure: ExecutionFailure? = nil
  ) async throws {
    try await store.admit(
      .init(
        attempt: id,
        owner: .init(principal: key, key: key, namespace: "synthetic", identity: "single"),
        window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 10,
        requestID: "request-" + id, mode: mode, keyRevision: 1, model: "synthetic-text"))
    try await store.finalize(
      attempt: id, evidence: evidence,
      outcome: .init(failure: failure, atUnixSeconds: Int64(Date().timeIntervalSince1970)))
    try await store.perform { db in
      try db.write(
        "UPDATE attempts SET created_at_epoch=? WHERE id=?",
        [at.map { .number($0) } ?? .null, .text(id)])
    }
  }
  func close() async {
    await reader.close()
    await store.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}

@Test func usageReadsLatestEvidenceWithKeyTimeModeAndFailureIsolationWithoutCountingRevisionsTwice()
  async throws
{
  let f = try await UsageFixture.make()
  do {
    try await f.insert("complete", at: f.hour, evidence: usage(amount: 10))
    try await f.insert(
      "partial", mode: .compact, at: f.hour + 3600,
      evidence: .init(
        revision: 1, inputTokens: 3, outputTokens: 0, cachedTokens: 0, images: 0,
        estimatedMicros: 3, completeness: .partial), failure: .deadlineExceeded)
    try await f.insert("missing", at: f.hour + 7200, evidence: nil, failure: .clientCancelled)
    try await f.insert(
      "foreign", key: "beta", mode: .warmup, at: f.hour, evidence: usage(amount: 40))
    try await f.insert("historical", at: nil, evidence: nil)
    try await f.store.recordRejection(
      requestID: "refused", keyID: "alpha", model: "synthetic-text", mode: .generation,
      failure: .localCapacity)
    // This has a real committed intent, so it must never also become a refusal.
    try await f.store.recordRejection(
      requestID: "request-missing", keyID: "alpha", model: "synthetic-text", mode: .generation,
      failure: .clientCancelled)
    let query = try UsageQuery(
      startUnixSeconds: f.hour, endUnixSeconds: f.hour + 10800, keyID: "alpha", limit: 2)
    let first = try await f.reader.queryUsage(query)
    #expect(first.totals.admitted == 3 && first.totals.rejected == 1)
    #expect(
      first.totals.complete == 1 && first.totals.partial == 1 && first.totals.unavailable == 1)
    #expect(first.totals.metrics.inputTokens == 13 && first.totals.metrics.outputTokens == 10)
    #expect(first.totals.unknown == 2 && first.totals.failed == 1 && first.totals.cancelled == 1)
    #expect(first.totals.historicalWithoutTime == 1 && first.totals.lifetimeUnknown == 3)
    #expect(
      first.totals.unresolvedExposureMicros == 20 && first.totals.lifetimeExposureMicros == 30)
    #expect(first.buckets.count == 3 && first.buckets[1].unresolved == 1)
    let cursor = try #require(first.nextCursor)
    let second = try await f.reader.queryUsage(
      .init(
        startUnixSeconds: f.hour, endUnixSeconds: f.hour + 10800, keyID: "alpha", cursor: cursor,
        limit: 2))
    #expect(second.nextCursor == nil && Set((first.rows + second.rows).map(\.id)).count == 4)
    let partial = try await f.reader.queryUsage(
      .init(
        startUnixSeconds: f.hour, endUnixSeconds: f.hour + 10800, keyID: "alpha", mode: .compact))
    #expect(
      partial.totals.admitted == 1 && partial.totals.partial == 1
        && partial.totals.lifetimeUnknown == 3)
    let failed = try await f.reader.queryUsage(
      .init(
        startUnixSeconds: f.hour, endUnixSeconds: f.hour + 10800, keyID: "alpha", failedOnly: true))
    #expect(failed.totals.admitted == 2 && failed.totals.rejected == 1)
    let missing = try await f.reader.queryUsage(
      .init(startUnixSeconds: f.hour + 7200, endUnixSeconds: f.hour + 10800, keyID: "alpha"))
    #expect(missing.totals.metrics.inputTokens == nil && missing.totals.unavailable == 1)
    let key = try #require(try await f.store.listKeys(after: nil).first { $0.id == "alpha" })
    _ = try await f.store.rotateKey(
      id: key.id, revision: key.revision, digest: String(repeating: "c", count: 64))
    try await f.store.finalize(attempt: "partial", evidence: usage(revision: 2, amount: 20))
    let late = try await f.reader.queryUsage(query)
    #expect(late.totals.admitted == 3 && late.totals.complete == 2 && late.totals.partial == 0)
    #expect(late.totals.metrics.inputTokens == 30 && late.totals.unknown == 1)
    #expect(late.totals.failed == 1 && late.totals.lifetimeUnknown == 2)
  } catch {
    await f.close()
    throw error
  }
  await f.close()
}

@Test func usageReadOnlyConnectionAndSingleReaderOwnerCannotModifyTheLedger() async throws {
  let f = try await UsageFixture.make()
  do {
    await #expect(throws: ExecutionError.conflict) { try await f.store.makeUsageReader() }
    let readOnly = try SQLiteConnection(readOnlyPath: f.path)
    #expect(throws: ExecutionError.storageUnavailable) {
      try readOnly.write("DELETE FROM managed_keys")
    }
    readOnly.shutdown()
    #expect(try await f.store.listKeys(after: nil).count == 2)
    let options = try await f.reader.usageOptions()
    #expect(options.keys == ["alpha", "beta"] && options.models == ["synthetic-text"])
    await f.reader.close()
    await #expect(throws: ExecutionError.capacity) { try await f.reader.usageOptions() }
    // A closed statistical reader does not fail the primary or block critical writes.
    try await f.insert("after-reader-close", at: f.hour, evidence: usage(amount: 1))
    #expect(f.store.isAvailable)
  } catch {
    await f.close()
    throw error
  }
  await f.close()
}

@Test func usageLargeIntegerMetricsStayExactAndQueryCapacityDoesNotStopCriticalWrites() async throws
{
  let f = try await UsageFixture.make()
  do {
    let huge = UsageEvidence(
      revision: 1, inputTokens: 1_000_000_000_000, outputTokens: 0, cachedTokens: 0, images: 0,
      estimatedMicros: 0, completeness: .complete)
    try await f.insert("seed", at: f.hour, evidence: huge)
    // A bounded, internally consistent reader dataset, not a protocol or admission benchmark.
    try await f.store.perform { db in
      try db.exec(
        """
        WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<9999)
        INSERT INTO attempts SELECT 'synthetic-'||i,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,
          reserved,state,json_remove(json_set(admission_json,'$.attempt','synthetic-'||i),'$.requestID'),usage_json,evidence_floor,estimated,
          created_at_epoch,outcome_json,NULL FROM attempts,n WHERE id='seed';
        INSERT INTO evidence SELECT id,1,usage_json FROM attempts WHERE id LIKE 'synthetic-%';
        """)
    }
    let query = try UsageQuery(startUnixSeconds: f.hour, endUnixSeconds: f.hour + 3600)
    let report = try await f.reader.queryUsage(query)
    #expect(
      report.totals.admitted == 10000 && report.totals.metrics.inputTokens == 10_000_000_000_000_000
    )
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for _ in 0..<16 {
        group.addTask {
          do {
            _ = try await f.reader.queryUsage(query)
            return true
          } catch { return false }
        }
      }
      var results: [Bool] = []
      for await result in group { results.append(result) }
      return results
    }
    #expect(results.contains(false) && results.contains(true))
    try await f.store.finalize(
      attempt: "seed", evidence: usage(revision: 2, amount: 1_000_000_000_000))
    #expect(f.store.isAvailable)
  } catch {
    await f.close()
    throw error
  }
  await f.close()
}

@Test func usageManagementValidatesQueriesAndRoundTripsBoundedCursorsWithExactMetrics() async throws
{
  let f = try await UsageFixture.make()
  do {
    try await f.insert("first", at: f.hour, evidence: usage(amount: 3))
    try await f.insert("second", at: f.hour, evidence: nil)
    let url = "/api/usage?start=\(f.hour)&end=\(f.hour + 3600)&key=alpha&limit=1"
    let query = try UsageAdminAPI.parse(url)
    let report = try await f.reader.queryUsage(query)
    let json = try UsageAdminAPI.document(report, query: query)
    #expect(json["totals"]?["metrics"]?["inputTokens"]?.string == "3")
    #expect(json["rows"]?.array?.count == 1)
    let cursor = try #require(json["nextCursor"]?.string)
    let next = try UsageAdminAPI.parse(url + "&after=" + cursor)
    #expect(next.cursor == report.nextCursor)
    #expect(try await f.reader.queryUsage(next).rows.count == 1)
    for suffix in [
      "&key=beta", "&body=private", "&mode=other", "&failedOnly=1", "&after=bad",
      "&after=" + cursor + "=",
    ] {
      #expect(throws: (any Error).self) { try UsageAdminAPI.parse(url + suffix) }
    }
    #expect(throws: ExecutionError.invalidCommand) {
      try UsageAdminAPI.parse("/api/usage?start=1&end=999999999")
    }
  } catch {
    await f.close()
    throw error
  }
  await f.close()
}

@Test func nativeImageUsageProjectionKeepsMissingMetricsUnavailableAndLegacyHostEvidence()
  async throws
{
  let f = try await UsageFixture.make()
  do {
    try await f.insert(
      "native-missing", at: f.hour,
      evidence: .init(
        revision: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0, images: 1,
        estimatedMicros: 0, completeness: .partial, nativeImages: true))
    let missing = try await f.reader.queryUsage(
      .init(startUnixSeconds: f.hour, endUnixSeconds: f.hour + 3600))
    #expect(missing.totals.metrics.inputTokens == nil && missing.totals.metrics.outputTokens == nil)
    #expect(
      missing.totals.metrics.estimatedMicros == nil
        && missing.totals.metrics.imageInputTokens == nil)
    #expect(missing.rows.first?.metrics.images == 1)
    try await f.insert(
      "native-complete", at: f.hour + 3600,
      evidence: .init(
        revision: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0, images: 1,
        estimatedMicros: 13, completeness: .complete, imageInputTokens: 2, imageOutputTokens: 3,
        imageInputTextTokens: 1, imageInputImageTokens: 1, nativeImages: true))
    let complete = try await f.reader.queryUsage(
      .init(startUnixSeconds: f.hour + 3600, endUnixSeconds: f.hour + 7200))
    #expect(
      complete.totals.metrics.imageInputTextTokens == 1
        && complete.rows.first?.metrics.imageInputImageTokens == 1)
    #expect(
      complete.totals.metrics.estimatedMicros == 13 && complete.totals.metrics.inputTokens == nil)
    try await f.insert("legacy-image-host", at: f.hour + 7200, evidence: usage(amount: 7))
    let legacy = try await f.reader.queryUsage(
      .init(startUnixSeconds: f.hour + 7200, endUnixSeconds: f.hour + 10800))
    #expect(legacy.totals.metrics.inputTokens == 7 && legacy.totals.metrics.estimatedMicros == 7)
  } catch {
    await f.close()
    throw error
  }
  await f.close()
}

@Test func keyUsageUsesUTCDayAndNamesWithoutInventingHistoricalTiming() async throws {
  let f = try await UsageFixture.make()
  do {
    let start = Int64(Date().timeIntervalSince1970) / 86400 * 86400
    try await f.insert("before", at: start - 1, evidence: usage(amount: 70))
    try await f.insert("boundary", at: start, evidence: usage(amount: 3))
    try await f.insert("failed-today", at: start + 1, evidence: nil, failure: .upstreamRejected)
    try await f.insert("after", at: start + 86400, evidence: usage(amount: 80))
    try await f.store.admit(
      .init(
        attempt: "in-flight",
        owner: .init(principal: "alpha", key: "alpha", namespace: "synthetic", identity: "single"),
        window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 10,
        requestID: "request-in-flight", model: "synthetic-text"))
    let summary = try await f.reader.keyUsage()
    let alpha = try #require(summary.keys.first { $0.key.id == "alpha" })
    #expect(summary.startUnixSeconds == start && summary.keys.count == 2)
    #expect(alpha.admitted == 3 && alpha.failed == 1 && alpha.pending == 2)
    #expect(alpha.estimatedMicros == 3 && alpha.lastUsedAtUnixSeconds == start + 86400)
    #expect(alpha.key.principal == "alpha")
    let query = try UsageQuery(startUnixSeconds: start, endUnixSeconds: start + 86400)
    let historical = try await f.reader.queryUsage(query)
    #expect(historical.rows.allSatisfy { $0.principal == "alpha" && $0.totalMilliseconds == nil })
    try await f.store.perform { db in
      try db.write(
        "UPDATE attempts SET outcome_json=json_set(outcome_json,'$.firstEventMilliseconds',12,'$.totalMilliseconds',34) WHERE id='boundary'"
      )
      try db.write(
        "INSERT INTO request_diagnostics VALUES ('ghost-request',?,'ghost','synthetic-text','generation','invalid_request')",
        [.number(start)])
      try db.write("DELETE FROM key_events WHERE key_id='alpha'")
      try db.write("DELETE FROM managed_keys WHERE id='alpha'")
    }
    let deleted = try await f.reader.queryUsage(query)
    #expect(deleted.rows.allSatisfy { $0.principal == nil })
    #expect(deleted.rows.contains { $0.keyID == "ghost" })
    #expect(deleted.rows.first { $0.id == "boundary" }?.totalMilliseconds == 34)
    #expect(deleted.totals.metrics.estimatedMicros == historical.totals.metrics.estimatedMicros)
    #expect(try await f.reader.usageOptions().keyOptions.map(\.principal) == [nil, "beta", nil])
    // Reader rejects corrupted/oversized option sets instead of silently truncating.
    try await f.store.perform { db in
      try db.exec(
        """
        WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<255)
        INSERT INTO managed_keys SELECT 'extra-'||i,printf('%064d',i),metadata_json FROM managed_keys,n WHERE id='beta';
        """)
    }
    #expect(try await f.reader.keyUsage().keys.count == 256)
    try await f.store.perform { db in
      try db.write(
        "INSERT INTO managed_keys SELECT 'overflow',printf('%064d',9999),metadata_json FROM managed_keys WHERE id='beta'"
      )
    }
    await #expect(throws: ExecutionError.capacity) { try await f.reader.keyUsage() }
  } catch {
    await f.close()
    throw error
  }
  await f.close()
}
