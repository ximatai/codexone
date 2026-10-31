import CodexOneCore
import Foundation
import Vapor

public struct UsageAdminAPI: Sendable {
  private let querying: any UsageQuerying
  private let defaultReasoningEfforts: [String: String]
  public init(querying: any UsageQuerying, models: [SingleIdentityConfiguration.Model] = []) {
    self.querying = querying
    defaultReasoningEfforts = Dictionary(
      uniqueKeysWithValues: models.compactMap { model in
        guard
          let value = model.catalog?.defaultReasoningEffort
            ?? model.upstream?["default_reasoning_level"]?.string
        else { return nil }
        return (model.id, RequestMetadataValue.sanitize(value))
      })
  }
  func register(_ routes: any RoutesBuilder) {
    routes.get("headroom") { request async throws -> Response in
      guard request.url.query == nil, let reader = querying as? any GovernanceReading else {
        throw ExecutionError.invalidCommand
      }
      do {
        let now = Int64(Date().timeIntervalSince1970)
        let report = try await reader.governanceHeadroom(now: now)
        return try Self.response(
          .object([
            "generatedAtUnixSeconds": .number(Decimal(now)),
            "unknownReconciliation": .object([
              "count": .number(Decimal(report.unknownCount)),
              "beforeUnixSeconds": .number(Decimal(report.beforeUnixSeconds)),
              "periodSeconds": .number(Decimal(ExecutionLimits.unknownReconciliationSeconds)),
            ]),
            "capacities": .array(
              report.capacities.map { value in
                .object([
                  "name": .string(value.name),
                  "current": value.current.map { .string(String($0)) } ?? .null,
                  "limit": .string(String(value.limit)), "blocking": .bool(value.blocking),
                ])
              }),
            "accounts": .array(
              report.accounts.map {
                .object([
                  "id": .string($0.id), "current": .number(Decimal($0.current)),
                  "peak24Hours": .number(Decimal($0.peak24Hours)),
                  "limit": .number(Decimal(ExecutionLimits.accountConcurrency)),
                  "blocking": .bool(true),
                ])
              }),
            "storage": try JSONValue.decode(JSONEncoder().encode(reader.governanceStorage)),
            "storageLimits": .object([
              "stopAvailableBytes": .number(Decimal(reader.governanceStoragePolicy.stopBytes)),
              "stopWALBytes": .number(Decimal(reader.governanceStoragePolicy.walStopBytes)),
            ]),
          ]))
      } catch ExecutionError.capacity { throw GatewayProtocolError(429, "usage_query_capacity") }
    }
    routes.get("daily") { request async throws -> Response in
      let values = try Self.parameters(
        request.url.string, allowed: ["days", "key", "model", "end"])
      let days: Int
      if let raw = values["days"] {
        guard let value = Int(raw) else { throw ExecutionError.invalidCommand }
        days = value
      } else {
        days = 7
      }
      let end = values["end"].flatMap(Int64.init)
      guard values["end"] == nil || end != nil else { throw ExecutionError.invalidCommand }
      do {
        let buckets = try await querying.dailyUsage(
          days: days, keyID: values["key"], model: values["model"], endUnixSeconds: end)
        return try Self.response(
          .object([
            "timezone": .string("UTC"), "days": .number(Decimal(days)),
            "buckets": .array(
              buckets.map { value in
                .object([
                  "atUnixSeconds": .number(Decimal(value.atUnixSeconds)),
                  "requests": .number(Decimal(value.requests)),
                  "usageUnknown": .number(Decimal(value.usageUnknown)),
                  "unknownReasons": .object(
                    value.unknownReasons.mapValues { .number(Decimal($0)) }),
                  "succeeded": .number(Decimal(value.succeeded)),
                  "failed": .number(Decimal(value.failed)),
                  "cancelled": .number(Decimal(value.cancelled)),
                  "failures": .object(value.failures.mapValues { .number(Decimal($0)) }),
                  "metrics": Self.metricsDocument(value.metrics),
                ])
              }),
          ]))
      } catch ExecutionError.capacity { throw GatewayProtocolError(429, "usage_query_capacity") }
    }
    routes.get("in-flight") { request async throws -> Response in
      let values = try Self.parameters(request.url.string, allowed: ["limit"])
      let limit: Int
      if let raw = values["limit"] {
        guard let value = Int(raw) else { throw ExecutionError.invalidCommand }
        limit = value
      } else {
        limit = 200
      }
      do {
        let rows = try await querying.inFlightUsage(limit: limit)
        return try Self.response(
          .object([
            "rows": .array(
              try rows.map { row in
                var object = try JSONValue.decode(JSONEncoder().encode(row)).object!
                object["displayName"] = row.displayName.map { .string($0) } ?? .null
                return .object(object)
              })
          ]))
      } catch ExecutionError.capacity { throw GatewayProtocolError(429, "usage_query_capacity") }
    }
    routes.get("options") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      let options = try await querying.usageOptions()
      return try Self.response(
        .object([
          "keys": .array(options.keys.map { .string($0) }),
          "keyOptions": .array(
            options.keyOptions.map {
              .object([
                "displayName": $0.displayName.map { .string($0) } ?? .null,
                "id": .string($0.id), "principal": $0.principal.map { .string($0) } ?? .null,
              ])
            }),
          "models": .array(options.models.map { .string($0) }),
          "defaultReasoningEfforts": .object(defaultReasoningEfforts.mapValues { .string($0) }),
          "failures": .array(ExecutionFailure.allCases.map { .string($0.rawValue) }),
        ]))
    }
    routes.get("keys") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      do {
        let report = try await querying.keyUsage()
        return try Self.response(
          .object([
            "startUnixSeconds": .number(Decimal(report.startUnixSeconds)),
            "endUnixSeconds": .number(Decimal(report.startUnixSeconds + 86400)),
            "timezone": .string("UTC"),
            "keys": .array(
              report.keys.map { value in
                .object([
                  "keyID": .string(value.key.id),
                  "displayName": value.key.displayName.map { .string($0) } ?? .null,
                  "principal": value.key.principal.map { .string($0) } ?? .null,
                  "admitted": .number(Decimal(value.admitted)),
                  "failed": .number(Decimal(value.failed)),
                  "pending": .number(Decimal(value.pending)),
                  "estimatedMicros": value.estimatedMicros.map { .string(String($0)) } ?? .null,
                  "lastUsedAtUnixSeconds": value.lastUsedAtUnixSeconds.map { .number(Decimal($0)) }
                    ?? .null,
                ])
              }),
          ]))
      } catch ExecutionError.capacity { throw GatewayProtocolError(429, "usage_query_capacity") }
    }
    routes.get { request async throws -> Response in
      let query = try Self.parse(request.url.string)
      do {
        return try Self.response(Self.document(try await querying.queryUsage(query), query: query))
      } catch ExecutionError.capacity {
        throw GatewayProtocolError(429, "usage_query_capacity")
      }
    }
  }
  private static func parameters(_ url: String, allowed: Set<String>) throws -> [String: String] {
    let entries = URLComponents(string: url)?.queryItems ?? []
    guard entries.count <= allowed.count, Set(entries.map(\.name)).count == entries.count,
      entries.allSatisfy({ allowed.contains($0.name) && $0.value != nil })
    else { throw ExecutionError.invalidCommand }
    return Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.value!) })
  }
  private static func metricsDocument(_ value: UsageMetrics) -> JSONValue {
    func metric(_ value: Int64?) -> JSONValue { value.map { .string(String($0)) } ?? .null }
    return .object([
      "inputTokens": metric(value.inputTokens), "outputTokens": metric(value.outputTokens),
      "cachedTokens": metric(value.cachedTokens), "images": metric(value.images),
      "estimatedMicros": metric(value.estimatedMicros),
      "imageInputTokens": metric(value.imageInputTokens),
      "imageOutputTokens": metric(value.imageOutputTokens),
      "imageInputTextTokens": metric(value.imageInputTextTokens),
      "imageInputImageTokens": metric(value.imageInputImageTokens),
    ])
  }
  static func parse(_ url: String) throws -> UsageQuery {
    let allowed: Set<String> = [
      "start", "end", "key", "model", "mode", "failure", "failedOnly", "state", "after", "limit",
      "reasoningEffort",
    ]
    let entries = URLComponents(string: url)?.queryItems ?? []
    guard entries.count <= allowed.count, Set(entries.map(\.name)).count == entries.count,
      entries.allSatisfy({ allowed.contains($0.name) && $0.value != nil })
    else { throw ExecutionError.invalidCommand }
    let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.value!) })
    guard let start = values["start"].flatMap(Int64.init),
      let end = values["end"].flatMap(Int64.init)
    else { throw ExecutionError.invalidCommand }
    let mode = values["mode"].flatMap(ExecutionMode.init(rawValue:))
    let failure = values["failure"].flatMap(ExecutionFailure.init(rawValue:))
    let state = values["state"].flatMap(ExecutionSnapshot.State.init(rawValue:))
    guard values["mode"] == nil || mode != nil, values["failure"] == nil || failure != nil,
      values["state"] == nil || state != nil,
      values["failedOnly"] == nil || ["true", "false"].contains(values["failedOnly"]!)
    else { throw ExecutionError.invalidCommand }
    let limit: Int
    if let raw = values["limit"] {
      guard let parsed = Int(raw) else { throw ExecutionError.invalidCommand }
      limit = parsed
    } else {
      limit = 50
    }
    let cursor = try values["after"].map(Self.decodeCursor)
    return try .init(
      startUnixSeconds: start, endUnixSeconds: end, keyID: values["key"], model: values["model"],
      mode: mode, failure: failure, failedOnly: values["failedOnly"] == "true", state: state,
      reasoningEffort: values["reasoningEffort"],
      cursor: cursor, limit: limit)
  }
  private static func decodeCursor(_ raw: String) throws -> UsageCursor {
    guard !raw.isEmpty, raw.utf8.count <= 512,
      raw.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 95
      })
    else { throw ExecutionError.invalidCommand }
    var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else { throw ExecutionError.invalidCommand }
    let value = try JSONValue.decode(data)
    guard let object = value.object, Set(object.keys) == ["at", "id"],
      let at = value["at"]?.integer, let id = value["id"]?.string
    else { throw ExecutionError.invalidCommand }
    let cursor = try UsageCursor(atUnixSeconds: at, id: id)
    guard try cursorValue(cursor).string == raw else { throw ExecutionError.invalidCommand }
    return cursor
  }
  private static func cursorValue(_ cursor: UsageCursor?) throws -> JSONValue {
    guard let cursor else { return .null }
    let value = JSONValue.object([
      "at": .number(Decimal(cursor.atUnixSeconds)), "id": .string(cursor.id),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return .string(
      data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
        of: "/", with: "_"
      ).replacingOccurrences(of: "=", with: ""))
  }
  static func document(_ report: UsageReport, query: UsageQuery) throws -> JSONValue {
    func count(_ value: Int64) -> JSONValue { .number(Decimal(value)) }
    func text(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    func metric(_ value: Int64?) -> JSONValue { value.map { .string(String($0)) } ?? .null }
    func metrics(_ value: UsageMetrics) -> JSONValue {
      .object([
        "inputTokens": metric(value.inputTokens), "outputTokens": metric(value.outputTokens),
        "cachedTokens": metric(value.cachedTokens), "images": metric(value.images),
        "estimatedMicros": metric(value.estimatedMicros),
        "imageInputTokens": metric(value.imageInputTokens),
        "imageOutputTokens": metric(value.imageOutputTokens),
        "imageInputTextTokens": metric(value.imageInputTextTokens),
        "imageInputImageTokens": metric(value.imageInputImageTokens),
      ])
    }
    let totals = report.totals
    return try .object([
      "startUnixSeconds": count(query.startUnixSeconds),
      "endUnixSeconds": count(query.endUnixSeconds), "timezone": .string("UTC"),
      "totals": .object([
        "averageFirstEventMilliseconds": totals.averageFirstEventMilliseconds.map {
          .number(Decimal($0))
        } ?? .null,
        "p95FirstEventMilliseconds": totals.p95FirstEventMilliseconds.map(count) ?? .null,
        "averageTotalMilliseconds": totals.averageTotalMilliseconds.map { .number(Decimal($0)) }
          ?? .null,
        "admitted": count(totals.admitted), "recordedRejections": count(totals.rejected),
        "inFlight": count(totals.inFlight), "unknown": count(totals.unknown),
        "usageUnknown": count(totals.usageUnknown),
        "unknownReasons": .object(totals.unknownReasons.mapValues(count)),
        "complete": count(totals.complete), "partial": count(totals.partial),
        "unavailable": count(totals.unavailable),
        "failed": count(totals.failed), "cancelled": count(totals.cancelled),
        "historicalWithoutTime": count(totals.historicalWithoutTime),
        "unresolvedExposureMicros": metric(totals.unresolvedExposureMicros),
        "metrics": metrics(totals.metrics),
      ]),
      "lifetimeGovernance": .object([
        "keyID": text(query.keyID), "inFlight": count(totals.lifetimeInFlight),
        "unknown": count(totals.lifetimeUnknown),
        "exposureMicros": metric(totals.lifetimeExposureMicros),
        "scope": .string("key_only_all_time"),
      ]),
      "detailRetentionDays": .number(90),
      "diagnosticsPolicy": .object([
        "days": .number(30), "maximum": .number(10000), "mayOmitUnderLoad": .bool(true),
      ]),
      "buckets": .array(
        report.buckets.map {
          .object([
            "atUnixSeconds": count($0.atUnixSeconds), "admitted": count($0.admitted),
            "recordedRejections": count($0.rejected), "unresolved": count($0.unresolved),
          ])
        }),
      "rows": .array(
        report.rows.map { value in
          .object([
            "kind": .string(value.kind.rawValue), "id": .string(value.id),
            "atUnixSeconds": count(value.atUnixSeconds),
            "reasoningEffort": text(value.reasoningEffort),
            "serviceTier": text(value.serviceTier),
            "actualServiceTier": text(value.actualServiceTier),
            "requestMetadataRecorded": .bool(value.requestMetadataRecorded),
            "principal": text(value.principal),
            "displayName": text(value.displayName),
            "firstEventMilliseconds": value.firstEventMilliseconds.map(count) ?? .null,
            "totalMilliseconds": value.totalMilliseconds.map(count) ?? .null,
            "keyID": .string(value.keyID), "model": text(value.model),
            "mode": .string(value.mode.rawValue),
            "accountID": text(value.accountID), "requestID": text(value.requestID),
            "state": text(value.state?.rawValue),
            "outcome": text(value.outcome?.rawValue), "failure": text(value.failure?.rawValue),
            "completeness": text(value.completeness?.rawValue), "metrics": metrics(value.metrics),
          ])
        }),
      "nextCursor": cursorValue(report.nextCursor),
    ])
  }
  private static func response(_ document: JSONValue) throws -> Response {
    .init(
      status: .ok,
      headers: [
        "content-type": "application/json", "cache-control": "no-store", "connection": "close",
      ], body: .init(data: try document.data()))
  }
}
