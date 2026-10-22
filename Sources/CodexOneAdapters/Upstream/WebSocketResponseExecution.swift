import CodexOneCore
import Foundation

extension HTTPResponseExecution {
  func execute(
    _ request: ResponseRequest, requestID: String, peer: WebSocketPeer, lane: String = "",
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard let gateway else { throw ExecutionError.unauthorized }
    guard let model = effectiveModels.first(where: { $0.id == request.model }) else {
      throw GatewayProtocolError(403, "model_not_allowed")
    }
    try peer.beginTurn(lane: lane, compaction: request.streamCompaction)
    try await gateway.execute(
      model: request.model, references: request.references, requestID: requestID, mode: request.mode
    ) { context, authorization in
      guard authorization == nil else {
        throw GatewayProtocolError(503, "pool_websocket_unavailable")
      }
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
        if request.mode == .warmup { create["generate"] = .bool(false) }
        if !lane.isEmpty { create["stream_id"] = .string(lane) }
        try await peer.send(.object(create))
        var total = 0
        var compaction = StreamCompaction()
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
          if request.mode == .warmup {
            guard
              [
                "response.created", "response.in_progress", "response.completed", "response.failed",
                "response.incomplete",
              ].contains(event["type"]?.string ?? ""),
              event["response"]?["output"] == nil || event["response"]?["output"]?.array == []
            else { throw GatewayProtocolError(502, "invalid_upstream_warmup") }
          }
          let observation = try ProviderObservation(
            event: event, model: model, functionNames: request.functionNames,
            customToolNames: request.customToolNames,
            expectedPreviousResponseID: request.document["previous_response_id"]?.string,
            allowCompaction: request.streamCompaction)
          if request.streamCompaction { try compaction.observe(event) }
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
  let generate = document.removeValue(forKey: "generate")
  guard generate == nil || generate?.bool != nil else {
    throw GatewayProtocolError(400, "unsupported_websocket_control")
  }
  document["stream"] = .bool(true)
  return try ResponseRequest(
    data: JSONValue.object(document).data(), mode: generate?.bool == false ? .warmup : .generation)
}
