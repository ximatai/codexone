import Foundation
import Synchronization

struct WebSocketUpstreamClosed: Error {}
struct UnadmittedWebSocketResponse: Error {}

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
      var receivedCreated = false
      var interrupted = false
      // Set at the existing wire dispatch boundary, not at admission/begin.
      var dispatched = false
      var evidence: (@Sendable (JSONValue) throws -> Void)?
    }
    var lanes: [String: Lane] = [:]
    /// Recently started responses; stale events for them can never begin a later turn.
    var started: [String] = []
    var startedSet = Set<String>()
    var responseLanes: [String: String] = [:]
    var endedLanes: [String: String] = [:]
    var ended: [String] = []
    /// At most one terminal awaiting downstream submission per admitted lane (33 lanes).
    var pendingDelivery: [String: String] = [:]
    mutating func end(_ id: String, lane: String) {
      guard endedLanes.updateValue(lane, forKey: id) == nil else { return }
      ended.append(id)
      if ended.count > 1024 { endedLanes.removeValue(forKey: ended.removeFirst()) }
    }
    var closed = false
    var settlementPermitted = false
    var closeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    mutating func start(_ id: String, lane: String) {
      guard startedSet.insert(id).inserted else { return }
      started.append(id)
      responseLanes[id] = lane
      if started.count > 1024 {
        let oldest = started.removeFirst()
        startedSet.remove(oldest)
        responseLanes.removeValue(forKey: oldest)
      }
    }
  }

  private let state = Mutex(State())
  var isClosed: Bool { state.withLock { $0.closed } }
  var settlementPermitted: Bool { state.withLock { $0.settlementPermitted } }
  func permitSettlement() { state.withLock { $0.settlementPermitted = true } }
  // Independent cancellation: completing one turn must not end other close waiters.
  func waitForClose() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let ready = state.withLock { value in
          guard !value.closed, !Task.isCancelled else { return true }
          value.closeWaiters[id] = continuation
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      let waiter = self.state.withLock { $0.closeWaiters.removeValue(forKey: id) }
      waiter?.resume()
    }
  }
  func close() {
    let waiters = state.withLock { value in
      value.closed = true
      let waiters = Array(value.closeWaiters.values)
      value.closeWaiters.removeAll()
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }
  func begin(lane: String = "", compaction: Bool = false) throws {
    try state.withLock { value in
      guard !value.closed else { throw WebSocketUpstreamClosed() }
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
      value.lanes[lane]!.receivedCreated = false
      value.lanes[lane]!.interrupted = false
      value.lanes[lane]!.dispatched = false
    }
  }
  func attachEvidence(lane: String, handler: @escaping @Sendable (JSONValue) throws -> Void) throws
  {
    try state.withLock { value in
      guard !value.closed else { throw WebSocketUpstreamClosed() }
      guard var current = value.lanes[lane], case .awaitingCreated = current.phase,
        current.evidence == nil
      else {
        throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnLifecycle)
      }
      current.evidence = handler
      value.lanes[lane] = current
    }
  }
  func detachEvidence(lane: String) { state.withLock { $0.lanes[lane]?.evidence = nil } }

  func markDispatched(lane: String) {
    state.withLock { $0.lanes[lane]?.dispatched = true }
  }

  /// A projection of the owned turn, never an independently advanced settlement state.
  enum Settlement {
    case finished, awaitingIdentity, interrupted
    case interrupt(String)
  }
  func settlement(lane: String) -> Settlement {
    state.withLock { value in
      guard !value.closed, let turn = value.lanes[lane], turn.dispatched else {
        return .finished
      }
      switch turn.phase {
      case .idle: return .finished
      case .awaitingCreated: return .awaitingIdentity
      case .active(let id): return turn.interrupted ? .interrupted : .interrupt(id)
      }
    }
  }

  func markInterrupted(responseID: String, lane: String) {
    state.withLock { value in
      guard case .active(let id) = value.lanes[lane]?.phase, id == responseID else { return }
      value.lanes[lane]?.interrupted = true
    }
  }
  func wasInterrupted(lane: String) -> Bool {
    state.withLock { $0.lanes[lane]?.interrupted == true }
  }

  func interruptLane(responseID: String) -> String? {
    state.withLock { value in
      value.lanes.first { _, lane in
        if case .active(let id) = lane.phase { return lane.receivedCreated && id == responseID }
        return false
      }?.key
    }
  }

  func delivered(_ event: JSONValue) {
    guard ProviderObservation.terminalEvents.contains(event["type"]?.string ?? ""),
      let id = event["response"]?["id"]?.string
    else { return }
    state.withLock { value in
      if let lane = value.pendingDelivery.first(where: { $0.value == id })?.key {
        value.pendingDelivery.removeValue(forKey: lane)
      }
    }
  }
  func waitForDelivery(_ data: Data) async throws {
    let event = try JSONValue.decode(data)
    guard let id = event["response_id"]?.string ?? event["response"]?["id"]?.string else { return }
    while state.withLock({ $0.pendingDelivery.values.contains(id) && !$0.closed }) {
      try await Task.sleep(for: .milliseconds(1))
    }
    try Task.checkCancellation()
  }

  struct Delivery {
    let lane: String
    let detached: Bool
  }
  func observe(_ data: Data) throws -> String? { try delivery(data)?.lane }

  /// Returns the lane that owns the event, or nil for provider events outside any turn.
  func delivery(_ data: Data) throws -> Delivery? {
    let event: JSONValue
    do { event = try JSONValue.decode(data) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_event")
    }
    var lane: String
    do { lane = try webSocketLane(event) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_lane")
    }
    return try state.withLock { value -> Delivery? in
      guard !value.closed else {
        throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnLifecycle)
      }
      let type = event["type"]?.string ?? ""
      let id = event["response_id"]?.string ?? event["response"]?["id"]?.string
      let activeOwner = id.flatMap { responseID in
        value.lanes.first { _, lane in
          if case .active(let currentID) = lane.phase { return currentID == responseID }
          return false
        }?.key
      }
      if let id, let owner = activeOwner ?? value.endedLanes[id] ?? value.responseLanes[id] {
        let active: Bool
        if case .active(let currentID) = value.lanes[owner]?.phase {
          active = currentID == id
        } else {
          active = false
        }
        if !active {
          // Repeated lifecycle starts never attach to a newer attempt.
          if type == "response.created" { return nil }
          return .init(lane: owner, detached: true)
        }
        if type == "response.interrupt.accepted" || type == "response.interrupt.failed" {
          return .init(lane: owner, detached: true)
        }
        if event["stream_id"] == nil { lane = owner }
      }
      if ["response.created", "response.queued", "response.in_progress"].contains(type) {
        let expected: Bool
        switch value.lanes[lane]?.phase {
        case .awaitingCreated: expected = true
        case .active(let currentID): expected = currentID == id
        default: expected = false
        }
        guard expected else {
          value.closed = true
          throw UnadmittedWebSocketResponse()
        }
      }
      guard var current = value.lanes[lane] else {
        if ProviderObservation.lifecycleEvents.contains(type) {
          value.closed = true
          throw UnadmittedWebSocketResponse()
        }
        return nil
      }
      defer { value.lanes[lane] = current }
      let responseID = event["response"]?["id"]?.string
      if type == "response.created" { current.receivedCreated = true }
      let previousID: String?
      if case .active(let id) = current.phase { previousID = id } else { previousID = nil }
      switch current.phase {
      case .idle:
        if ProviderObservation.lifecycleEvents.contains(type) {
          value.closed = true
          throw UnadmittedWebSocketResponse()
        }
        return nil
      case .awaitingCreated:
        if type == "error" {
          current.phase = .idle
        } else if ProviderObservation.lifecycleEvents.contains(type) {
          guard let id = ProviderObservation.identifier(event["response"]?["id"]) else {
            throw GatewayProtocolError(502, "invalid_upstream_turn", detail: .upstreamTurnCreated)
          }
          // A stale or foreign response can never begin, or supply evidence to, this turn.
          guard !value.startedSet.contains(id), activeOwner == nil else { return nil }
          value.start(id, lane: lane)
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
      if case .idle = current.phase, let id = previousID ?? responseID {
        if ProviderObservation.terminalEvents.contains(type) { value.pendingDelivery[lane] = id }
        value.end(id, lane: lane)
      }
      try current.evidence?(event)
      return .init(lane: lane, detached: false)
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
