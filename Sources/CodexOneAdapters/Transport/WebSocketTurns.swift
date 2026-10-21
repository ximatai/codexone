import Foundation
import Synchronization

/// Serial-lane protocol state, updated by the sole reader before it queues an event.
final class WebSocketTurns: Sendable {
  private enum Phase {
    case idle, awaitingCreated
    case active(String)
  }
  private struct State {
    var phase = Phase.idle
    var responses = Set<String>()
    var items = Set<String>()
    var closed = false
  }
  private let state = Mutex(State())
  func close() { state.withLock { $0.closed = true } }
  func begin() throws {
    try state.withLock { value in
      guard !value.closed, case .idle = value.phase, value.responses.count < 256 else {
        throw GatewayProtocolError(502, "invalid_upstream_turn")
      }
      value.phase = .awaitingCreated
      value.items.removeAll(keepingCapacity: true)
    }
  }
  func observe(_ data: Data) throws {
    let event: JSONValue
    do { event = try JSONValue.decode(data) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_event")
    }
    try state.withLock { value in
      guard !value.closed, let type = event["type"]?.string else {
        throw GatewayProtocolError(502, "invalid_upstream_turn")
      }
      switch value.phase {
      case .idle: throw GatewayProtocolError(502, "event_outside_upstream_turn")
      case .awaitingCreated:
        guard type == "response.created", let id = event["response"]?["id"]?.string,
          !id.isEmpty, id.utf8.count <= 256, value.responses.insert(id).inserted
        else { throw GatewayProtocolError(502, "invalid_upstream_turn") }
        value.phase = .active(id)
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
            value.items.count < 256 || value.items.contains(itemID)
          else { throw GatewayProtocolError(502, "invalid_upstream_turn") }
          value.items.insert(itemID)
        }
        if ProviderObservation.transparentEvents.contains(type), event["item_id"] == nil {
          throw GatewayProtocolError(502, "invalid_upstream_turn")
        }
        if let itemID = event["item_id"] {
          guard let itemID = itemID.string, value.items.contains(itemID) else {
            throw GatewayProtocolError(502, "invalid_upstream_turn")
          }
        }
        if ["response.completed", "response.failed", "response.incomplete"].contains(type) {
          guard event["response"]?["id"]?.string == id else {
            throw GatewayProtocolError(502, "invalid_upstream_turn")
          }
          value.phase = .idle
        }
      }
    }
  }
}
