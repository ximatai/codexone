import CodexOneCore
import Foundation
import NIOHTTP1
import Synchronization
import Testing

@testable import CodexOneAdapters

@Test func overviewPublishesOnlyCommittedSQLiteChangesAndSkipsZeroViewers() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let time = TestWallClock()
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: time.clock)
  let activity = store.overviewActivity
  let evaluated = Mutex(0)
  activity.publish {
    evaluated.withLock { $0 += 1 }
    return nil
  }
  #expect(evaluated.withLock { $0 } == 0)
  func timed(_ milliseconds: Int64) throws -> ExecutionOutcome {
    try .init(
      failure: nil, atUnixSeconds: time.clock.unixSeconds,
      totalMilliseconds: milliseconds)
  }
  try await store.admit(admission("invisible"))
  try await store.finalize(attempt: "invisible", evidence: usage(), outcome: timed(2000))
  try await store.admit(admission("same-second"))
  try await store.finalize(attempt: "same-second", evidence: usage(), outcome: timed(1000))
  try await store.admit(admission("no-duration"))
  try await store.finalize(attempt: "no-duration", evidence: usage())
  #expect(activity.drain().0.isEmpty)
  let now = time.clock.unixSeconds
  #expect(activity.requestOutputSnapshot(at: now).rate == Decimal(9))
  try await store.admit(admission("late"))
  activity.watch(true)
  try await store.admit(admission("visible"))
  let start = activity.drain().0
  guard case .admitted("visible", _) = start.first else {
    Issue.record("Expected an admission publication")
    return
  }
  #expect(start.count == 1)
  store.executionStarted(attempt: "visible")
  store.executionReceivedFirstEvent(attempt: "visible")
  store.executionReceivedFirstEvent(attempt: "visible")
  let firstEvents = activity.drain().0
  guard case .firstEvent("visible") = firstEvents.first else {
    Issue.record("Expected a first-event publication")
    return
  }
  #expect(firstEvents.count == 1)
  try rawSQL(
    path,
    "CREATE TRIGGER fail_finalize BEFORE INSERT ON evidence BEGIN SELECT RAISE(ABORT,'synthetic'); END;"
  )
  await #expect(throws: ExecutionError.self) {
    try await store.finalize(attempt: "visible", evidence: usage(), outcome: timed(500))
  }
  #expect(activity.drain().0.isEmpty)
  #expect(activity.requestOutputSnapshot(at: now).rate == Decimal(9))
  try rawSQL(path, "DROP TRIGGER fail_finalize;")
  time.advance(seconds: 10)
  try await store.finalize(attempt: "visible", evidence: usage(), outcome: timed(500))
  let finished = activity.drain().0
  guard case .finished("visible") = finished.first else {
    Issue.record("Expected a completion publication")
    return
  }
  #expect(finished.count == 1)
  try await store.finalize(attempt: "visible", evidence: usage())
  try await store.finalize(attempt: "visible", evidence: usage(revision: 2, amount: 15))
  let committedAt = time.clock.unixSeconds
  #expect(activity.requestOutputSnapshot(at: committedAt).rate == Decimal(12))
  let afterIdle = activity.requestOutputSnapshot(at: committedAt + 60)
  #expect(afterIdle.rate == nil)
  #expect(afterIdle.days.values.first == .number(12))

  time.advance(seconds: 60)
  try await store.finalize(attempt: "late", evidence: usage(complete: false), outcome: timed(2000))
  let cutoff = time.clock.unixSeconds + 1
  #expect(try await store.releaseUnknown(beforeUnixSeconds: cutoff, expectedCount: 1) == 1)
  #expect(activity.requestOutputSnapshot(at: time.clock.unixSeconds).rate == nil)
  try await store.finalize(attempt: "late", evidence: usage(revision: 2))
  try await store.finalize(attempt: "late", evidence: usage(revision: 3, amount: 15))
  #expect(activity.requestOutputSnapshot(at: time.clock.unixSeconds).rate == Decimal(6))
  await store.close()
}

