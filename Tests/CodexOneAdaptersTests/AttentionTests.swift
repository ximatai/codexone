import CSQLite
import CodexOneCore
import Foundation
import Testing
import Vapor

@testable import CodexOneAdapters

private let attentionNow: Int64 = 1_800_000_000
private func attentionQuota(_ percent: Double, age: Int64 = 0, failed: Bool = false) throws
  -> AccountQuotaObservation
{
  try .init(
    attemptedAtUnixSeconds: attentionNow, observedAtUnixSeconds: attentionNow - age,
    quota: .init(limits: [
      .init(
        id: "codex", allowed: true, limitReached: false,
        primary: .init(
          usedPercent: percent, durationSeconds: 3600, resetsAtUnixSeconds: attentionNow + 1000),
        secondary: nil)
    ]),
    failure: failed ? .unavailable : nil)
}
private func accountItems(
  _ percent: Double = 89, age: Int64 = 0, authorization: AccountAuthorization = .ready,
  cooldown: Int64 = 0, failed: Bool = false
) throws -> [AttentionItem] {
  AttentionRules.account(
    id: "synthetic-account", name: "合成账号", authorization: authorization,
    quota: try attentionQuota(percent, age: age, failed: failed), cooldownCount: cooldown,
    failureAt: attentionNow - 10, now: attentionNow)
}

