import Foundation
import Logging
import NIOHTTP1

/// Owned by the connection's sole downstream reader; discarded when that connection ends.
struct WebSocketControlRate {
  private var tokens = 20.0
  private var last = ContinuousClock.now

  mutating func admit(now: ContinuousClock.Instant = .now) -> Bool {
    let elapsed = last.duration(to: now).components
    tokens = min(20, tokens + Double(elapsed.seconds) * 10 + Double(elapsed.attoseconds) / 1e17)
    last = now
    guard tokens >= 1 else { return false }
    tokens -= 1
    return true
  }
}

enum ClientProtocolDiagnostics {
  private static let logger = Logger(label: "codexone.protocol")

  static func metadata(name: String, outcome: String, headers: HTTPHeaders) -> Logger.Metadata {
    func identifier(_ value: String) -> String {
      guard (1...128).contains(value.utf8.count),
        value.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || [45, 46, 95].contains($0)
        })
      else { return "invalid" }
      return value
    }
    return [
      "protocol_name": .string(identifier(name)), "outcome": .string(outcome),
      "client_version": .string(identifier(headers.first(name: "version") ?? "unknown")),
      "client_category": .string(ClientFingerprint.isNative(headers) ? "codex" : "other"),
    ]
  }

  static func record(name: String, outcome: String, headers: HTTPHeaders) {
    logger.warning(
      "Client protocol extension",
      metadata: metadata(name: name, outcome: outcome, headers: headers))
  }
}

func handleWebSocketControl(
  _ body: WebSocketBody, upstream: WebSocketPeer?, downstream: WebSocketPeer,
  headers: HTTPHeaders, rate: inout WebSocketControlRate,
  registry: ClientProtocolExtensionRegistry? = nil
) async throws -> Bool {
  let document = try JSONValue.decode(body.data)
  guard let fields = document.object, let type = fields["type"]?.string else {
    throw GatewayProtocolError(400, "unsupported_websocket_control")
  }
  if type == "response.create" { return false }
  defer { body.release() }
  let lane = try webSocketLane(document)
  if type == "response.interrupt" {
    let id = fields["response_id"]?.string ?? ""
    if let upstream, let owner = upstream.interruptLane(responseID: id),
      fields["stream_id"] == nil || owner == lane
    {
      try await upstream.writer.send(body.data)
      upstream.markInterrupted(responseID: id, lane: owner)
      downstream.permitSettlement()
    } else {
      var failed: [String: JSONValue] = [
        "type": .string("response.interrupt.failed"), "response_id": .string(id),
      ]
      if !lane.isEmpty { failed["stream_id"] = .string(lane) }
      try await downstream.send(.object(failed))
    }
    return true
  }
  let outcome: String
  if upstream == nil {
    outcome = "rejected_unbound"
  } else if ["input", "model", "tools"].contains(where: { fields[$0] != nil }) {
    outcome = "rejected_generation"
  } else if !rate.admit() {
    outcome = "rejected_rate"
  } else {
    outcome = "forwarded"
  }
  registry?.record(name: type)
  ClientProtocolDiagnostics.record(name: type, outcome: outcome, headers: headers)
  if outcome == "forwarded" {
    try await upstream!.writer.send(body.data)
  } else {
    try await sendWebSocketError(
      GatewayProtocolError(400, "unsupported_websocket_control"),
      requestID: UUID().uuidString, lane: lane, to: downstream)
  }
  return true
}
