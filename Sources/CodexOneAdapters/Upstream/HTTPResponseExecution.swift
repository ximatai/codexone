import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1

struct HTTPResponseExecution: Sendable {
  var protocolExtensions: ClientProtocolExtensionRegistry? = nil
  var compressionPool: ZstdUploadPool? = nil
  let imageCapacity: ImageCapacity
  var controlCapacity = ControlCapacity()
  var sessionAffinity = SessionAffinity()
  var turnStateOwners = TurnStateOwners()
  var controlHealth = ControlEndpointHealth()
  var receiveResponseHeaders: @Sendable (HTTPHeaders) async -> Void = { _ in }
  var clientHeaders = HTTPHeaders()
  var protocolClientHeaders = HTTPHeaders()
  let client: HTTPClient
  let webSocket: WebSocketUpstream
  let configuration: ResponsesConfiguration
  let token: String?
  let report: @Sendable () async -> ReadinessReport
  let access: DataPlaneAuthorization
  let gateway: ResponsesGateway?
  var connection: AccountRouteIdentity? = nil
  var connectionLifetime: AccountExecutionConnection? = nil
  var currentKeyID: String? = nil
  var keyCapabilities: KeyPolicy? = nil
  var effectiveImageModels: [ImageConfiguration.Model] = []
  let effectiveModels: [SingleIdentityConfiguration.Model]

  func pinned(to identity: AccountRouteIdentity, lifetime: AccountExecutionConnection) -> Self {
    var copy = self
    copy.connection = identity
    copy.connectionLifetime = lifetime
    return copy
  }

  func authorized(_ digest: String?) async throws -> Self {
    let live = access.withLiveModels()
    let configuration = live.source.configuration
    let policy = try await live.policy(digest)
    var permittedAccounts: Set<String> = []
    var accountForModel: [String: String] = [:]
    if case .pool(let pool, _, _, _, _) = live.source, !pool.accountForModel.isEmpty,
      let accounts = live.store as? any AccountGovernanceStore
    {
      accountForModel = pool.accountForModel
      permittedAccounts = Set(
        try await accounts.listAccounts(after: nil).filter {
          $0.mode == .enabled && ($0.authorization == .ready || $0.authorization == .refreshing)
        }.map(\.id))
    }
    let effectiveImages =
      policy.capabilities.map { configuration.imageGeneration?.effective(for: $0) ?? [] } ?? []
    return Self(
      protocolExtensions: protocolExtensions, compressionPool: compressionPool,
      imageCapacity: imageCapacity,
      controlCapacity: controlCapacity,
      sessionAffinity: sessionAffinity, turnStateOwners: turnStateOwners,
      controlHealth: controlHealth,
      receiveResponseHeaders: receiveResponseHeaders, clientHeaders: clientHeaders,
      protocolClientHeaders: protocolClientHeaders, client: client,
      webSocket: webSocket, configuration: configuration, token: token,
      report: report, access: access,
      gateway: try live.gateway(policy), connection: connection,
      connectionLifetime: connectionLifetime, currentKeyID: policy.keyID,
      keyCapabilities: policy.capabilities, effectiveImageModels: effectiveImages,
      effectiveModels: configuration.models.filter {
        policy.models.contains($0.id)
          && (accountForModel[$0.id].map(permittedAccounts.contains) ?? true)
      }.map { model in
        var model = model
        model.visionInput = model.visionInput == true && policy.capabilities?.visionInput == true
        model.imageGeneration =
          model.imageGeneration == true && !effectiveImages.isEmpty
        return model
      })
  }

  func executionModel(_ request: ResponseRequest) throws -> SingleIdentityConfiguration.Model {
    guard let model = effectiveModels.first(where: { $0.id == request.model }),
      !request.requirements.visionInput || model.visionInput == true,
      request.requirements.imageModel == nil
        || (model.imageGeneration == true
          && effectiveImageModels.contains {
            $0.id == request.requirements.imageModel
          })
    else { throw GatewayProtocolError(403, "model_not_allowed") }
    let keyRange = keyCapabilities?.reasoningEfforts?[model.id]
    if request.mode != .warmup, keyRange != nil || model.reasoningSettings?.allowed != nil {
      guard request.document["reasoning_effort"] == nil,
        let effort = request.document["reasoning"]?["effort"]?.string,
        keyRange?.contains(effort) ?? true, model.effectiveReasoningEfforts.contains(effort)
      else { throw GatewayProtocolError(403, "reasoning_effort_not_allowed") }
    }
    return model
  }