@Test func outputRateHistorySurvivesV12UpgradeAndRestart() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let time = TestWallClock()
  func open(automatic: Bool = true) async throws -> SQLiteExecutionStore {
    try await SQLiteExecutionStore.open(
      path: path, limits: syntheticLimits, clock: time.clock,
      allowStartupMigration: automatic)
  }
  func timed(_ milliseconds: Int64) throws -> ExecutionOutcome {
    try .init(failure: nil, atUnixSeconds: time.clock.unixSeconds, totalMilliseconds: milliseconds)
  }
  let original = try await open()
  try await original.admit(admission("legacy"))
  try await original.finalize(attempt: "legacy", evidence: usage(), outcome: timed(1000))
  await original.close()
  try rawSQL(path, removeOutputRateSchema + "PRAGMA user_version=12")
  await #expect(throws: ExecutionError.incompatibleSchema) { try await open(automatic: false) }

  // Force the DDL transaction to fail after ALTER TABLE has already executed.
  try rawSQL(path, "CREATE INDEX attempts_output_rate ON attempts(id)")
  await #expect(throws: StartupMigrationError.transactionFailed) { try await open() }
  let failed = try SQLiteConnection(readOnlyPath: path)
  #expect(try failed.scalar("PRAGMA user_version") == 12)
  #expect(
    try failed.scalar("SELECT COUNT(*) FROM pragma_table_info('attempts') WHERE name='output_rate'")
      == 0)
  failed.shutdown()
  try rawSQL(path, "DROP INDEX attempts_output_rate")
  let folder = (path as NSString).deletingLastPathComponent
  func backups() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.contains(".pre-v13-") }
  }
  #expect(try backups().count == 1)

  let upgraded = try await open()
  #expect(try backups().count == 2)
  for backup in try backups() {
    let source = try SQLiteConnection(readOnlyPath: folder + "/" + backup)
    #expect(try source.scalar("PRAGMA user_version") == 12)
    #expect(try source.scalar("SELECT COUNT(*) FROM attempts WHERE id='legacy'") == 1)
    source.shutdown()
  }
  #expect(try await upgraded.snapshot(attempt: "legacy").state == .settled)
  #expect(upgraded.overviewActivity.requestOutputSnapshot(at: time.clock.unixSeconds).days.isEmpty)
  try await upgraded.admit(admission("first-day"))
  try await upgraded.finalize(attempt: "first-day", evidence: usage(), outcome: timed(2000))
  time.advance(seconds: 86400)
  try await upgraded.admit(admission("second-day"))
  try await upgraded.finalize(attempt: "second-day", evidence: usage(), outcome: timed(1000))
  let now = time.clock.unixSeconds
  let before = upgraded.overviewActivity.requestOutputSnapshot(at: now)
  #expect(before.rate == Decimal(12))
  #expect(before.days.count == 2)
  await upgraded.close()

  let reopened = try await open()
  #expect(try backups().count == 2)
  let restored = reopened.overviewActivity.requestOutputSnapshot(at: now)
  #expect(restored.days == before.days)
  #expect(restored.hours == before.hours)
  #expect(restored.rate == nil)
  try await reopened.finalize(attempt: "second-day", evidence: usage(revision: 2, amount: 30))
  #expect(reopened.overviewActivity.requestOutputSnapshot(at: now).days == before.days)
  #expect(reopened.overviewActivity.requestOutputSnapshot(at: now).rate == nil)
  await reopened.close()
}

@Test func outputRateHoursKeepThePartialEighthDayAndOmitEmptyHours() throws {
  let activity = OverviewActivity()
  let now = testUnixSeconds / 86400 * 86400 + 3600
  let first = now - 167 * 3600
  for (index, sample) in [(first - 3600, 9), (first, 4), (first + 15, 8), (now, 20)].enumerated() {
    activity.recordRequestOutput(
      Decimal(sample.1), at: sample.0, rowID: Int64(index + 1))
  }
  let history = activity.requestOutputSnapshot(at: now).hours
  let points = try #require(history["points"]?.object)
  #expect(history["endUnixSeconds"]?.integer == now)
  #expect(points.count == 2)
  #expect(points[String(first)]?["median"]?.integer == 6)
  #expect(points[String(first)]?["count"]?.integer == 2)
  #expect(points[String(now)]?["median"]?.integer == 20)
}

