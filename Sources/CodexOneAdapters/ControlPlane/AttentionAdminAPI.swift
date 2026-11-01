import CodexOneCore
import Foundation
import Vapor

/// A sanitized observation. Detail values are constructed from fixed enums or numbers only.
public struct AttentionItem: Sendable, Encodable {
  public let kind: String
  public let severity: String
  public let subjectType: String
  public let subjectID: String?
  public let subjectName: String?
  let detail: [String: JSONValue]
  public let sinceUnixSeconds: Int64?

  init(
    _ kind: String, critical: Bool = false, type: String = "system", id: String? = nil,
    name: String? = nil, detail: [String: JSONValue] = [:], since: Int64? = nil
  ) {
    self.kind = kind
    self.severity = critical ? "critical" : "warning"
    self.subjectType = type
    self.subjectID = id
    self.subjectName = name
    self.detail = detail
    self.sinceUnixSeconds = since
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(kind, forKey: .kind)
    try values.encode(severity, forKey: .severity)
    try values.encode(subjectType, forKey: .subjectType)
    try values.encode(subjectID, forKey: .subjectID)
    try values.encode(subjectName, forKey: .subjectName)
    try values.encode(detail, forKey: .detail)
    try values.encode(sinceUnixSeconds, forKey: .sinceUnixSeconds)
  }
  private enum CodingKeys: String, CodingKey {
    case kind, severity, subjectType, subjectID, subjectName, detail, sinceUnixSeconds
  }
  static func unavailable(_ source: String) -> Self {
    .init("attention_source_unavailable", detail: ["source": .string(source)])
  }
}

public protocol AttentionReading: Sendable {
  func attentionItems(now: Int64) async throws -> [AttentionItem]
}

enum AttentionThresholds {
  static let capacityWarning = 0.8
  static let unknownPercent = 20.0
  static let minimumUnknown: Int64 = 10
  static let rateWindowSeconds: Int64 = 600
  static let rateMinimum: Int64 = 60
  static let rateMultiplier: Int64 = 5
  static let rankingWindowSeconds: Int64 = 5 * 3600
  static let maximumItems = 50
  static let quotaWarning = 90.0
  static let quotaCritical = 98.0
  static let keyExpirationSeconds: Int64 = 7 * 86400
  static let errorWindowSeconds: Int64 = 3600
  static let minimumAdmitted: Int64 = 20
  static let errorPercent = 10.0
}

