import CodexOneCore
import Foundation

struct HTTPReply: Sendable {
  let status: Int
  let body: Data
}

struct HealthRouter: Sendable {
  let report: ReadinessReport

  func reply(method: String, uri: String) -> HTTPReply {
    let path = String(uri.split(separator: "?", maxSplits: 1).first ?? "")
    if method == "GET", path == "/health/live" {
      return HTTPReply(status: 200, body: Data(#"{"status":"alive"}"#.utf8))
    }
    if method == "GET", path == "/health/ready" {
      return HTTPReply(
        status: report.isReady ? 200 : 503,
        body: (try? JSONEncoder().encode(SystemStatusResponse(report: report))) ?? Data())
    }
    if method == "POST", ["/v1/responses", "/v1/images/generations"].contains(path) {
      return HTTPReply(
        status: 503,
        body: Data(
          #"{"error":{"message":"Gateway is not configured.","type":"server_error","code":"gateway_not_configured"}}"#
            .utf8))
    }
    return HTTPReply(
      status: 404,
      body: Data(
        #"{"error":{"message":"Route not found.","type":"invalid_request_error","code":"not_found"}}"#
          .utf8))
  }
}
