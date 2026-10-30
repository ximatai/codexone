import CodexOneCore
import Foundation

extension HTTPResponseExecution {
  func execute(
    _ request: ResponseRequest, requestID: String, peer: WebSocketPeer, lane: String = "",
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard let gateway else { throw ExecutionError.unauthorized }
    let model = try executionModel(request)
    _ = try request.preparedDocument(contract: configuration.requestContract, nativeWebSocket: true)
    if case .pool = gateway, connection == nil {
      throw GatewayProtocolError(503, "pool_websocket_unavailable")
    }
    try peer.beginTurn(lane: lane, compaction: request.streamCompaction)
    try await gateway.execute(
      model: request.admissionModel, references: request.references,
      affinityHints: request.affinityHints, requestID: requestID,
      mode: request.mode, connection: connection, requirements: request.requirements
    ) { context, _ in
      try await exchange(
        request, context: context, model: model, peer: peer, lane: lane, emit: emit)
      return nil
    }
  }

  /// Performs one prepared wire turn under an already durable, owned execution context.
  func exchange(
    _ request: ResponseRequest, context: ExecutionContext, model: SingleIdentityConfiguration.Model,
    peer: WebSocketPeer, lane: String = "",
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    try peer.attachEvidence(lane: lane) { event in
      try request.observeUsage(
        event["response"], context: context, model: model,
        configuration: configuration.imageGeneration)
    }
    defer { peer.detachEvidence(lane: lane) }
    try await withProgressDeadline(budget: configuration.budget) { progress in
      var create = try request.preparedDocument(
        contract: configuration.requestContract, nativeWebSocket: true
      ).object!
      // Codex subscription WS keeps stream=true in its native request contract.
      // The public Responses WS dialect and image contract retain their separate wire rules.
      if configuration.requestContract == .responses || request.requirements.imageModel != nil {
        create.removeValue(forKey: "stream")
      }
      create["type"] = .string("response.create")
      if request.usesResponsesLite {
        var metadata = create["client_metadata"]?.object ?? [:]
        metadata[ResponseRequest.liteMetadataKey] = .string("true")
        create["client_metadata"] = .object(metadata)
      }
      if request.mode == .warmup { create["generate"] = .bool(false) }
      if !lane.isEmpty { create["stream_id"] = .string(lane) }
      try await peer.send(.object(create))
      var total = 0
      while true {
        let data = try await peer.next(lane: lane)
        let limit =
          request.requirements.imageModel == nil
          ? ProviderObservation.maximumTextResponseBytes : ImageLimits.responseBytes
        guard data.count <= limit - total else {
          throw GatewayProtocolError(502, "upstream_response_too_large")
        }
        total += data.count
        guard
          data.count
            <= (request.requirements.imageModel == nil
              ? ProviderObservation.maximumTextEventBytes : ImageLimits.eventBytes)
        else {
          throw GatewayProtocolError(502, "upstream_event_too_large")
        }
        let event: JSONValue
        do { event = try JSONValue.decode(data) } catch {
          throw GatewayProtocolError(502, "invalid_upstream_event")
        }
        guard try webSocketLane(event) == lane else {
          throw GatewayProtocolError(502, "invalid_upstream_lane")
        }
        let type = try ProviderObservation.eventType(event)
        if type == "error" { throw ProviderObservation.providerFailure(event) }
        if ProviderObservation.terminalEvents.contains(type) {
          try request.observeUsage(
            event["response"], context: context, model: model,
            configuration: configuration.imageGeneration)
        }
        let observation = try ProviderObservation(
          event: event, model: model, allowImages: request.requirements.imageModel != nil)
        progress.note(event: event)
        for object in observation.bindings { try await context.bind(object) }
        try observeTerminalOutcome(event, context: context)
        if request.streaming {
          try await emit(
            request.requirements.imageModel == nil ? ProviderObservation.textOutput(event) : event)
        } else if observation.terminal {
          let response = event["response"]!
          try await emit(
            request.requirements.imageModel == nil
              ? ProviderObservation.textOutput(response) : response)
        }
        if observation.terminal { try observeSubmittedTerminal(event, context: context) }
        if observation.terminal { break }
      }
    }
  }
}

func webSocketCreate(
  _ data: Data, imageConfiguration: ImageConfiguration? = nil,
  previousTools: ClientToolSnapshot? = nil
) throws
  -> ResponseRequest
{
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
    data: JSONValue.object(document).data(escapingSlashes: false),
    mode: generate?.bool == false ? .warmup : .generation,
    imageConfiguration: imageConfiguration, previousTools: previousTools)
}