@Test func attentionAccountAuthorizationAndCooldownBoundaries() throws {
  #expect(try accountItems().isEmpty)
  #expect(try accountItems(authorization: .refreshing).isEmpty)
  #expect(try accountItems(authorization: .requiresAuth).first?.kind == "account_requires_auth")
  #expect(try accountItems(authorization: .requiresAuth).first?.severity == "critical")
  #expect(try accountItems(authorization: .authUncertain).first?.kind == "account_auth_uncertain")
  let cooldown = try accountItems(cooldown: 1)
  #expect(cooldown.first?.kind == "account_cooldown" && cooldown.first?.severity == "warning")
  #expect(cooldown.first?.sinceUnixSeconds == attentionNow - 10)
}
@Test func attentionQuotaPercentageAndFreshnessBoundaries() throws {
  #expect(try accountItems(89).isEmpty)
  #expect(try accountItems(90).first?.severity == "warning")
  #expect(try accountItems(97.99).first?.severity == "warning")
  #expect(try accountItems(98).first?.severity == "critical")
  #expect(try accountItems(98, age: 299).first?.kind == "quota_high")
  #expect(try accountItems(98, age: 300).map(\.kind) == ["quota_stale"])
  #expect(try accountItems(89, age: -1).map(\.kind) == ["quota_stale"])
  #expect(try accountItems(failed: true).map(\.kind) == ["quota_stale"])
  let empty = AttentionRules.account(
    id: "empty", name: nil, authorization: .ready,
    quota: try .init(
      attemptedAtUnixSeconds: nil, observedAtUnixSeconds: nil, quota: nil, failure: nil),
    cooldownCount: 0, failureAt: nil, now: attentionNow)
  #expect(empty.map(\.kind) == ["quota_stale"])
  let noLimits = try AccountQuotaObservation(
    attemptedAtUnixSeconds: attentionNow,
    observedAtUnixSeconds: attentionNow, quota: .init(limits: []), failure: nil)
  let unavailable = AttentionRules.account(
    id: "empty-limits", name: nil, authorization: .ready,
    quota: noLimits, cooldownCount: 0, failureAt: nil, now: attentionNow)
  #expect(
    unavailable.first?.kind == "quota_stale"
      && unavailable.first?.detail["reason"]?.string == "unavailable")

  let quota = try AccountQuotaObservation(
    attemptedAtUnixSeconds: attentionNow, observedAtUnixSeconds: attentionNow,
    quota: .init(limits: [
      .init(
        id: "codex", allowed: true, limitReached: false, primary: nil,
        secondary: .init(usedPercent: 98, durationSeconds: nil, resetsAtUnixSeconds: nil))
    ]), failure: nil)
  #expect(
    AttentionRules.account(
      id: "secondary", name: nil, authorization: .ready, quota: quota,
      cooldownCount: 0, failureAt: nil, now: attentionNow
    ).first?.severity == "critical")
}
private func attentionKey(expires: Int64? = nil, enabled: Bool = true, unlimited: Bool = false)
  throws -> ManagedKey
{
  .init(
    id: "synthetic-key", principal: "synthetic-user", revision: 1, enabled: enabled,
    policy: try .init(
      models: ["synthetic-model"],
      limits: .init(
        requests: unlimited ? nil : 100,
        active: nil, unresolved: nil, budgetMicros: unlimited ? nil : 1000, unresolvedMicros: nil)),
    createdAtUnixSeconds: 1, expiresAtUnixSeconds: expires)
}
@Test func attentionKeyExpirationAndLimitsBoundaries() throws {
  let week = AttentionThresholds.keyExpirationSeconds
  #expect(
    AttentionRules.key(
      try attentionKey(expires: attentionNow + week + 1), requests: 89, budget: 899,
      now: attentionNow
    ).isEmpty)
  #expect(
    AttentionRules.key(
      try attentionKey(expires: attentionNow + week), requests: 0, budget: 0, now: attentionNow
    ).first?.kind == "key_expiring")
  #expect(
    AttentionRules.key(
      try attentionKey(expires: attentionNow - 1), requests: 0, budget: 0, now: attentionNow
    ).first?.kind == "key_expiring")
  #expect(
    AttentionRules.key(
      try attentionKey(expires: attentionNow, enabled: false), requests: 100, budget: 1000,
      now: attentionNow
    ).isEmpty)
  #expect(
    AttentionRules.key(try attentionKey(), requests: 90, budget: 900, now: attentionNow).count == 2)
  #expect(
    AttentionRules.key(
      try attentionKey(unlimited: true), requests: 100000, budget: 100000, now: attentionNow
    ).isEmpty)
}
@Test func attentionExecutionThresholdsAndDeterministicTruncation() {
  #expect(AttentionRules.executions(admitted: 19, failed: 19, unknown: 0, since: nil).isEmpty)
  #expect(AttentionRules.executions(admitted: 20, failed: 1, unknown: 0, since: nil).isEmpty)
  #expect(
    AttentionRules.executions(admitted: 20, failed: 2, unknown: 0, since: nil).first?.kind
      == "error_rate_high")
  #expect(AttentionRules.executions(admitted: 100, failed: 9, unknown: 0, since: nil).isEmpty)
  #expect(
    AttentionRules.executions(admitted: 0, failed: 0, unknown: 512, since: 20).first?.kind
      == "unresolved_executions")
  var many = (0..<60).map { AttentionItem("quota_stale", id: "\($0)", since: Int64($0)) }
  many.append(.init("storage_pressure", critical: true, since: 100))
  many.append(.init("account_requires_auth", critical: true, since: 50))
  let sorted = AttentionAdminAPI.sorted(many)
  #expect(sorted.count == 50)
  #expect(sorted[0].kind == "account_requires_auth" && sorted[1].kind == "storage_pressure")
  #expect(sorted[2].sinceUnixSeconds == 0 && sorted.last?.sinceUnixSeconds == 47)
}
private struct BrokenAttention: AttentionReading {
  let capacity: Bool
  func attentionItems(now: Int64) async throws -> [AttentionItem] {
    if capacity { throw ExecutionError.capacity }
    throw ExecutionError.storageUnavailable
  }
}
private struct AttentionStorage: StorageMonitoring {
  let storageObservation: StorageObservation
  func maintainStorage() async throws {}
}
@Test func attentionSourceFailureStoragePressureAndCapacity() async throws {
  let failure = try await AttentionAdminAPI(reader: BrokenAttention(capacity: false)).items(
    now: attentionNow)
  #expect(failure.count == 4)
  #expect(
    Set(failure.map { $0.detail["source"]?.string ?? "" }) == [
      "accounts", "keys", "executions", "storage",
    ])
  await #expect(throws: ExecutionError.capacity) {
    try await AttentionAdminAPI(reader: BrokenAttention(capacity: true)).items(now: attentionNow)
  }
  for pressure in [StoragePressure.normal, .degraded, .blocked, .unknown] {
    var observation = StorageObservation()
    observation.pressure = pressure
    observation.sampledUnixSeconds = attentionNow
    let items = try await AttentionAdminAPI(
      reader: BrokenAttention(capacity: false),
      storage: AttentionStorage(storageObservation: observation)
    ).items(now: attentionNow)
    #expect(
      items.contains { $0.kind == "storage_pressure" }
        == (pressure == .degraded || pressure == .blocked))
    #expect(items.contains { $0.detail["source"]?.string == "storage" } == (pressure == .unknown))
  }
}

