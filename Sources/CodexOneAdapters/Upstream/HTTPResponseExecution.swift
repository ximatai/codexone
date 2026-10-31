import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1

struct HTTPResponseExecution: Sendable {
  let imageCapacity: ImageCapacity
  var controlCapacity = ControlCapacity()
  var controlAffinity = ControlAffinity()
  var clientHeaders = HTTPHeaders()
  let client: HTTPClient
  let webSocket: WebSocketUpstream
  let configuration: ResponsesConfiguration
  let token: String?
  let report: @Sendable () async -> ReadinessReport
  let access: DataPlaneAuthorization
  let gateway: ResponsesGateway?
  var connection: AccountRouteIdentity? = nil
  var currentKeyID: String? = nil
  var effectiveImageModels: [ImageConfiguration.Model] = []
  let effectiveModels: [SingleIdentityConfiguration.Model]

  func pinned(to identity: AccountRouteIdentity) -> Self {
    var copy = self
    copy.connection = identity
    return copy
  }

  func authorized(_ digest: String?) async throws -> Self {
    let policy = try await access.policy(digest)
    let effectiveImages =
      policy.capabilities.map { configuration.imageGeneration?.effective(for: $0) ?? [] } ?? []
    return Self(
      imageCapacity: imageCapacity, controlCapacity: controlCapacity,
      controlAffinity: controlAffinity, clientHeaders: clientHeaders, client: client,
      webSocket: webSocket, configuration: configuration, token: token,
      report: report, access: access,
      gateway: try access.gateway(policy), connection: connection, currentKeyID: policy.keyID,
      effectiveImageModels: effectiveImages,
      effectiveModels: configuration.models.filter { policy.models.contains($0.id) }.map { model in
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
    return model
  }

  func execute(
    _ request: ResponseRequest, requestID: String,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    do { try await executeHTTP(request, requestID: requestID, emit: emit) } catch {
      await recordRejection(request, requestID: requestID, error: error)
      throw error
    }
  }
  private func executeHTTP(
    _ request: ResponseRequest, requestID: String,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard let gateway else { throw ExecutionError.unauthorized }
    guard request.mode == .generation || request.streamCompaction else {
      throw GatewayProtocolError(400, "unsupported_execution_mode")
    }
    let model = try executionModel(request)
    let wireDocument = try request.preparedDocument(
      contract: configuration.requestContract, nativeWebSocket: false)
    let wireStreaming = wireDocument["stream"]?.bool == true
    if configuration.upstreamTransport == "websocket" {
      try await gateway.execute(
        model: request.admissionModel, references: request.references,
        affinityHints: request.affinityHints, requestID: requestID,
        mode: request.mode, requirements: request.requirements
      ) { context, authorization in
        try await withExecutionDeadline(seconds: configuration.budget.total) {
          try await webSocket.authorized(authorization).run { peer in
            try peer.beginTurn(compaction: request.streamCompaction)
            try await exchange(request, context: context, model: model, peer: peer, emit: emit)
          }
        }
        return nil
      }
      return
    }
    try await gateway.execute(
      model: request.admissionModel, references: request.references,
      affinityHints: request.affinityHints, requestID: requestID,
      mode: request.mode, requirements: request.requirements
    ) { context, authorization in
      try await withProgressDeadline(budget: configuration.budget) { progress in
        var upstream = HTTPClientRequest(
          url: (authorization?.baseURL ?? configuration.upstreamBaseURL) + "/responses")
        upstream.method = .POST
        upstream.headers = clientHeaders
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
        upstream.body = .bytes(
          ByteBuffer(
            data: try wireDocument.data())
        )
        // The structured deadline owns classification; the client is a later transport fallback.
        let response = try await client.execute(
          upstream, deadline: .now() + .seconds(Int64(configuration.budget.total + 5)))
        if let identity = authorization?.identity, let key = currentKeyID {
          controlAffinity.observe(key: key, headers: clientHeaders, account: identity)
          controlAffinity.observe(key: key, headers: response.headers, account: identity)
        }
        guard response.status == .ok else {
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
          readUpstream: for try await chunk in response.body {
            try Task.checkCancellation()
            for byte in chunk.readableBytesView {
              guard let event = try decoder.append(byte) else { continue }
              context.observeUpstreamEvent()
              guard !terminal else { break readUpstream }
              let type = try ProviderObservation.eventType(event)
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
              // Trusted usage must survive later binding/output failures.
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
              terminal = observation.terminal
              if request.streaming || terminal {
                let output = request.streaming ? event : event["response"]!
                try await emit(
                  request.requirements.imageModel == nil
                    ? ProviderObservation.textOutput(output) : output)
              }
              if terminal { try observeSubmittedTerminal(event, context: context) }
              if terminal { break readUpstream }
            }
          }
          if !terminal { try decoder.finish() }
          guard terminal else { throw GatewayProtocolError(502, "execution_indeterminate") }
        } else {
          guard
            response.headers.first(name: "content-type")?.lowercased().hasPrefix("application/json")
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
            document, context: context, model: model, configuration: configuration.imageGeneration)
          let event = JSONValue.object([
            "type": .string("response." + status!), "response": document,
          ])
          let observation = try ProviderObservation(
            event: event, model: model, allowImages: request.requirements.imageModel != nil)
          for object in observation.bindings { try await context.bind(object) }
          try observeTerminalOutcome(event, context: context)
          try await emit(
            request.requirements.imageModel == nil
              ? ProviderObservation.textOutput(document) : document)
          try observeSubmittedTerminal(event, context: context)
        }
      }
      return nil
    }
  }
  func recordRejection(_ request: ResponseRequest?, requestID: String, error: any Error) async {
    guard let currentKeyID, let diagnostics = access.diagnostics else { return }
    let model = request.flatMap { request in
      configuration.models.contains(where: { $0.id == request.model }) ? request.model : nil
    }
    try? await diagnostics.recordRejection(
      requestID: requestID, keyID: currentKeyID,
      model: model, mode: request?.mode ?? .generation, failure: executionFailure(error))
  }

}

/// The client's header deadline does not cover streaming body consumption.
func withExecutionDeadline<Value: Sendable>(
  seconds: Int,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw GatewayProtocolError(504, "execution_deadline_exceeded")
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

func collectProgressBody(_ body: HTTPClientResponse.Body, progress: ExecutionProgress, maximum: Int)
  async throws -> Data
{
  var data = Data()
  for try await chunk in body {
    try Task.checkCancellation()
    guard chunk.readableBytes <= maximum - data.count else {
      throw GatewayProtocolError(502, "upstream_response_too_large")
    }
    if chunk.readableBytes > 0 { progress.note() }
    data.append(contentsOf: chunk.readableBytesView)
  }
  return data
}
