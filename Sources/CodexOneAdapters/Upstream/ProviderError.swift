import AsyncHTTPClient
import Foundation
import NIOHTTP1

/// Provider errors keep their client-actionable members; account identifiers never leave the gateway.
enum ProviderError {
  private static let stringMembers = ["type", "code", "param", "message", "plan_type"]
  private static let numberMembers = ["resets_at", "resets_in_seconds"]
  private static let rateLimitCodes: Set<String> = [
    "rate_limit_exceeded", "rate_limit_error", "usage_limit_reached", "insufficient_quota",
    "usage_not_included",
  ]
  private static let authenticationCodes: Set<String> = [
    "invalid_api_key", "invalid_token", "authentication_error", "unauthorized", "token_expired",
  ]

  static func sanitized(_ value: JSONValue?) -> JSONValue? {
    guard let object = value?.object else {
      guard let message = value?.string else { return nil }
      return .object(["message": .string(redact(message))])
    }
    var result: [String: JSONValue] = [:]
    for key in stringMembers {
      if let text = object[key]?.string {
        result[key] = .string(redact(String(text.prefix(4096))))
      }
    }
    for key in numberMembers {
      if case .number = object[key] { result[key] = object[key] }
    }
    return result.isEmpty ? nil : .object(result)
  }

  /// Replaces provider-side account, organization and person identifiers in free text.
  static func redact(_ text: String) -> String {
    var output = text
    for pattern in [
      #"\b(org|user|proj|acct|account)[-_][A-Za-z0-9_-]{4,}"#,
      #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
    ] {
      output = output.replacingOccurrences(
        of: pattern, with: "[redacted]", options: .regularExpression)
    }
    return output
  }

  /// Maps a provider failure to the gateway's health class while forwarding the actionable error.
  static func failure(
    status: Int?, error: JSONValue?, retryAfter: Int64? = nil, compact: Bool = false
  ) -> GatewayProtocolError {
    let code = error?["code"]?.string ?? error?["type"]?.string ?? ""
    let forwarded = sanitized(error)
    let cooldown =
      retryAfter ?? error?["resets_in_seconds"]?.integer.map { min(3600, max(1, $0)) }
    if status == 401 || authenticationCodes.contains(code) {
      // The provider credential belongs to the gateway, not the caller.
      return .init(502, "upstream_authentication_rejected", upstreamStatus: status)
    }
    if status == 429 || rateLimitCodes.contains(code) {
      return .init(
        429, "upstream_rate_limited", cooldownSeconds: cooldown, upstreamStatus: status,
        providerError: forwarded)
    }
    if let status, (500...599).contains(status) || code == "server_is_overloaded" {
      return .init(
        status == 503 ? 503 : 502, "upstream_unavailable", cooldownSeconds: cooldown,
        upstreamStatus: status, providerError: forwarded)
    }
    let downstream = status.map { (400...499).contains($0) ? $0 : 502 } ?? 502
    return .init(
      downstream, compact ? "upstream_compact_rejected" : "upstream_rejected",
      upstreamStatus: status, providerError: forwarded)
  }

  /// Reads a bounded non-success body; unparsable bodies keep only the status classification.
  static func failure(
    response: HTTPClientResponse, compact: Bool = false
  ) async -> GatewayProtocolError {
    let status = Int(response.status.code)
    let document = (try? await response.body.collect(upTo: 65_536)).flatMap {
      try? JSONValue.decode(Data($0.readableBytesView))
    }
    let error = document?["error"].flatMap { $0 == .null ? nil : $0 } ?? document?["detail"]
    return failure(
      status: status, error: error, retryAfter: retryAfter(response.headers), compact: compact)
  }

  static func retryAfter(_ headers: HTTPHeaders) -> Int64? {
    let retry = headers["retry-after"]
    guard retry.count == 1, retry[0].utf8.count <= 10,
      retry[0].utf8.allSatisfy({ (48...57).contains($0) }), let raw = Int64(retry[0])
    else { return nil }
    return min(3600, max(1, raw))
  }
}
