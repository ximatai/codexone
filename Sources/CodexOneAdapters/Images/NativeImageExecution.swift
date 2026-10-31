import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1

/// Client metadata only; credentials, routing and arbitrary internal headers never cross.
func forwardedClientHeaders(
  _ headers: HTTPHeaders, fingerprint: ClientFingerprint = .init().resolved(models: [])
) -> HTTPHeaders {
  let allowed: Set<String> = [
    "user-agent", "originator", "version", "session_id", "x-codex-turn-metadata",
    "x-codex-image-turn-id", "x-codex-turn-state", "x-session-id", "conversation_id",
    "x-conversation-id",
  ]
  let connectionHeaders = Set(
    headers["connection"].flatMap {
      $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    })
  var result = HTTPHeaders()
  for header in headers
  where allowed.contains(header.name.lowercased())
    && !connectionHeaders.contains(header.name.lowercased())
  {
    if header.value.utf8.count <= 8192 { result.add(name: header.name, value: header.value) }
  }
  if !ClientFingerprint.isNative(headers) {
    for name in ["user-agent", "originator", "version"] { result.remove(name: name) }
    result.add(name: "user-agent", value: fingerprint.userAgent)
    result.add(name: "originator", value: "codex_cli_rs")
    result.add(name: "version", value: fingerprint.version!)
  }
  return result
}

extension HTTPResponseExecution {
  func executeImage(
    _ request: ImagesRequest, requestID: String, headers: HTTPHeaders,
    receiveHeaders: @escaping @Sendable (HTTPHeaders) async -> Void,
    begin: @escaping @Sendable (HTTPHeaders) async throws -> Void,
    emit: @escaping @Sendable (Data) async throws -> Void,
    finish: @escaping @Sendable () async throws -> Void
  ) async throws {
    guard let gateway else { throw ExecutionError.unauthorized }
    guard let model = effectiveImageModels.first(where: { $0.id == request.model }) else {
      throw GatewayProtocolError(403, "model_not_allowed")
    }
    let permit = try await imageCapacity.acquire()
    defer { permit.release() }
    try Task.checkCancellation()
    try await gateway.execute(
      model: request.model, references: [], requestID: requestID, mode: .generation,
      requirements: try .init(route: .images, imageModel: request.model)
    ) { context, authorization in
      try await withProgressDeadline(budget: configuration.budget) { progress in
        let base = authorization?.baseURL ?? configuration.upstreamBaseURL
        guard var url = URLComponents(string: base) else { throw ExecutionError.invalidCommand }
        url.path = "/backend-api/codex/images/" + (request.editing ? "edits" : "generations")
        var upstream = HTTPClientRequest(url: url.string!)
        upstream.method = .POST
        upstream.headers = forwardedClientHeaders(
          headers, fingerprint: configuration.clientFingerprint)
        upstream.headers.add(name: "content-type", value: "application/json")
        upstream.headers.add(
          name: "accept", value: request.streaming ? "text/event-stream" : "application/json")
        if let authorization {
          for header in authorization.headers {
            upstream.headers.add(name: header.name, value: header.value)
          }
        } else if let token {
          upstream.headers.add(name: "authorization", value: "Bearer " + token)
        }
        upstream.body = .bytes(ByteBuffer(data: request.body))
        let response = try await client.execute(
          upstream, deadline: .now() + .seconds(Int64(configuration.budget.total + 5)))
        var replyHeaders = HTTPHeaders()
        for name in ["content-type", "x-codex-imagegen-request-id"] {
          if let value = response.headers.first(name: name) {
            replyHeaders.add(name: name, value: value)
          }
        }
        await receiveHeaders(replyHeaders)
        guard response.status == .ok else { throw await ProviderError.failure(response: response) }
        if request.streaming {
          guard
            response.headers.first(name: "content-type")?.lowercased().split(separator: ";").first
              == "text/event-stream"
          else {
            throw GatewayProtocolError(502, "invalid_upstream_content_type")
          }
          var decoder = SSEDecoder(
            maximumEventBytes: ImageLimits.nativeResponseBytes,
            maximumTotalBytes: ImageLimits.nativeResponseBytes)
          var terminal: JSONValue?
          // Retain only the current event; decoder enforces the event and stream limits.
          var pending = Data()
          try await begin(replyHeaders)
          for try await chunk in response.body {
            try Task.checkCancellation()
            for byte in chunk.readableBytesView {
              let event = try decoder.append(byte)
              pending.append(byte)
              if let event {
                context.observeUpstreamEvent()
                progress.note()
                try observeProviderEvent(event, context: context)
                let type = event["type"]?.string ?? ""
                if type == "error" { throw ProviderObservation.providerFailure(event) }
                if type == (request.editing ? "image_edit.completed" : "image_generation.completed")
                {
                  guard terminal == nil else {
                    throw GatewayProtocolError(502, "invalid_upstream_image")
                  }
                  terminal = event
                  let observation = NativeImageObservation(event, model: model, streaming: true)
                  if let usage = observation.usage { try context.observeUsage(usage) }
                }
              }
              if decoder.isAtEventBoundary {
                try await emit(pending)
                pending.removeAll(keepingCapacity: true)
              }
            }
          }
          try decoder.finish()
          guard let terminal else { throw GatewayProtocolError(502, "execution_indeterminate") }
          let observation = NativeImageObservation(terminal, model: model, streaming: true)
          guard observation.images > 0 else {
            throw GatewayProtocolError(502, "invalid_upstream_image")
          }
        } else {
          let body = try await collectProgressBody(
            response.body, progress: progress, maximum: ImageLimits.nativeResponseBytes)
          context.observeUpstreamEvent()
          let observation = (try? JSONValue.decode(body)).map {
            NativeImageObservation($0, model: model)
          }
          if let usage = observation?.usage { try context.observeUsage(usage) }
          if observation?.images ?? 0 == 0 {
            try context.observeOutcome(
              .init(
                failure: .invalidUpstreamResponse,
                atUnixSeconds: Int64(Date().timeIntervalSince1970)))
          }
          try await begin(replyHeaders)
          try await emit(body)
        }
        try await finish()
        try context.observeOutcome(
          .init(failure: nil, atUnixSeconds: Int64(Date().timeIntervalSince1970)))
      }
      return nil
    }
  }
}

