import CodexOneCore
import Foundation

extension HTTPResponseExecution {
  func execute(
    _ request: ResponseRequest, requestID: String, peer: WebSocketPeer, lane: String = "",
    downstream: WebSocketPeer? = nil, useHandshakeState: Bool = false,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard let gateway else { throw ExecutionError.unauthorized }
    let model = try executionModel(request)
    _ = try request.preparedDocument(contract: configuration.requestContract, nativeWebSocket: true)
    if case .pool = gateway, connection == nil {
      throw GatewayProtocolError(503, "pool_websocket_unavailable")
    }
    let turnState = try requestTurnState(
      headers: useHandshakeState ? clientHeaders : .init(), document: request.document)
    let frame = try webSocketFrame(request, lane: lane, turnState: turnState)
    try UpstreamWebSocketBodyLimit.requireNativeFrame(frame)
    try peer.beginTurn(lane: lane, compaction: request.streamCompaction)
    try await withExecutionDeadline(seconds: configuration.budget.total) {
      try await executeRouted(
        model: request.admissionModel, references: request.references,
        affinityHints: request.affinityHints, requestID: requestID,
        mode: request.mode, turnState: turnState, connection: connection,
        requirements: request.requirements,
        reasoningEffort: request.reasoningEffort, serviceTier: request.serviceTier
      ) { context, _ in
        try await exchange(
          request, context: context, model: model, peer: peer, lane: lane,
          downstream: downstream, frame: frame, emit: emit)
        return nil
      }
    }
  }

  func webSocketFrame(_ request: ResponseRequest, lane: String = "", turnState: String? = nil)
    throws -> Data
  {
    var create = try request.preparedDocument(
      contract: configuration.requestContract, nativeWebSocket: true
    ).object!
    // Codex subscription WS keeps stream=true in its native request contract.
    // Public Responses WS streams implicitly.
    if configuration.requestContract == .responses {
      create.removeValue(forKey: "stream")
    }
    create["type"] = .string("response.create")
    if request.usesResponsesLite {
      var metadata = create["client_metadata"]?.object ?? [:]
      metadata[ResponseRequest.liteMetadataKey] = .string("true")
      create["client_metadata"] = .object(metadata)
    }
    if configuration.requestContract == .codexSubscription, let turnState {
      var metadata = create["client_metadata"]?.object ?? [:]
      metadata["x-codex-turn-state"] = .string(turnState)
      create["client_metadata"] = .object(metadata)
    }
    if request.mode == .warmup { create["generate"] = .bool(false) }
    if !lane.isEmpty { create["stream_id"] = .string(lane) }
    return try JSONValue.object(create).data(escapingSlashes: false)
  }