@Test func outputRateHourlyCapDoesNotEvictEarlierHoursAfterRestart() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let morning = testUnixSeconds / 86400 * 86400
  let peak = morning + 3600
  let time = TestWallClock(peak)
  let day = try BusinessDayDefinition(offsetMinutes: 480)
  func open() async throws -> SQLiteExecutionStore {
    try await SQLiteExecutionStore.open(
      path: path, limits: syntheticLimits, clock: time.clock, businessDay: day)
  }
  let store = try await open()
  let activity = store.overviewActivity
  activity.recordRequestOutput(12, at: morning, rowID: 1)
  for i in 2...4098 {
    activity.recordRequestOutput(i < 4000 ? 1 : 20, at: peak, rowID: Int64(i))
  }
  let before = activity.requestOutputSnapshot(at: peak).hours
  let points = try #require(before["points"]?.object)
  #expect(before["offsetMinutes"]?.integer == 480)
  #expect(points[String(morning)]?["median"]?.integer == 12)
  #expect(points[String(peak)]?["median"]?.integer == 1)
  #expect(points[String(peak)]?["count"]?.integer == 256)
  await store.close()
  try rawSQL(
    path,
    """
    WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4098)
    INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,reserved,state,admission_json,output_rate_settled_at,output_rate)
    SELECT 'synthetic-hourly-'||i,'synthetic','synthetic','synthetic','synthetic','synthetic','1','1',1,'settled','{}',
           CASE WHEN i=1 THEN \(morning) ELSE \(peak) END,
           CASE WHEN i=1 THEN '12' WHEN i<4000 THEN '1' ELSE '20' END FROM n ORDER BY i;
    """)
  let restored = try await open()
  #expect(restored.overviewActivity.requestOutputSnapshot(at: peak).hours == before)
  await restored.close()
}

@Test func outputRateDailyCapBreaksSettlementTiesInRecoveryOrder() {
  let activity = OverviewActivity()
  let now = testUnixSeconds
  // The later admission settles first, but wins the final slot in both live and recovery order.
  activity.recordRequestOutput(3, at: now, rowID: 2)
  activity.recordRequestOutput(1, at: now, rowID: 1)
  for i in 3...4097 {
    activity.recordRequestOutput(i < 2050 ? 1 : 3, at: now + 1, rowID: Int64(i))
  }
  #expect(activity.requestOutputSnapshot(at: now + 1).days.values.first == .number(3))
}

