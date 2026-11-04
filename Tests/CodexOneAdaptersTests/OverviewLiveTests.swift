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
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let activity = store.overviewActivity
  let evaluated = Mutex(0)
  activity.publish {
    evaluated.withLock { $0 += 1 }
    return nil
  }
  #expect(evaluated.withLock { $0 } == 0)
  try await store.admit(admission("invisible"))
  try await store.finalize(attempt: "invisible", evidence: usage())
  #expect(activity.drain().0.isEmpty)
  activity.watch(true)
  try await store.admit(admission("visible"))
  let start = activity.drain().0
  #expect(start.count == 1 && start[0].id == "visible" && start[0].outcome == nil)
  store.executionStarted(attempt: "visible")
  store.executionReceivedFirstEvent(attempt: "visible")
  store.executionReceivedFirstEvent(attempt: "visible")
  let firstEvents = activity.drain().0
  #expect(firstEvents.count == 1 && firstEvents.first?.first == true)
  try rawSQL(
    path,
    "CREATE TRIGGER fail_finalize BEFORE INSERT ON evidence BEGIN SELECT RAISE(ABORT,'synthetic'); END;"
  )
  await #expect(throws: ExecutionError.self) {
    try await store.finalize(attempt: "visible", evidence: usage())
  }
  #expect(activity.drain().0.isEmpty)
  await store.close()
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
    activity.publish { .init(id: "synthetic", row: nil, outcome: nil, at: 1, first: true) }
  }
  let drained = activity.drain()
  #expect(drained.0.count == 512 && drained.1 == 9488)
  let codes = Mutex([UInt16]())
  let box = OverviewMailbox { code in codes.withLock { $0.append(code) } }
  for _ in 0..<3 { box.offer(.init(snapshot: false, data: Data(repeating: 1, count: 1_048_000))) }
  #expect(codes.withLock { $0 } == [1013])
  #expect(await box.next() == nil)
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