  /// Performs one prepared wire turn under an already durable, owned execution context.
  func exchange(
    _ request: ResponseRequest, context: ExecutionContext, model: SingleIdentityConfiguration.Model,
    peer: WebSocketPeer, lane: String = "",
    downstream: WebSocketPeer? = nil, frame: Data, allowSizeFallback: Bool = false,
    sizeRefusalPath: String = "reject_native_1009",
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    defer { observeDisconnectedOutcome(downstream, context: context) }
    try peer.attachEvidence(
      lane: lane,
      unattributedProcessing: {
        context.observeUpstreamEvent()
        _ = context.observeProviderEvent()
      },
      handler: { event in
        context.observeUpstreamEvent()
        try observeProviderEvent(event, context: context)
        guard !context.providerRejectedBeforeOutput,
          ProviderObservation.terminalEvents.contains(event["type"]?.string ?? "")
        else { return }
        try request.observeUsage(
          event["response"], context: context, model: model,
          configuration: configuration.imageGeneration, authorModels: configuration.models)
      })
    defer { peer.detachEvidence(lane: lane) }
    do {
      try await withProgressDeadline(budget: configuration.budget) { progress in
        try Task.checkCancellation()
        guard downstream?.isClosed != true else { throw CancellationError() }
        peer.markDispatched(lane: lane)
        let upload = RequestUpload(bytes: frame.count, transport: "websocket")
        defer { upload.finish() }
        try await peer.writer.send(frame, requestUpload: true)
        upload.sent()
        progress.requestSent()
        let account: AccountRouteIdentity?
        if let gateway, case .pool = gateway {
          account = try .init(
            id: context.admission.owner.identity, namespace: context.admission.owner.namespace)
        } else {
          account = nil
        }
        var total = 0
        var observedMetadata = false
        var bufferedMetadata: [JSONValue] = []
        var lifecycle = false
        do {
          while true {
            let data = try await peer.next(lane: lane)
            context.observeUpstreamEvent()
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
            observeDisconnectedOutcome(downstream, context: context)
            let type = try ProviderObservation.eventType(event)
            protocolExtensions?.recordUpstreamEvent(event)
            await observeResponseMetadata(event, account: account, returned: &observedMetadata)
            if type == "error" { throw ProviderObservation.providerFailure(event) }
            if ProviderObservation.terminalEvents.contains(type),
              !context.providerRejectedBeforeOutput
            {
              try request.observeUsage(
                event["response"], context: context, model: model,
                configuration: configuration.imageGeneration, authorModels: configuration.models)
            }
            let observation = try ProviderObservation(
              event: event, model: model, allowImages: request.requirements.imageModel != nil)
            context.observeActualServiceTier(observation.actualServiceTier)
            progress.note(event: event)
            for object in observation.bindings { try await context.bind(object) }
            try observeTerminalOutcome(event, context: context)
            if !ProviderEventSemantics(event).connectionMetadata {
              lifecycle = true
            }
            if !lifecycle {
              bufferedMetadata.append(event)
              continue
            }
            if request.streaming {
              for metadata in bufferedMetadata { try await emit(metadata) }
              bufferedMetadata.removeAll()
              try await emit(
                ProviderObservation.clientOutput(event)
              )
            } else if observation.terminal {
              let response = event["response"]!
              try await emit(
                ProviderObservation.clientOutput(response))
            }
            if observation.terminal { try observeSubmittedTerminal(event, context: context) }
            if observation.terminal {
              peer.delivered(event)
              break
            }
          }
        } catch {
          let refusal =
            (error as? GatewayProtocolError)?.upstreamWebSocketCloseCode == 1009
            && peer.mayAcceptSizeRefusal(lane: lane)
          // Only the unprocessed 1009 discards metadata. Other failures retain the
          // established streamed-event/error behavior, including committed SSE status.
          if !refusal, !lifecycle, request.streaming {
            for metadata in bufferedMetadata { try await emit(metadata) }
          }
          throw error
        }
      }
    } catch let error as GatewayProtocolError
      where error.upstreamWebSocketCloseCode == 1009
    {
      let refused = peer.mayAcceptSizeRefusal(lane: lane)
      ProtocolFailureDiagnostics.recordOversizedFrame(
        bytes: frame.count, path: refused ? sizeRefusalPath : "indeterminate_1009",
        closeCode: 1009)
      guard refused else { throw error }
      if !allowSizeFallback {
        try observeProviderRejection(context)
        try context.observeOutcome(
          .init(failure: .invalidRequest, atUnixSeconds: context.clock.unixSeconds))
      }
      throw GatewayProtocolError(
        413, UpstreamWebSocketBodyLimit.errorCode, upstreamWebSocketCloseCode: 1009)
    } catch {
      ProtocolFailureDiagnostics.recordUpstreamBeforeFirstEvent(
        error, stage: .webSocketTurn, context: context)
      throw error
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

/// A detached native turn may settle usage, but its caller still cancelled the response.
private func observeDisconnectedOutcome(_ downstream: WebSocketPeer?, context: ExecutionContext) {
  guard downstream?.isClosed == true else { return }
  try? context.observeOutcome(
    .init(failure: .clientCancelled, atUnixSeconds: context.clock.unixSeconds))
}
