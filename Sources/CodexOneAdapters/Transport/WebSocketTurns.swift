import Foundation
import Synchronization

/// Per-lane protocol state, updated by the sole reader before it queues an event.
final class WebSocketTurns: Sendable {
  private enum Phase {
    case idle, awaitingCreated
    case active(String)
  }
  private struct State {
    struct Lane {
      var phase = Phase.idle
      var items = Set<String>()
      var evidence: (@Sendable (JSONValue) throws -> Void)?
    }
    var lanes: [String: Lane] = [:]
    var responses = Set<String>()
    var closed = false
  }
  private let state = Mutex(State())
  func close() { state.withLock { $0.closed = true } }
  func begin(lane: String = "") throws {
    try state.withLock { value in
      guard !value.closed, value.responses.count < 256 else {
        throw GatewayProtocolError(502, "invalid_upstream_turn")
      }
      if value.lanes[lane] == nil {
        guard lane.isEmpty || value.lanes.keys.filter({ !$0.isEmpty }).count < 32 else {
          throw GatewayProtocolError(503, "websocket_lane_capacity")
        }
        value.lanes[lane] = .init()
      }
      guard case .idle = value.lanes[lane]!.phase else {
        throw GatewayProtocolError(502, "invalid_upstream_turn")
      }
      let active = value.lanes.values.filter {
        if case .idle = $0.phase { return false }
        return true
      }.count
      guard active < 16 else { throw GatewayProtocolError(503, "websocket_turn_capacity") }
      value.lanes[lane]!.phase = .awaitingCreated
      value.lanes[lane]!.items.removeAll(keepingCapacity: true)
    }
  }
  func attachEvidence(lane: String, handler: @escaping @Sendable (JSONValue) throws -> Void) throws
  {
    try state.withLock { value in
      guard !value.closed, var current = value.lanes[lane], case .awaitingCreated = current.phase,
        current.evidence == nil
      else { throw GatewayProtocolError(502, "invalid_upstream_turn") }
      current.evidence = handler
      value.lanes[lane] = current
    }
  }
  func detachEvidence(lane: String) { state.withLock { $0.lanes[lane]?.evidence = nil } }
  @discardableResult func observe(_ data: Data) throws -> String {
    let event: JSONValue
    do { event = try JSONValue.decode(data) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_event")
    }
    let lane: String
    do { lane = try webSocketLane(event) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_lane")
    }
    try state.withLock { value in
      guard !value.closed, let type = event["type"]?.string else {
        throw GatewayProtocolError(502, "invalid_upstream_turn")
      }
      guard var current = value.lanes[lane] else {
        throw GatewayProtocolError(502, "unknown_upstream_lane")
      }
      defer { value.lanes[lane] = current }
      switch current.phase {
      case .idle: throw GatewayProtocolError(502, "event_outside_upstream_turn")
      case .awaitingCreated:
        guard type == "response.created", let id = event["response"]?["id"]?.string,
          !id.isEmpty, id.utf8.count <= 256, value.responses.count < 256,
          value.responses.insert(id).inserted
        else { throw GatewayProtocolError(502, "invalid_upstream_turn") }
        current.phase = .active(id)
      case .active(let id):
        if let response = event["response"] {
          guard response["id"]?.string == id, type != "response.created" else {
            throw GatewayProtocolError(502, "invalid_upstream_turn")
          }
        }
        if let responseID = event["response_id"] {
          guard responseID.string == id else {
            throw GatewayProtocolError(502, "invalid_upstream_turn")
          }
        }
        if let item = event["item"] {
          guard let itemID = item["id"]?.string, !itemID.isEmpty, itemID.utf8.count <= 256,
            current.items.count < 256 || current.items.contains(itemID)
          else { throw GatewayProtocolError(502, "invalid_upstream_turn") }
          current.items.insert(itemID)
        }
        if ProviderObservation.transparentEvents.contains(type), event["item_id"] == nil {
          throw GatewayProtocolError(502, "invalid_upstream_turn")
        }
        if let itemID = event["item_id"] {
          guard let itemID = itemID.string, current.items.contains(itemID) else {
            throw GatewayProtocolError(502, "invalid_upstream_turn")
          }
        }
        if ["response.completed", "response.failed", "response.incomplete"].contains(type) {
          guard event["response"]?["id"]?.string == id else {
            throw GatewayProtocolError(502, "invalid_upstream_turn")
          }
          // Preserve classified evidence before any other lane can cancel queued delivery.
          try current.evidence?(event)
          current.phase = .idle
        }
      }
    }
    return lane
  }
}

func webSocketLane(_ document: JSONValue) throws -> String {
  guard let value = document["stream_id"] else { return "" }
  guard let name = value.string, (1...256).contains(name.utf8.count),
    name.utf8.allSatisfy({
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [45, 46, 95].contains($0)
    })
  else { throw GatewayProtocolError(400, "invalid_stream_id") }
  return name
}