@Test func attentionReaderUsesRollingHourExcludesCancelledAndProtectsMetadata() async throws {
  let path = try temporaryExecutionPath()
  let store = try await SQLiteExecutionStore.open(
    path: path,
    limits: .init(requests: 1000, active: 64, unresolved: 64, budgetMicros: 1_000_000))
  let reader = try await store.makeUsageReader()
  do {
    let policy = try KeyPolicy(
      models: ["synthetic-model"],
      limits: .init(
        requests: 20, active: nil,
        unresolved: nil, budgetMicros: 1000, unresolvedMicros: nil))
    _ = try await store.createKey(
      id: "synthetic-key", principal: "synthetic-user",
      digest: String(repeating: "a", count: 64), policy: policy)
    for i in 0..<20 {
      try await store.admit(
        .init(
          attempt: "attention-\(i)",
          owner: .init(
            principal: "synthetic-user", key: "synthetic-key", namespace: "synthetic",
            identity: "single"),
          window: "utc-day-\(attentionNow / 86400)", policyVersion: "1", pricingVersion: "1",
          reservedMicros: 10,
          model: "synthetic-model"))
      try await store.finalize(
        attempt: "attention-\(i)", evidence: nil,
        outcome: .init(
          failure: i == 0 ? .upstreamUnavailable : i == 1 ? .clientCancelled : nil,
          atUnixSeconds: attentionNow))
    }
    try await store.perform { db in
      try db.write("UPDATE attempts SET created_at_epoch=?", [.number(attentionNow - 3599)])
    }
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await reader.attentionItems(now: attentionNow)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let first = try await reader.attentionItems(now: attentionNow)
    #expect(!first.contains { $0.kind == "error_rate_high" })
    #expect(!first.contains { $0.kind == "unresolved_executions" })
    #expect(
      first.contains { $0.kind == "key_limit_near" && $0.detail["metric"]?.string == "requests" })
    let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
    for forbidden in [
      String(repeating: "a", count: 64), "outcome_json", "envelope", "namespace", "Bearer",
      "refreshToken", "accessToken",
    ] {
      #expect(!encoded.contains(forbidden))
    }
    try await store.perform { db in
      try db.write(
        "UPDATE attempts SET outcome_json=? WHERE id='attention-2'",
        [.text(#"{"kind":"failed","failure":"upstream_unavailable","atUnixSeconds":1800000000}"#)])
    }
    #expect(
      try await reader.attentionItems(now: attentionNow).contains { $0.kind == "error_rate_high" })
    try await store.perform { db in
      try db.write(
        "UPDATE attempts SET created_at_epoch=? WHERE id='attention-2'",
        [.number(attentionNow - 3601)])
    }
    #expect(
      !(try await reader.attentionItems(now: attentionNow)).contains {
        $0.kind == "error_rate_high"
      })
    // A source-specific malformed metadata record must report failure, not an empty source.
    try await store.perform { db in
      try db.write("UPDATE managed_keys SET metadata_json='{}'")
    }
    #expect(
      try await reader.attentionItems(now: attentionNow).contains {
        $0.kind == "attention_source_unavailable" && $0.detail["source"]?.string == "keys"
      })
    await reader.close()
    await store.close()
  } catch {
    await reader.close()
    await store.close()
    throw error
  }
  try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

@Test func attentionAuthenticatedRouteMapsBusyTo429WithoutCSRF() async throws {
  let path = try temporaryExecutionPath()
  let directory = (path as NSString).deletingLastPathComponent
  let secret = "synthetic-attention-admin-secret-for-testing"
  let secretFile = directory + "/admin"
  try Data(secret.utf8).write(to: URL(fileURLWithPath: secretFile))
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile)
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let api = try await KeyAdminAPI.load(
    path: secretFile, store: store,
    attention: AttentionAdminAPI(reader: BrokenAttention(capacity: true)))
  let app = try await Application.make(.testing)
  api.register(app)
  api.bind(port: 19876)
  do {
    var headers = HTTPHeaders()
    headers.add(name: "authorization", value: "Bearer " + secret)
    let request = Request(
      application: app, method: .GET, url: URI(path: "/api/attention"),
      headers: headers, on: app.eventLoopGroup.next())
    let response = try await app.responder.respond(to: request).get()
    #expect(response.status == .tooManyRequests)
    #expect(response.headers.first(name: "cache-control") == "no-store")
    let body = response.body.string ?? ""
    #expect(body.contains("attention_query_capacity") && !body.contains(secret))
    let unauthenticated = Request(
      application: app, method: .GET, url: URI(path: "/api/attention"),
      headers: ["host": "127.0.0.1:19876"], on: app.eventLoopGroup.next())
    #expect(try await app.responder.respond(to: unauthenticated).get().status == .unauthorized)
    try await app.asyncShutdown()
    await store.close()
  } catch {
    try await app.asyncShutdown()
    await store.close()
    throw error
  }
  try? FileManager.default.removeItem(atPath: directory)
}