@Test func overviewSamplerSharesSQLiteReadsAndJoinsLastViewer() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let reader = try await store.makeUsageReader()
  let usageAPI = UsageAdminAPI(querying: reader)
  let reads = Mutex([String: Int]())
  let time = Mutex(Int64(Date().timeIntervalSince1970))
  let overview = OverviewLive(
    activity: store.overviewActivity,
    read: { name in
      reads.withLock { $0[name, default: 0] += 1 }
      if ["inFlight", "daily", "keys", "headroom"].contains(name) {
        return try await usageAPI.overviewSection(name)
      }
      return try JSONValue.object([:]).data()
    }, now: { time.withLock { $0 } })
  let worker = Task { try await overview.run() }
  var ids: [UUID] = []
  var boxes: [OverviewMailbox] = []
  let first = OverviewMailbox { _ in }
  let id = UUID()
  ids.append(id)
  boxes.append(first)
  try await overview.subscribe(id: id, mailbox: first)
  let snapshot = await first.next()
  #expect(snapshot?.snapshot == true)
  let initialReads = reads.withLock { $0 }
  time.withLock { $0 += 5 }
  store.overviewActivity.signal.yield(.tick)
  let freshness = try JSONValue.decode(try #require(await first.next()).data)
  #expect(freshness["daily"]?["data"] == nil)
  #expect(freshness["daily"]?["lastSuccessAt"] != nil)
  let baseline = reads.withLock { $0 }
  let singleDelta = baseline.mapValues { $0 }.map {
    ($0.key, $0.value - (initialReads[$0.key] ?? 0))
  }

  for _ in 1..<8 {
    let box = OverviewMailbox { _ in }
    let id = UUID()
    ids.append(id)
    boxes.append(box)
    try await overview.subscribe(id: id, mailbox: box)
    #expect(await box.next()?.snapshot == true)
  }
  #expect(reads.withLock { $0 } == baseline)
  time.withLock { $0 += 5 }
  store.overviewActivity.signal.yield(.tick)
  _ = await first.next()
  let eightReads = reads.withLock { $0 }
  for (name, delta) in singleDelta {
    #expect((eightReads[name] ?? 0) - (baseline[name] ?? 0) == delta)
  }

  // Lose the publication deliberately; the next SQL reconciliation still restores durable intent.
  store.overviewActivity.watch(false)
  try await store.admit(admission("lost-wakeup"))
  store.overviewActivity.watch(true)
  time.withLock { $0 += 5 }
  store.overviewActivity.signal.yield(.tick)
  let reconciled = try JSONValue.decode(try #require(await first.next()).data)
  #expect(
    reconciled["inFlight"]?["data"]?["rows"]?.array?.contains(where: {
      $0["id"]?.string == "lost-wakeup"
    }) == true)
  try await store.finalize(attempt: "lost-wakeup", evidence: usage())
  let completion = try JSONValue.decode(try #require(await first.next()).data)
  #expect(completion["inFlight"]?["data"]?["rows"]?.array == [])
  #expect(completion["inFlight"]?["data"]?["recentlyFinished"]?.array == [])
  for id in ids { await overview.unsubscribe(id: id) }
  let stopped = reads.withLock { $0 }
  try await Task.sleep(for: .milliseconds(1200))
  #expect(reads.withLock { $0 } == stopped)
  worker.cancel()
  try await worker.value
  await overview.shutdown()
  await reader.close()
  await store.close()
}

@Test func overviewStormHasBoundedEventsAndMailboxClosesOverflow() async throws {
  let activity = OverviewActivity()
  activity.watch(true)
  for _ in 0..<10000 {
    activity.publish { .firstEvent(id: "synthetic") }
  }
  let drained = activity.drain()
  #expect(drained.0.count == 512 && drained.1 == 9488)
  let codes = Mutex([UInt16]())
  let box = OverviewMailbox { code in codes.withLock { $0.append(code) } }
  for _ in 0..<3 { box.offer(.init(snapshot: false, data: Data(repeating: 1, count: 1_048_000))) }
  #expect(codes.withLock { $0 } == [1013])
  #expect(await box.next() == nil)
}

@Test func overviewSQLiteFailureStaysUnavailableAcrossActivityAndRecovers() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let reader = try await store.makeUsageReader()
  let usageAPI = UsageAdminAPI(querying: reader)
  let time = Mutex(Int64(1000))
  let overview = OverviewLive(
    activity: store.overviewActivity,
    read: { name in
      if name == "inFlight" { return try await usageAPI.overviewSection(name) }
      return try JSONValue.object([:]).data()
    }, now: { time.withLock { $0 } })
  // An actual SQLite read failure, not an encoded synthetic error response.
  try rawSQL(path, "ALTER TABLE attempts RENAME TO synthetic_unavailable_attempts")
  let worker = Task { try await overview.run() }
  let box = OverviewMailbox { _ in }
  let viewer = UUID()
  try await overview.subscribe(id: viewer, mailbox: box)
  let initial = try JSONValue.decode(try #require(await box.next()).data)
  #expect(initial["inFlight"]?["freshness"]?.string == "unavailable")
  #expect(initial["inFlight"]?["data"] == .null)
  #expect(initial["inFlight"]?["lastSuccessAt"] == .null)

  try rawSQL(path, "ALTER TABLE synthetic_unavailable_attempts RENAME TO attempts")
  time.withLock { $0 += 5 }
  store.overviewActivity.signal.yield(.tick)
  let recovered = try JSONValue.decode(try #require(await box.next()).data)
  #expect(recovered["inFlight"]?["freshness"]?.string == "fresh")
  #expect(recovered["inFlight"]?["data"]?["rows"]?.array == [])
  let lastSuccess = recovered["inFlight"]?["lastSuccessAt"]

  try rawSQL(path, "ALTER TABLE attempts RENAME TO synthetic_unavailable_attempts")
  time.withLock { $0 += 5 }
  let client = try #require(
    store.overviewActivity.register(key: "synthetic-key", name: nil, capacity: 1))
  store.overviewActivity.signal.yield(.tick)
  let failed = try JSONValue.decode(try #require(await box.next()).data)
  #expect(failed["inFlight"]?["freshness"]?.string == "stale")
  #expect(failed["inFlight"]?["lastSuccessAt"] == lastSuccess)
  #expect(failed["inFlight"]?["data"]?["clients"]?.array?.count == 1)
  store.overviewActivity.unregister(client)
  try rawSQL(path, "ALTER TABLE synthetic_unavailable_attempts RENAME TO attempts")
  await overview.unsubscribe(id: viewer)
  worker.cancel()
  try await worker.value
  await overview.shutdown()
  await reader.close()
  await store.close()
}

@Test func liveSessionTouchPreservesAbsoluteExpiryAndRevocationIsSynchronous() throws {
  let time = Mutex(ContinuousClock.now)
  let sessions = try AdminSessions(
    digest: keyDigest("synthetic-live-admin-credential-for-tests"), publicOrigin: nil,
    now: { time.withLock { $0 } })
  sessions.bind(port: 19876)
  let headers: HTTPHeaders = ["host": "127.0.0.1:19876", "origin": "http://127.0.0.1:19876"]
  let created = try sessions.login(
    username: "admin", secret: "synthetic-live-admin-credential-for-tests", headers: headers)
  var authorized = headers
  authorized.add(name: "cookie", value: AdminSessions.cookieName + "=" + created.token)
  let codes = Mutex([UInt16]())
  let id = UUID()
  try sessions.bindLive(authorized, id: id) { code in codes.withLock { $0.append(code) } }
  for _ in 0..<7 {
    time.withLock { $0 = $0.advanced(by: .seconds(23 * 3600)) }
    #expect(sessions.withLive(id, touch: true))
  }
  time.withLock { $0 = $0.advanced(by: .seconds(7 * 3600)) }
  #expect(!sessions.withLive(id, touch: true))
  sessions.bind(port: 19876)
  #expect(codes.withLock { $0 } == [1008])
}

@Test func overviewShutdownCancelsOwnedReadBeforeClosingViewers() async throws {
  let cancellation = Mutex(false)
  let (started, ready) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
  let overview = OverviewLive(activity: OverviewActivity()) { _ in
    ready.yield(())
    return try await withTaskCancellationHandler {
      try await Task.sleep(for: .seconds(60))
      return Data()
    } onCancel: {
      cancellation.withLock { $0 = true }
    }
  }
  let mailbox = OverviewMailbox { _ in }
  let worker = Task { try await overview.run() }
  try await overview.subscribe(id: UUID(), mailbox: mailbox)
  var iterator = started.makeAsyncIterator()
  _ = await iterator.next()
  worker.cancel()
  try await worker.value
  await overview.shutdown()
  #expect(cancellation.withLock { $0 })
  #expect(await mailbox.next() == nil)
  ready.finish()
}

@Test func imageGenerationDoesNotDistortOutputRatesAcrossRestartAndRevision() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let time = TestWallClock()
  func open() async throws -> SQLiteExecutionStore {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits, clock: time.clock)
  }
  func toolAdmission(_ id: String) throws -> ExecutionAdmission {
    .init(
      attempt: id, owner: .init(principal: "p", key: "key", namespace: "synthetic", identity: "i"),
      window: "w", policyVersion: "policy-v1", pricingVersion: "price-v1", reservedMicros: 10,
      requirements: try .init(route: .conversation, imageModel: "synthetic-image"))
  }
  func evidence(_ images: Int64, revision: Int64 = 1) -> UsageEvidence {
    .init(
      revision: revision, inputTokens: 12, outputTokens: 12, cachedTokens: 0,
      images: images, estimatedMicros: 12, completeness: .complete)
  }
  let store = try await open()
  let outcome = try ExecutionOutcome(
    failure: nil, atUnixSeconds: time.clock.unixSeconds, totalMilliseconds: 1000)
  try await store.admit(toolAdmission("text"))
  try await store.finalize(attempt: "text", evidence: evidence(0), outcome: outcome)
  try await store.admit(toolAdmission("image"))
  try await store.finalize(attempt: "image", evidence: evidence(1), outcome: outcome)
  #expect(store.overviewActivity.requestOutputSnapshot(at: time.clock.unixSeconds).rate == 12)
  try await store.admit(toolAdmission("revised"))
  try await store.finalize(attempt: "revised", evidence: evidence(0), outcome: outcome)
  try await store.finalize(attempt: "revised", evidence: evidence(1, revision: 2))
  let before = store.overviewActivity.requestOutputSnapshot(at: time.clock.unixSeconds)
  #expect(before.rate == 12)
  #expect(before.hours["points"]?.object?.values.first?["count"]?.integer == 1)
  await store.close()
  // Simulate historical rows written before this filtering rule was introduced.
  try rawSQL(
    path,
    "UPDATE attempts SET output_rate_settled_at=\(time.clock.unixSeconds), output_rate='1' WHERE id='image'"
  )
  let reopened = try await open()
  let restored = reopened.overviewActivity.requestOutputSnapshot(at: time.clock.unixSeconds)
  #expect(restored.days == before.days)
  #expect(restored.hours == before.hours)
  await reopened.close()
}