public struct AttentionAdminAPI: Sendable {
  private let clock: WallClock
  private let reader: any AttentionReading
  private let storage: (any StorageMonitoring)?
  private let backup: (any BackupMaintaining)?
  private let registry: ClientProtocolExtensionRegistry?
  public init(
    reader: any AttentionReading, storage: (any StorageMonitoring)? = nil,
    registry: ClientProtocolExtensionRegistry? = nil, backup: (any BackupMaintaining)? = nil,
    clock: WallClock = .system
  ) {
    self.clock = clock
    self.reader = reader
    self.storage = storage
    self.registry = registry
    self.backup = backup
  }
  func register(_ routes: any RoutesBuilder) {
    routes.get("attention") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      do {
        let now = clock.unixSeconds
        let items = try await self.items(now: now)
        return Response(
          status: .ok, headers: ["content-type": "application/json", "cache-control": "no-store"],
          body: .init(
            data: try JSONValue.object([
              "items": try JSONValue.decode(JSONEncoder().encode(items)),
              "generatedAtUnixSeconds": .number(Decimal(now)),
            ]).data()))
      } catch ExecutionError.capacity {
        throw GatewayProtocolError(429, "attention_query_capacity")
      }
    }
  }
  func items(now: Int64) async throws -> [AttentionItem] {
    var items: [AttentionItem]
    do {
      if let storage, !storage.storageObservation.optionalWorkAllowed {
        items = [.unavailable("accounts"), .unavailable("keys"), .unavailable("executions")]
      } else {
        items = try await reader.attentionItems(now: now)
      }
    } catch is CancellationError { throw CancellationError() } catch ExecutionError.capacity {
      throw ExecutionError.capacity
    } catch {
      items = [.unavailable("accounts"), .unavailable("keys"), .unavailable("executions")]
    }
    if let storage {
      let observation = storage.storageObservation
      if observation.pressure == .unknown || !observation.coreAvailable {
        items.append(.unavailable("storage"))
      }
      if observation.pressure == .degraded || observation.pressure == .blocked {
        items.append(
          .init(
            "storage_pressure", critical: true,
            detail: ["pressure": .string(observation.pressure.rawValue)],
            since: observation.sampledUnixSeconds > 0 ? observation.sampledUnixSeconds : nil))
      }
    } else {
      items.append(.unavailable("storage"))
    }
    if let registry {
      let snapshot = registry.snapshot()
      items += snapshot.entries.map {
        .init(
          "client_protocol_extension", type: "protocol", name: $0.name,
          detail: ["overflow": .bool(snapshot.overflow)], since: $0.firstSeenUnixSeconds)
      }
    }
    items += AttentionRules.backup(backup?.backupObservation ?? BackupObservation(), now: now)
    return Self.sorted(items)
  }
  static func sorted(_ items: [AttentionItem]) -> [AttentionItem] {
    Array(
      items.sorted {
        if $0.severity != $1.severity { return $0.severity == "critical" }
        if $0.sinceUnixSeconds != $1.sinceUnixSeconds {
          return ($0.sinceUnixSeconds ?? Int64.max) < ($1.sinceUnixSeconds ?? Int64.max)
        }
        return [$0.kind, $0.subjectID ?? "", $0.subjectName ?? ""].lexicographicallyPrecedes(
          [$1.kind, $1.subjectID ?? "", $1.subjectName ?? ""])
      }.prefix(AttentionThresholds.maximumItems))
  }
}

// Pure decisions shared by the bounded reader and boundary tests.
enum AttentionRules {
  static func backup(_ observation: BackupObservation, now: Int64) -> [AttentionItem] {
    guard observation.enabled else { return [.init("backup_disabled")] }
    var items: [AttentionItem] = []
    let since = observation.lastSuccessUnixSeconds ?? observation.enabledUnixSeconds
    if now - since > 36 * 3600 {
      items.append(.init("backup_stale", critical: now - since > 72 * 3600, since: since))
    }
    if observation.totalBytes > 5 * 1024 * 1024 * 1024
      || observation.largestBundleBytes > 768 * 1024 * 1024
    {
      items.append(
        .init(
          "backup_size",
          detail: [
            "totalBytes": .number(Decimal(observation.totalBytes)),
            "largestBundleBytes": .number(Decimal(observation.largestBundleBytes)),
          ]))
    }
    return items
  }