@Test func attentionReaderAccountsUseNonSecretQuotaAndHealthSnapshots() async throws {
  let path = try temporaryExecutionPath()
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let reader = try await store.makeUsageReader()
  do {
    let envelope =
      "v1." + String(repeating: "a", count: 32) + "."
      + Data(repeating: 7, count: 28).base64EncodedString()
    let account = try await store.createVerifiedAccount(
      id: "synthetic-account", namespace: "synthetic-account-space", envelope: envelope)
    let initial = try await reader.attentionItems(now: attentionNow)
    #expect(initial.map(\.kind) == ["quota_stale"])
    try await store.configureHealthModels(["synthetic-model"])
    let quota = try attentionQuota(98)
    _ = try await store.recordQuotaObservation(
      account: account, atUnixSeconds: attentionNow, result: .success(quota.quota!))
    try await store.perform { db in
      try db.write("UPDATE accounts SET authorization='requires_auth'")
      try db.write(
        "INSERT INTO account_health VALUES(?,NULL,?,?)",
        [.text("synthetic-account"), .text("rate_limited"), .number(attentionNow - 10)])
      try db.write(
        "INSERT INTO account_model_health VALUES(?,?,?,?)",
        [
          .text("synthetic-account"), .text("synthetic-model"), .number(attentionNow + 10),
          .text("rate_limited"),
        ])
    }
    let active = try await reader.attentionItems(now: attentionNow)
    #expect(Set(active.map(\.kind)) == ["quota_high", "account_cooldown", "account_requires_auth"])
    let serialized = String(decoding: try JSONEncoder().encode(active), as: UTF8.self)
    #expect(!serialized.contains(envelope) && !serialized.contains("synthetic-account-space"))
    let afterCooldown = try await reader.attentionItems(now: attentionNow + 10)
    #expect(!afterCooldown.contains { $0.kind == "account_cooldown" })
    try await store.perform { db in
      try db.write("UPDATE accounts SET authorization='auth_uncertain'")
      try db.write("UPDATE account_quota SET record_json='{\"quota\":1}'")
    }
    let broken = try await reader.attentionItems(now: attentionNow)
    #expect(
      broken.contains {
        $0.kind == "attention_source_unavailable" && $0.detail["source"]?.string == "accounts"
      })
    await reader.close()
    await store.close()
  } catch {
    await reader.close()
    await store.close()
    throw error
  }
  try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

@Test func attentionProtocolRegistrySnapshotContainsOnlyNamesAndFirstTimesWithOverflow()
  async throws
{
  let registry = ClientProtocolExtensionRegistry()
  registry.record(name: "x-codex-synthetic", atUnixSeconds: attentionNow - 100)
  registry.record(name: "x-codex-synthetic", atUnixSeconds: attentionNow)
  for index in 0..<31 {
    registry.record(name: "synthetic.control.\(index)", atUnixSeconds: attentionNow - 1)
  }
  registry.record(name: "overflow.control", atUnixSeconds: attentionNow)
  let items = try await AttentionAdminAPI(
    reader: BrokenAttention(capacity: false), registry: registry
  ).items(now: attentionNow)
  let names = items.filter { $0.kind == "client_protocol_extension" }
  #expect(names.count == 32)
  #expect(
    names.allSatisfy {
      $0.severity == "warning" && $0.subjectType == "protocol" && $0.subjectID == nil
        && $0.detail == ["overflow": .bool(true)]
    })
  #expect(
    names.first?.subjectName == "x-codex-synthetic"
      && names.first?.sinceUnixSeconds == attentionNow - 100)
  #expect(!names.contains { $0.subjectName == "overflow.control" })
  let encoded = String(decoding: try JSONEncoder().encode(names), as: UTF8.self)
  #expect(!encoded.contains("headerValue") && !encoded.contains("messageBody"))
}

@Test func attentionLowDiskDoesNotHidePressureBehindReaderCapacity() async throws {
  var observation = StorageObservation()
  observation.pressure = .blocked
  observation.sampledUnixSeconds = attentionNow
  let items = try await AttentionAdminAPI(
    reader: BrokenAttention(capacity: true),
    storage: AttentionStorage(storageObservation: observation)
  ).items(now: attentionNow)
  #expect(items.first?.kind == "storage_pressure" && items.first?.severity == "critical")
  #expect(items.filter { $0.kind == "attention_source_unavailable" }.count == 3)
}

@Test func attentionKeyDisplayNamePrecedesStablePrincipal() throws {
  let key = ManagedKey(
    id: "named-key", principal: "stable-principal", revision: 1,
    enabled: true, policy: try .init(models: ["synthetic-model"], limits: syntheticLimits),
    createdAtUnixSeconds: 1, expiresAtUnixSeconds: attentionNow, displayName: "合成显示名")
  #expect(
    AttentionRules.key(key, requests: 0, budget: 0, now: attentionNow).first?.subjectName == "合成显示名"
  )
}
