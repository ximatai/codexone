import CodexOneCore
import Foundation
import Vapor

public struct UsageAdminAPI: Sendable {
  private let querying: any UsageQuerying
  public init(querying: any UsageQuerying) { self.querying = querying }
  func register(_ routes: any RoutesBuilder) {
    routes.get("options") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      let options = try await querying.usageOptions()
      return try Self.response(
        .object([
          "keys": .array(options.keys.map { .string($0) }),
          "models": .array(options.models.map { .string($0) }),
          "failures": .array(ExecutionFailure.allCases.map { .string($0.rawValue) }),
        ]))
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
  static func parse(_ url: String) throws -> UsageQuery {
    let allowed: Set<String> = [
      "start", "end", "key", "model", "mode", "failure", "failedOnly", "state", "after", "limit",
    ]
    let entries = URLComponents(string: url)?.queryItems ?? []
    guard entries.count <= 10, Set(entries.map(\.name)).count == entries.count,
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
        "admitted": count(totals.admitted), "recordedRejections": count(totals.rejected),
        "inFlight": count(totals.inFlight), "unknown": count(totals.unknown),
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