struct NativeImageObservation {
  let images: Int64
  let usage: UsageEvidence?
  init(_ document: JSONValue, model: ImageConfiguration.Model, streaming: Bool = false) {
    let items = document["data"]?.array ?? (streaming ? [document] : [])
    images = Int64(
      items.filter {
        guard let encoded = $0["b64_json"]?.string, !encoded.isEmpty,
          let bytes = Data(base64Encoded: encoded), !bytes.isEmpty
        else { return false }
        return bytes.base64EncodedString() == encoded
      }.count)
    func count(_ value: JSONValue?) -> Int64? {
      guard let n = value?.integer, (0...1_000_000_000).contains(n) else { return nil }
      return n
    }
    let input = count(document["usage"]?["input_tokens"])
    let output = count(document["usage"]?["output_tokens"])
    let cost =
      (input ?? 0) * model.inputMicrosPerMillion + (output ?? 0) * model.outputMicrosPerMillion
    usage = .init(
      revision: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0,
      images: images, estimatedMicros: cost / 1_000_000 + (cost % 1_000_000 == 0 ? 0 : 1),
      completeness: input != nil && output != nil ? .complete : .partial,
      imageInputTokens: input, imageOutputTokens: output,
      imageInputTextTokens: count(document["usage"]?["input_tokens_details"]?["text_tokens"]),
      imageInputImageTokens: count(document["usage"]?["input_tokens_details"]?["image_tokens"]),
      nativeImages: true)
  }
}
