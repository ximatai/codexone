import Foundation
import Synchronization

/// Per-lane turn ownership, updated by the sole reader before it queues an event.
/// Only lifecycle identity is enforced; other provider events belong to the active turn as-is.
final class WebSocketTurns: Sendable {
  private enum Phase {
    case idle, awaitingCreated
    case active(String)
  }
  private struct State {
    struct Lane {
      var phase = Phase.idle
      var evidence: (@Sendable (JSONValue) throws -> Void)?
    }
    var lanes: [String: Lane] = [:]
    /// Recently started responses; stale events for them can never begin a later turn.
    var started: [String] = []
    var startedSet = Set<String>()
    var closed = false
    mutating func start(_ id: String) {
      guard startedSet.insert(id).inserted else { return }
      started.append(id)
      if started.count > 1024 { startedSet.remove(started.removeFirst()) }
    }
  }

  private let state = Mutex(State())
  func close() { state.withLock { $0.closed = true } }
  func begin(lane: String = "", compaction: Bool = false) throws {
    try state.withLock { value in
      guard !value.closed else {
        throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnLifecycle)
      }
      if value.lanes[lane] == nil {
        guard lane.isEmpty || value.lanes.keys.filter({ !$0.isEmpty }).count < 32 else {
          throw GatewayProtocolError(503, "websocket_lane_capacity")
        }
        value.lanes[lane] = .init()
      }
      guard case .idle = value.lanes[lane]!.phase else {
        throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnLifecycle)
      }
      let active = value.lanes.values.filter {
        if case .idle = $0.phase { return false }
        return true
      }.count
      guard active < 16 else { throw GatewayProtocolError(503, "websocket_turn_capacity") }
      value.lanes[lane]!.phase = .awaitingCreated
    }
  }
  func attachEvidence(lane: String, handler: @escaping @Sendable (JSONValue) throws -> Void) throws
  {
    try state.withLock { value in
      guard !value.closed, var current = value.lanes[lane], case .awaitingCreated = current.phase,
        current.evidence == nil
      else {
        throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnLifecycle)
      }
      current.evidence = handler
      value.lanes[lane] = current
    }
  }
  func detachEvidence(lane: String) { state.withLock { $0.lanes[lane]?.evidence = nil } }

  /// Returns the lane that owns the event, or nil for provider events outside any turn.
  func observe(_ data: Data) throws -> String? {
    let event: JSONValue
    do { event = try JSONValue.decode(data) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_event")
    }
    let lane: String
    do { lane = try webSocketLane(event) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_lane")
    }
    return try state.withLock { value -> String? in
      guard !value.closed else {
        throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnLifecycle)
      }
      guard var current = value.lanes[lane] else { return nil }
      defer { value.lanes[lane] = current }
      let type = event["type"]?.string ?? ""
      let responseID = event["response"]?["id"]?.string
      switch current.phase {
      case .idle: return nil
      case .awaitingCreated:
        if type == "error" {
          current.phase = .idle
        } else if ProviderObservation.lifecycleEvents.contains(type) {
          guard let id = ProviderObservation.identifier(event["response"]?["id"]) else {
            throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnCreated)
          }
          // A stale or foreign response can never begin, or supply evidence to, this turn.
          guard !value.startedSet.contains(id) else { return nil }
          value.start(id)
          current.phase = .active(id)
          try finish(&current, type: type, event: event)
        } else if type.hasPrefix("response.") && type != "response.metadata"
          || event["response_id"] != nil
        {
          return nil  // Output of an earlier turn; the new response has not started yet.
        }
      case .active(let id):
        if let foreign = event["response_id"], foreign.string != id {
          throw GatewayProtocolError(
            502, "invalid_upstream_turn", detail: .upstreamTurnResponseID)
        }
        if type == "error" {
          current.phase = .idle
        } else if ProviderObservation.lifecycleEvents.contains(type) {
          guard responseID == id else {
            throw GatewayProtocolError(
              502, "invalid_upstream_turn", detail: .upstreamTurnResponseID)
          }
          try finish(&current, type: type, event: event)
        }
      }
      try current.evidence?(event)
      return lane
    }
  }

  private func finish(_ lane: inout State.Lane, type: String, event: JSONValue) throws {
    guard ProviderObservation.terminalEvents.contains(type) else { return }
    // Preserve classified evidence before any other lane can cancel queued delivery.
    lane.phase = .idle
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
