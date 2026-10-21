import CodexOneCore
import Foundation

extension HTTPResponseExecution {
  func execute(
    _ request: ResponseRequest, requestID: String, peer: WebSocketPeer, lane: String = "",
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard let model = configuration.models.first(where: { $0.id == request.model }) else {
      throw GatewayProtocolError(403, "model_not_allowed")
    }
    try peer.beginTurn(lane: lane)
    try await gateway.execute(
      model: request.model, references: request.references, requestID: requestID
    ) { context in
      try peer.attachEvidence(lane: lane) { event in
        if let evidence = try ProviderObservation.usage(event["response"]?["usage"], model: model) {
          try context.observeUsage(evidence)
        }
      }
      defer { peer.detachEvidence(lane: lane) }
      try await withExecutionDeadline(seconds: configuration.executionTimeoutSeconds ?? 120) {
        var create = request.document.object!
        create.removeValue(forKey: "stream")
        create["type"] = .string("response.create")
        if !lane.isEmpty { create["stream_id"] = .string(lane) }
        try await peer.send(.object(create))
        var total = 0
        while true {
          let data = try await peer.next(lane: lane)
          guard data.count <= 8_388_608 - total else {
            throw GatewayProtocolError(502, "upstream_response_too_large")
          }
          total += data.count
          guard data.count <= 262_144 else {
            throw GatewayProtocolError(502, "upstream_event_too_large")
          }
          let event: JSONValue
          do { event = try JSONValue.decode(data) } catch {
            throw GatewayProtocolError(502, "invalid_upstream_event")
          }
          guard try webSocketLane(event) == lane else {
            throw GatewayProtocolError(502, "invalid_upstream_lane")
          }
          if ["response.completed", "response.failed", "response.incomplete"].contains(
            event["type"]?.string ?? ""),
            let evidence = try ProviderObservation.usage(event["response"]?["usage"], model: model)
          {
            try context.observeUsage(evidence)
          }
          let observation = try ProviderObservation(
            event: event, model: model, functionNames: request.functionNames)
          for object in observation.bindings { try await context.bind(object) }
          if request.streaming {
            try await emit(event)
          } else if observation.terminal {
            try await emit(event["response"]!)
          }
          if observation.terminal { break }
        }
      }
      return nil
    }
  }
}

func webSocketCreate(_ data: Data) throws -> ResponseRequest {
  guard var document = try JSONValue.decode(data).object,
    document.removeValue(forKey: "type") == .string("response.create")
  else { throw GatewayProtocolError(400, "unsupported_websocket_control") }
  _ = try webSocketLane(.object(document))
  document.removeValue(forKey: "stream_id")
  document["stream"] = .bool(true)
  return try ResponseRequest(data: JSONValue.object(document).data())
}