@Test func imageRevisionRefillsFullOutputRateBuckets() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let time = TestWallClock()
  func open() async throws -> SQLiteExecutionStore {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits, clock: time.clock)
  }
  let seed = try await open()
  try await seed.admit(admission("revised-full"))
  let outcome = try ExecutionOutcome(
    failure: nil, atUnixSeconds: time.clock.unixSeconds, totalMilliseconds: 1000)
  try await seed.finalize(attempt: "revised-full", evidence: usage(), outcome: outcome)
  await seed.close()
  let timestamp = time.clock.unixSeconds
  try rawSQL(
    path,
    """
    WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4096)
    INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,reserved,state,admission_json,output_rate_settled_at,output_rate)
    SELECT 'refill-'||i,'synthetic','synthetic','synthetic','synthetic','synthetic','1','1',1,'settled','{}',\(timestamp - 1),'1' FROM n
    """)
  let store = try await open()
  let before = store.overviewActivity.requestOutputSnapshot(at: timestamp)
  #expect(before.hours["points"]?.object?.values.first?["count"]?.integer == 256)
  let image = UsageEvidence(
    revision: 2, inputTokens: 12, outputTokens: 12, cachedTokens: 0,
    images: 1, estimatedMicros: 12, completeness: .complete)
  try await store.finalize(attempt: "revised-full", evidence: image)
  let corrected = store.overviewActivity.requestOutputSnapshot(at: timestamp)
  #expect(corrected.hours["points"]?.object?.values.first?["count"]?.integer == 256)
  #expect(corrected.hours["points"]?.object?.values.first?["median"]?.integer == 1)
  await store.close()
  let restarted = try await open()
  let restored = restarted.overviewActivity.requestOutputSnapshot(at: timestamp)
  #expect(restored.hours == corrected.hours)
  #expect(restored.days == corrected.days)
  await restarted.close()
}
