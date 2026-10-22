import CodexOneCore
import Foundation

func accountObservationDTO(
  _ quota: AccountQuotaObservation, health: AccountHealth, observing: Bool,
  detail: Bool, now: Int64 = Int64(Date().timeIntervalSince1970)
) -> JSONValue {
  func time(_ value: Int64?) -> JSONValue { value.map { .number(Decimal($0)) } ?? .null }
  func window(_ value: SubscriptionQuotaWindow?) -> JSONValue {
    guard let value else { return .null }
    return .object([
      "usedPercent": value.usedPercent.map { .number(Decimal($0)) } ?? .null,
      "durationSeconds": time(value.durationSeconds),
      "resetsAtUnixSeconds": time(value.resetsAtUnixSeconds),
    ])
  }
  let limits = quota.quota?.limits ?? []
  let hasData = limits.contains {
    $0.allowed != nil || $0.limitReached != nil || $0.primary != nil || $0.secondary != nil
  }
  let state = !hasData ? "unavailable" : quota.isFresh(at: now) ? "fresh" : "stale"
  let age = quota.observedAtUnixSeconds.flatMap { now >= $0 ? now - $0 : nil }
  let snapshot: JSONValue = .object([
    "state": .string(state), "observedAtUnixSeconds": time(quota.observedAtUnixSeconds),
    "attemptedAtUnixSeconds": time(quota.attemptedAtUnixSeconds),
    "ageSeconds": time(age), "freshForSeconds": .number(Decimal(age.map { max(0, 300 - $0) } ?? 0)),
    "failure": quota.failure.map { .string($0.rawValue) } ?? .null,
    "additionalCount": .number(Decimal(limits.filter { $0.id != "codex" }.count)),
    "limits": .array(
      limits.filter { detail || $0.id == "codex" }.map { value in
        .object([
          "id": .string(value.id), "allowed": value.allowed.map { .bool($0) } ?? .null,
          "limitReached": value.limitReached.map { .bool($0) } ?? .null,
          "primary": window(value.primary), "secondary": window(value.secondary),
        ])
      }),
  ])
  var healthDTO: [String: JSONValue] = [
    "authenticationRejected": .bool(health.authenticationRejected),
    "lastFailure": health.lastFailure.map { .string($0.rawValue) } ?? .null,
    "lastFailureAtUnixSeconds": time(health.lastFailureAtUnixSeconds),
    "cooldownCount": .number(Decimal(health.cooldowns.count)),
    "nextCooldownEndsAtUnixSeconds": time(health.cooldowns.map(\.untilUnixSeconds).min()),
  ]
  if detail {
    healthDTO["cooldowns"] = .array(
      health.cooldowns.map {
        .object([
          "model": .string($0.model), "untilUnixSeconds": time($0.untilUnixSeconds),
          "failure": .string($0.failure.rawValue),
        ])
      })
  }
  return .object(["quota": snapshot, "health": .object(healthDTO), "observing": .bool(observing)])
}