  func execute(
    _ request: ResponseRequest, requestID: String,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    do {
      try await withExecutionDeadline(seconds: configuration.budget.total) {
        try await executeHTTP(request, requestID: requestID, emit: emit)
      }
    } catch {
      await recordRejection(request, requestID: requestID, error: error)
      throw error
    }
  }
  private func executeHTTP(
    _ request: ResponseRequest, requestID: String,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard gateway != nil else { throw ExecutionError.unauthorized }
    guard request.mode == .generation || request.mode == .priming || request.streamCompaction else {
      throw GatewayProtocolError(400, "unsupported_execution_mode")
    }
    let model = try executionModel(request)
    let turnState = try requestTurnState(headers: clientHeaders, document: request.document)
    // Discard an oversized WS encoding before allocating the HTTP body.
    let (frame, oversizedBytes): (Data?, Int?) = try {
      guard configuration.upstreamTransport == "websocket" else { return (nil, nil) }
      let encoded = try webSocketFrame(request, turnState: turnState)
      return encoded.count > UpstreamWebSocketBodyLimit.httpRoutingBytes
        ? (nil, encoded.count) : (encoded, nil)
    }()
    let oversized = oversizedBytes != nil
    if let oversizedBytes, let previous = request.document["previous_response_id"],
      previous != .null
    {
      ProtocolFailureDiagnostics.recordOversizedFrame(
        bytes: oversizedBytes, path: "reject_continuation")
      throw UpstreamWebSocketBodyLimit.rejection()
    }
    let wireDocument = try request.preparedDocument(
      contract: configuration.requestContract, nativeWebSocket: false)
    if let oversizedBytes {
      ProtocolFailureDiagnostics.recordOversizedFrame(bytes: oversizedBytes, path: "http")
    }
    try await executeRouted(
      model: request.admissionModel, references: request.references,
      affinityHints: request.affinityHints, requestID: requestID,
      mode: request.mode, turnState: turnState, requirements: request.requirements,
      reasoningEffort: request.reasoningEffort, serviceTier: request.serviceTier
    ) { context, authorization in
      var fallback = oversized
      if let frame {
        do {
          try await webSocket.authorized(authorization, headers: clientHeaders).run(
            diagnosticContext: context,
            receiveHeaders: {
              await observeResponseHeaders($0, account: authorization?.identity)
            }
          ) { peer in
            try peer.beginTurn(compaction: request.streamCompaction)
            try await exchange(
              request, context: context, model: model, peer: peer,
              frame: frame, allowSizeFallback: true,
              sizeRefusalPath: request.document["previous_response_id"] == nil
                || request.document["previous_response_id"] == .null
                ? "http_1009" : "reject_continuation_1009", emit: emit)
          }
          return nil
        } catch let error as GatewayProtocolError
          where error.code == UpstreamWebSocketBodyLimit.errorCode
          && error.upstreamWebSocketCloseCode == 1009
        {
          if let previous = request.document["previous_response_id"], previous != .null {
            try observeProviderRejection(context)
            throw error
          }
          fallback = true
        }
      }
      let isFallback = fallback
      let wireStreaming = wireDocument["stream"]?.bool == true
      try await withProgressDeadline(budget: configuration.budget) { progress in
        var upstream = HTTPClientRequest(
          url: (authorization?.baseURL ?? configuration.upstreamBaseURL) + "/responses")
        upstream.method = .POST
        upstream.headers = clientHeaders
        if isFallback, upstream.headers.first(name: "x-codex-turn-state") == nil,
          let turnState = try requestTurnState(headers: clientHeaders, document: request.document)
        {
          upstream.headers.add(name: "x-codex-turn-state", value: turnState)
        }
        upstream.headers.add(name: "content-type", value: "application/json")
        upstream.headers.add(
          name: "accept", value: wireStreaming ? "text/event-stream" : "application/json")
        if request.usesResponsesLite {
          upstream.headers.add(name: "x-openai-internal-codex-responses-lite", value: "true")
        }
        if let authorization {
          for header in authorization.headers {
            upstream.headers.add(name: header.name, value: header.value)
          }
        } else if let token {
          upstream.headers.add(name: "authorization", value: "Bearer " + token)
        }
        let data = try wireDocument.data()
        // One encoding, one selected account and one attempt, including a 415 negotiation retry.
        let canCompress =
          configuration.requestContract == .codexSubscription
          && configuration.upstreamRequestCompression == "zstd"
          && data.count > configuration.upstreamZstdMinimumBytes
        let template = upstream
        @Sendable func send(compressed: Bool) async throws -> (
          HTTPClientResponse, ZstdUpload?, RequestUpload
        ) {
          var outgoing = template
          outgoing.headers.remove(name: "content-length")
          outgoing.headers.remove(name: "transfer-encoding")
          outgoing.headers.remove(name: "content-encoding")
          let upload = RequestUpload(
            bytes: data.count, transport: "http", encoding: compressed ? "zstd" : "identity")
          let owner: ZstdUpload?
          if compressed, let compressionPool {
            let zstd = ZstdUpload(
              data: data, pool: compressionPool, progress: progress, upload: upload)
            owner = zstd
            outgoing.headers.add(name: "content-encoding", value: "zstd")
            outgoing.body = .stream(ZstdUploadBody(owner: zstd), length: .unknown)
          } else {
            owner = nil
            outgoing.body = .stream(
              UploadBody(data: data, progress: progress, upload: upload),
              length: .known(Int64(data.count)))
          }
          do {
            let response = try await client.execute(
              outgoing, deadline: .now() + .seconds(Int64(configuration.budget.total + 5)))
            // Headers can precede upload EOF for either encoding. Rejections finish
            // immediately; successful uploads finish at EOF or exchange exit.
            if !(200..<300).contains(response.status.code) {
              if let owner { await owner.close() }
              upload.finish()
            }
            return (response, owner, upload)
          } catch {
            ProtocolFailureDiagnostics.recordUpstreamBeforeFirstEvent(
              error, stage: .httpRequest, context: context)
            if let owner { await owner.close() }
            upload.finish()
            throw error
          }
        }
        let compressed = canCompress && compressionPool?.reserve() == true
        var firstResponse: HTTPClientResponse?
        let owner: ZstdUpload?
        var upload: RequestUpload
        (firstResponse, owner, upload) = try await send(compressed: compressed)
        let response: HTTPClientResponse
        if compressed, firstResponse?.status == .unsupportedMediaType {
          // No HTTP body events have been read; a prior WS fallback also proves no lifecycle.
          // Negotiate once without changing admission or account health.
          // Dispose the rejected response before creating a new connection; never re-encode Data.
          firstResponse = nil
          progress.negotiateUpload()
          (response, _, upload) = try await send(compressed: false)
        } else {
          response = firstResponse!
        }
        defer { upload.finish() }
        do {
          await observeResponseHeaders(
            response.headers, account: authorization?.identity, includeModel: response.status == .ok
          )
          guard response.status == .ok else {
            if isFallback, (400...499).contains(Int(response.status.code)) {
              try observeProviderRejection(context)
            }
            if isFallback, response.status == .payloadTooLarge {
              throw UpstreamWebSocketBodyLimit.rejection(upstreamStatus: 413)
            }
            throw await ProviderError.failure(response: response)
          }
          if wireStreaming {
            let header = response.headers.first(name: "content-type")?
              .trimmingCharacters(in: .whitespacesAndNewlines)
            let media =
              header?
              .components(separatedBy: ";").first?
              .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if header == nil || header == "" {
              ProtocolFailureDiagnostics.recordMissingStreamMediaType(requestID: requestID)
            } else if media != "text/event-stream" {
              let detail: ProtocolRejectionDetail =
                media == "application/json"
                ? .upstreamMediaTypeJSON
                : media == "text/html" ? .upstreamMediaTypeHTML : .upstreamMediaTypeOther
              throw GatewayProtocolError(
                502, "invalid_upstream_content_type", detail: detail, upstreamStatus: 200)
            }
            var decoder = SSEDecoder(
              maximumEventBytes: request.requirements.imageModel == nil
                ? ProviderObservation.maximumTextEventBytes : ImageLimits.eventBytes,
              maximumTotalBytes: request.requirements.imageModel == nil
                ? ProviderObservation.maximumTextResponseBytes : ImageLimits.responseBytes)
            var responseID: String?
            var terminal = false
            var observedMetadata = false
            var firstHTTPEvent = true
            readUpstream: for try await chunk in response.body {
              try Task.checkCancellation()
              for byte in chunk.readableBytesView {
                guard let event = try decoder.append(byte) else { continue }
                context.observeUpstreamEvent()
                guard !terminal else { break readUpstream }
                try observeProviderEvent(
                  event, context: context,
                  firstAfterUnprocessedRefusal: isFallback && firstHTTPEvent)
                firstHTTPEvent = false
                let type = try ProviderObservation.eventType(event)
                protocolExtensions?.recordUpstreamEvent(event)
                if type == "error" { throw ProviderObservation.providerFailure(event) }
                // A foreign response cannot supply evidence to this attempt.
                if ProviderObservation.lifecycleEvents.contains(type),
                  let response = event["response"]
                {
                  guard let id = ProviderObservation.identifier(response["id"]),
                    responseID == nil || responseID == id
                  else { throw GatewayProtocolError(502, "invalid_upstream_turn") }
                  responseID = id
                }
                if let id = event["response_id"],
                  id.string == nil
                    || responseID.map({ $0 != id.string })
                      == true
                {
                  throw GatewayProtocolError(502, "invalid_upstream_turn")
                }
                await observeResponseMetadata(
                  event, account: authorization?.identity, returned: &observedMetadata)
                // Trusted usage must survive later binding/output failures.
                if ProviderObservation.terminalEvents.contains(type),
                  !context.providerRejectedBeforeOutput
                {
                  try request.observeUsage(
                    event["response"], context: context, model: model,
                    configuration: configuration.imageGeneration, authorModels: configuration.models
                  )
                }
                let observation = try ProviderObservation(
                  event: event, model: model, allowImages: request.requirements.imageModel != nil)
                context.observeActualServiceTier(observation.actualServiceTier)
                progress.note(event: event)
                for object in observation.bindings { try await context.bind(object) }
                try observeTerminalOutcome(event, context: context)
                terminal = observation.terminal
                if request.streaming || terminal {
                  let output = request.streaming ? event : event["response"]!
                  try await emit(
                    ProviderObservation.clientOutput(output))
                }
                if terminal { try observeSubmittedTerminal(event, context: context) }
                if terminal { break readUpstream }
              }
            }
            if !terminal { try decoder.finish() }
            guard terminal else { throw GatewayProtocolError(502, "execution_indeterminate") }
          } else {
            guard
              response.headers.first(name: "content-type")?.lowercased().hasPrefix(
                "application/json")
                == true
            else {
              throw GatewayProtocolError(502, "invalid_upstream_content_type")
            }
            let body = try await collectProgressBody(
              response.body, progress: progress,
              maximum: request.requirements.imageModel == nil
                ? ProviderObservation.maximumTextResponseBytes : ImageLimits.eventBytes)
            let document: JSONValue
            do {
              document = try JSONValue.decode(body)
            } catch { throw GatewayProtocolError(502, "invalid_upstream_response") }
            let status = document["status"]?.string
            guard ["completed", "failed", "incomplete"].contains(status ?? "") else {
              throw GatewayProtocolError(502, "execution_indeterminate")
            }
            context.observeUpstreamEvent()
            try request.observeUsage(
              document, context: context, model: model, configuration: configuration.imageGeneration
            )
            let event = JSONValue.object([
              "type": .string("response." + status!), "response": document,
            ])
            let observation = try ProviderObservation(
              event: event, model: model, allowImages: request.requirements.imageModel != nil)
            context.observeActualServiceTier(observation.actualServiceTier)
            for object in observation.bindings { try await context.bind(object) }
            try observeTerminalOutcome(event, context: context)
            try await emit(
              ProviderObservation.clientOutput(document))
            try observeSubmittedTerminal(event, context: context)
          }
        } catch {
          ProtocolFailureDiagnostics.recordUpstreamBeforeFirstEvent(
            error, stage: .httpResponse, context: context, responseStatus: Int(response.status.code)
          )
          if let owner { await owner.close() }
          throw error
        }
        if let owner { await owner.close() }
      }
      return nil
    }
  }
  func recordRejection(_ request: ResponseRequest?, requestID: String, error: any Error) async {
    guard let currentKeyID, let diagnostics = access.diagnostics else { return }
    let model = request.flatMap { request in
      configuration.models.contains(where: { $0.id == request.model }) ? request.model : nil
    }
    // This known local refusal is not an unknown execution. Keep the execution-time
    // mapping unchanged; the diagnostics store separately excludes committed intents.
    let failure =
      if let mapped = error as? GatewayProtocolError,
        mapped.status == 400, mapped.code == "unsupported_backend_parameter"
      {
        ExecutionFailure.invalidRequest
      } else {
        executionFailure(error)
      }
    let mapped = protocolFailure(error)
    let reason =
      mapped.detail.flatMap { RejectionReason(rawValue: $0.rawValue) }
      ?? RejectionReason(rawValue: mapped.code)
    try? await diagnostics.recordRejection(
      requestID: requestID, keyID: currentKeyID,
      model: model, mode: request?.mode ?? .generation, failure: failure, reason: reason)
  }

}

/// The client's header deadline does not cover streaming body consumption.
func withExecutionDeadline<Value: Sendable>(
  seconds: Int,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  let cause = ExecutionDeadlineCause(parent: ExecutionDeadlineScope.cause)
  return try await ExecutionDeadlineScope.$cause.withValue(cause) {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        cause.expire()
        throw GatewayProtocolError(504, "execution_deadline_exceeded")
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }
}

func collectProgressBody(
  _ body: HTTPClientResponse.Body, progress: ExecutionProgress, maximum: Int,
  onChunk: (@Sendable (Int) -> Void)? = nil
) async throws -> Data {
  var data = Data()
  for try await chunk in body {
    onChunk?(chunk.readableBytes)
    try Task.checkCancellation()
    guard chunk.readableBytes <= maximum - data.count else {
      throw GatewayProtocolError(502, "upstream_response_too_large")
    }
    if chunk.readableBytes > 0 { progress.note() }
    data.append(contentsOf: chunk.readableBytesView)
  }
  return data
}
