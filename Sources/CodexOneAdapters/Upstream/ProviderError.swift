import AsyncHTTPClient
import Foundation
import NIOCore
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

  static func isExplicitRejection(status: Int?, error: JSONValue?) -> Bool {
    if let status { return (400...499).contains(status) }
    let codes = [error?["code"]?.string, error?["type"]?.string].compactMap { $0 }
    return codes.contains { code in
      rateLimitCodes.contains(code) || authenticationCodes.contains(code)
        || [
          "invalid_request_error", "invalid_request", "permission_denied", "access_denied",
          "model_not_found", "content_policy_violation", "unsupported_parameter",
        ].contains(code)
    }
  }

  static func sanitized(_ value: JSONValue?) -> JSONValue? {
    guard let object = value?.object else {
      guard let message = value?.string else { return nil }
      return .object(["message": .string(redact(message))])
    }
    var result: JSONObject = [:]
    for (key, value) in object {
      if stringMembers.contains(key), let text = value.string {
        result[key] = .string(redact(String(text.prefix(4096))))
      } else if numberMembers.contains(key), case .number = value {
        result[key] = value
      }
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
    let rejected = isExplicitRejection(status: status, error: error)
    let code = error?["code"]?.string ?? error?["type"]?.string ?? ""
    let forwarded = sanitized(error)
    let cooldown =
      retryAfter ?? error?["resets_in_seconds"]?.integer.map { min(3600, max(1, $0)) }
    if let status, (500...599).contains(status) {
      return .init(
        status == 503 ? 503 : 502, "upstream_unavailable", cooldownSeconds: cooldown,
        upstreamStatus: status, providerError: forwarded)
    }
    if status == 401 || authenticationCodes.contains(code) {
      // The provider credential belongs to the gateway, not the caller.
      return .init(
        502, "upstream_authentication_rejected", upstreamStatus: status,
        explicitProviderRejection: rejected)
    }
    if status == 429 || rateLimitCodes.contains(code) {
      return .init(
        429, "upstream_rate_limited", cooldownSeconds: cooldown, upstreamStatus: status,
        providerError: forwarded, explicitProviderRejection: rejected)
    }
    if code == "server_is_overloaded" {
      return .init(
        status == 503 ? 503 : 502, "upstream_unavailable", cooldownSeconds: cooldown,
        upstreamStatus: status, providerError: forwarded, explicitProviderRejection: rejected)
    }
    let downstream = status.map { (400...499).contains($0) ? $0 : 502 } ?? (rejected ? 400 : 502)
    return .init(
      downstream, compact ? "upstream_compact_rejected" : "upstream_rejected",
      upstreamStatus: status, providerError: forwarded, explicitProviderRejection: rejected)
  }

  /// Reads a bounded non-success body; unparsable bodies keep only the status classification.
  static func failure(
    response: HTTPClientResponse, compact: Bool = false, diagnostics: NativeImageDiagnostics? = nil
  ) async -> GatewayProtocolError {
    let status = Int(response.status.code)
    let body: ByteBuffer?
    do {
      // Preserve AHC's Content-Length preflight before wrapping its body sequence.
      if let diagnostics,
        !(response.status != .notModified
          && (response.headers.first(name: "content-length").flatMap { Int($0) } ?? 0) > 65_536)
      {
        body = try await response.body.map { chunk in
          diagnostics.receivedBody(bytes: chunk.readableBytes)
          return chunk
        }.collect(upTo: 65_536)
      } else {
        body = try await response.body.collect(upTo: 65_536)
      }
    } catch {
      diagnostics?.bodyFailed(error)
      body = nil
    }
    let document = body.flatMap { try? JSONValue.decode(Data($0.readableBytesView)) }
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