  static func account(
    id: String, name: String?, authorization: AccountAuthorization,
    quota: AccountQuotaObservation?, cooldownCount: Int64, failureAt: Int64?, now: Int64
  ) -> [AttentionItem] {
    var result: [AttentionItem] = []
    func add(
      _ kind: String, critical: Bool = false, detail: [String: JSONValue] = [:], since: Int64? = nil
    ) {
      result.append(
        .init(
          kind, critical: critical, type: "account", id: id, name: name,
          detail: detail, since: since))
    }
    if authorization == .requiresAuth { add("account_requires_auth", critical: true) }
    if authorization == .authUncertain { add("account_auth_uncertain", critical: true) }
    if cooldownCount > 0 {
      add("account_cooldown", detail: ["count": .number(Decimal(cooldownCount))], since: failureAt)
    }
    if let quota {
      let hasData =
        quota.quota?.limits.contains {
          $0.allowed != nil || $0.limitReached != nil || $0.primary != nil || $0.secondary != nil
        } ?? false
      if quota.failure != nil || !quota.isFresh(at: now) || !hasData {
        add(
          "quota_stale",
          detail: [
            "reason": .string(
              quota.failure != nil ? "failed" : !hasData ? "unavailable" : "stale")
          ],
          since: quota.failure != nil ? quota.attemptedAtUnixSeconds : quota.observedAtUnixSeconds)
      }
      if quota.isFresh(at: now), let limits = quota.quota?.limits {
        let maximum = limits.flatMap { [$0.primary?.usedPercent, $0.secondary?.usedPercent] }
          .compactMap { $0 }.max()
        if let maximum, maximum >= AttentionThresholds.quotaWarning {
          add(
            "quota_high", critical: maximum >= AttentionThresholds.quotaCritical,
            detail: ["usedPercent": .number(Decimal(maximum))], since: quota.observedAtUnixSeconds)
        }
      }
    }
    return result
  }
  static func key(_ key: ManagedKey, requests: Int64, budget: Int64, now: Int64) -> [AttentionItem]
  {
    guard key.enabled, key.archivedAtUnixSeconds == nil else { return [] }
    var result: [AttentionItem] = []
    if let expiration = key.expiresAtUnixSeconds,
      expiration <= now + AttentionThresholds.keyExpirationSeconds
    {
      result.append(
        .init(
          "key_expiring", type: "key", id: key.id, name: key.displayName ?? key.principal,
          detail: ["expiresAtUnixSeconds": .number(Decimal(expiration))], since: expiration))
    }
    for (metric, value, limit) in [
      ("requests", requests, key.policy.limits.requests),
      ("budgetMicros", budget, key.policy.limits.budgetMicros),
    ] {
      if let limit, Double(value) / Double(limit) * 100 >= AttentionThresholds.quotaWarning {
        result.append(
          .init(
            "key_limit_near", type: "key", id: key.id, name: key.displayName ?? key.principal,
            detail: [
              "metric": .string(metric),
              "usedPercent": .number(Decimal(Double(value) / Double(limit) * 100)),
            ]))
      }
    }
    return result
  }
  static func capacity(_ value: GovernanceCapacity) -> [AttentionItem] {
    guard let current = value.current,
      Double(current) / Double(value.limit) >= AttentionThresholds.capacityWarning
    else { return [] }
    return [
      .init(
        "capacity_reference",
        detail: [
          "metric": .string(value.name), "current": .string(String(current)),
          "limit": .string(String(value.limit)), "exceeded": .bool(current > value.limit),
        ])
    ]
  }
  static func accountCapacity(id: String, peak: Int64, recent: Int64, baseline: Int64)
    -> [AttentionItem]
  {
    var items: [AttentionItem] = []
    if Double(peak) / Double(ExecutionLimits.accountConcurrency)
      >= AttentionThresholds.capacityWarning
    {
      items.append(
        .init(
          "account_concurrency_high", type: "account", id: id,
          detail: [
            "peak": .number(Decimal(peak)),
            "limit": .number(Decimal(ExecutionLimits.accountConcurrency)),
          ]))
    }
    if recent >= AttentionThresholds.rateMinimum
      && recent >= baseline * AttentionThresholds.rateMultiplier
    {
      items.append(
        .init(
          "account_rate_surge", type: "account", id: id,
          detail: ["count": .number(Decimal(recent)), "median": .number(Decimal(baseline))]))
    }
    return items
  }
  static func executions(
    admitted: Int64, failed: Int64, unknown: Int64, since: Int64?, unresolved: Int64? = nil,
    limit: Int64 = ExecutionLimits.unresolvedCapacity
  )
    -> [AttentionItem]
  {
    var items: [AttentionItem] = []
    if unknown >= AttentionThresholds.minimumUnknown, admitted > 0,
      Double(unknown) / Double(admitted) * 100 >= AttentionThresholds.unknownPercent
    {
      items.append(
        .init(
          "observation_quality",
          detail: [
            "count": .number(Decimal(unknown)), "admitted": .number(Decimal(admitted)),
            "percent": .number(Decimal(Double(unknown) / Double(admitted) * 100)),
          ], since: since))
    }
    if admitted >= AttentionThresholds.minimumAdmitted,
      Double(failed) / Double(admitted) * 100 >= AttentionThresholds.errorPercent
    {
      items.append(
        .init(
          "error_rate_high", critical: true,
          detail: [
            "admitted": .number(Decimal(admitted)), "failed": .number(Decimal(failed)),
            "percent": .number(Decimal(Double(failed) / Double(admitted) * 100)),
          ]))
    }
    return items
  }
}
