import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1

extension HTTPResponseExecution {
  func executeImage(
    _ request: ImagesRequest, requestID: String, headers: HTTPHeaders,
    receiveHeaders: @escaping @Sendable (HTTPHeaders) async -> Void,
    begin: @escaping @Sendable (HTTPHeaders) async throws -> Void,
    emit: @escaping @Sendable (Data) async throws -> Void,
    finish: @escaping @Sendable () async throws -> Void
  ) async throws {
    guard gateway != nil else { throw ExecutionError.unauthorized }
    guard let model = effectiveImageModels.first(where: { $0.id == request.model }) else {
      throw GatewayProtocolError(403, "model_not_allowed")
    }
    let permit = try await imageCapacity.acquire()
    defer { permit.release() }
    try Task.checkCancellation()
    try await withExecutionDeadline(seconds: configuration.budget.total) {
      try await executeRouted(
        model: request.model, references: [], requestID: requestID, mode: .generation,
        turnState: try requestTurnState(headers: clientHeaders),
        requirements: try .init(route: .images, imageModel: request.model),
        serviceTier: request.serviceTier
      ) { context, authorization in
        try await withProgressDeadline(budget: configuration.budget) { progress in
          progress.noteUpload()
          let base = authorization?.baseURL ?? configuration.upstreamBaseURL
          guard var url = URLComponents(string: base) else { throw ExecutionError.invalidCommand }
          url.path = "/backend-api/codex/images/" + (request.editing ? "edits" : "generations")
          var upstream = HTTPClientRequest(url: url.string!)
          upstream.method = .POST
          upstream.headers = try forwardedClientHeaders(
            headers, fingerprint: configuration.clientFingerprint, registry: protocolExtensions)
          upstream.headers.add(name: "content-type", value: "application/json")
          let upstreamStreaming = !request.editing
          var wireBody = request.body
          if upstreamStreaming != request.streaming {
            var document = try JSONValue.decode(wireBody).object!
            document["stream"] = .bool(upstreamStreaming)
            wireBody = try JSONValue.object(document).data(escapingSlashes: false)
          }
          upstream.headers.add(
            name: "accept", value: upstreamStreaming ? "text/event-stream" : "application/json")
          if let authorization {
            for header in authorization.headers {
              upstream.headers.add(name: header.name, value: header.value)
            }
          } else if let token {
            upstream.headers.add(name: "authorization", value: "Bearer " + token)
          }
          let upload = RequestUpload(bytes: wireBody.count, transport: "http")
          defer { upload.finish() }
          upstream.body = .stream(
            UploadBody(
              data: wireBody, progress: progress, upload: upload, trackUploadProgress: true),
            length: .known(Int64(wireBody.count)))
          let diagnostics = NativeImageDiagnostics(
            streaming: upstreamStreaming, editing: request.editing,
            requestBytes: wireBody.count)
          var attemptError: (any Error)?
          defer { diagnostics.record(error: attemptError, requestID: requestID) }
          do {
            let response = try await client.execute(
              upstream, deadline: .now() + .seconds(Int64(configuration.budget.total + 5)))
            diagnostics.receivedHeaders(
              status: Int(response.status.code),
              contentType: response.headers.first(name: "content-type"))
            var replyHeaders = forwardedResponseHeaders(response.headers)
            for name in ["content-type", "x-codex-imagegen-request-id"] {
              if let value = response.headers.first(name: name) {
                replyHeaders.add(name: name, value: value)
              }
            }
            await observeResponseHeaders(response.headers, account: authorization?.identity)
            await receiveHeaders(replyHeaders)
            guard response.status == .ok else {
              throw await ProviderError.failure(response: response, diagnostics: diagnostics)
            }
            if request.streaming,
              NativeImageDiagnostics.contentTypeToken(response.headers.first(name: "content-type"))
                == "json"
            {
              let body = try await collectProgressBody(
                response.body, progress: progress, maximum: ImageLimits.nativeResponseBytes,
                onChunk: { diagnostics.receivedBody(bytes: $0) })
              guard let document = try? JSONValue.decode(body) else {
                throw GatewayProtocolError(502, "invalid_upstream_image")
              }
              context.observeUpstreamEvent()
              let observation = NativeImageObservation(document, model: model)
              context.observeActualServiceTier(requestMetadataValue(document["service_tier"]))
              if let usage = observation.usage { try context.observeUsage(usage) }
              _ = try NativeImageResult.validated(document)
              replyHeaders.replaceOrAdd(name: "content-type", value: "text/event-stream")
              try await begin(replyHeaders)
              for event in NativeImageResult.completions(document, editing: request.editing) {
                var data = Data(("event: " + event["type"]!.string! + "\ndata: ").utf8)
                data.append(try event.data())
                data.append(Data("\n\n".utf8))
                try await emit(data)
              }
              try await emit(Data("data: [DONE]\n\n".utf8))
            } else if request.streaming
              || (upstreamStreaming
                && NativeImageDiagnostics.contentTypeToken(
                  response.headers.first(name: "content-type"))
                  == "sse")
            {
              guard
                response.headers.first(name: "content-type")?.lowercased().split(separator: ";")
                  .first
                  == "text/event-stream"
              else {
                throw GatewayProtocolError(502, "invalid_upstream_content_type")
              }
              var decoder = SSEDecoder(
                maximumEventBytes: ImageLimits.nativeResponseBytes,
                maximumTotalBytes: ImageLimits.nativeResponseBytes)
              var terminals: [JSONValue] = []
              var cumulativeUsage: JSONValue = .object([:])
              var imageCount: Int64 = 0
              // Pending wire bytes cover only the current event; total retained output is bounded
              // by the decoder stream limit.
              var pending = Data()
              if request.streaming { try await begin(replyHeaders) }
              for try await chunk in response.body {
                diagnostics.receivedBody(bytes: chunk.readableBytes)
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
                    if type
                      == (request.editing ? "image_edit.completed" : "image_generation.completed")
                    {
                      // An explicit image index identifies delivery even if counters change.
                      // Without an index only an identical event proves duplicate delivery.
                      let duplicate = terminals.contains {
                        $0 == event
                          || (event["image_index"] != nil
                            && $0["image_index"] == event["image_index"])
                      }
                      context.observeActualServiceTier(requestMetadataValue(event["service_tier"]))
                      cumulativeUsage = NativeImageObservation.mergingUsage(
                        cumulativeUsage, event["usage"])
                      if !duplicate {
                        imageCount +=
                          NativeImageObservation(event, model: model, streaming: true).images
                      }
                      var snapshot = event.object!
                      snapshot["usage"] = cumulativeUsage
                      let observation = NativeImageObservation(
                        .object(snapshot), model: model, streaming: true,
                        revision: Int64(terminals.count + 1), images: imageCount)
                      if let usage = observation.usage { try context.observeUsage(usage) }
                      // Preserve counters even when delivery, completion metadata or output is invalid.
                      guard !duplicate else {
                        throw GatewayProtocolError(502, "invalid_upstream_image")
                      }
                      terminals.append(event)
                      _ = try NativeImageResult.assembled(event)
                    }
                  }
                  if decoder.isAtEventBoundary {
                    if request.streaming { try await emit(pending) }
                    pending.removeAll(keepingCapacity: true)
                  }
                }
              }
              try decoder.finish()
              guard let terminal = terminals.first else {
                throw GatewayProtocolError(502, "execution_indeterminate")
              }
              if !request.streaming {
                var result = try NativeImageResult.assembled(terminal).object!
                result["data"] = .array(
                  try terminals.flatMap {
                    try NativeImageResult.assembled($0)["data"]!.array!
                  })
                if cumulativeUsage.object?.isEmpty == false { result["usage"] = cumulativeUsage }
                replyHeaders.replaceOrAdd(name: "content-type", value: "application/json")
                try await begin(replyHeaders)
                try await emit(JSONValue.object(result).data())
              }
            } else {
              let body = try await collectProgressBody(
                response.body, progress: progress, maximum: ImageLimits.nativeResponseBytes,
                onChunk: { diagnostics.receivedBody(bytes: $0) })
              context.observeUpstreamEvent()
              let document = try? JSONValue.decode(body)
              let observation = document.map { NativeImageObservation($0, model: model) }
              context.observeActualServiceTier(requestMetadataValue(document?["service_tier"]))
              if let usage = observation?.usage { try context.observeUsage(usage) }
              if let document { try NativeImageResult.requireCompletion(document) }
              if observation?.images ?? 0 == 0 {
                try context.observeOutcome(
                  .init(
                    failure: .invalidUpstreamResponse,
                    atUnixSeconds: context.clock.unixSeconds))
              }
              try await begin(replyHeaders)
              try await emit(body)
            }
            try await finish()
            try context.observeOutcome(
              .init(failure: nil, atUnixSeconds: context.clock.unixSeconds))
          } catch {
            attemptError = error
            throw error
          }
        }
        return nil
      }
    }
  }
}

struct NativeImageObservation {
  let images: Int64
  let usage: UsageEvidence?

  /// Native usage is request-level cumulative evidence, including when repeated per image.
  static func mergingUsage(_ previous: JSONValue, _ next: JSONValue?) -> JSONValue {
    var fields = previous.object ?? [:]
    for (key, value) in next?.object ?? [:]
    where !["input_tokens", "output_tokens", "input_tokens_details"].contains(key) {
      fields[key] = value
    }
    for key in ["input_tokens", "output_tokens", "input_tokens_details"] {
      if key == "input_tokens_details", next?[key] != nil {
        fields[key] = mergingDetails(fields[key], next?[key])
      } else if let n = next?[key]?.integer, (0...1_000_000_000).contains(n) {
        fields[key] = .number(Decimal(max(fields[key]?.integer ?? 0, n)))
      }
    }
    return .object(fields)
  }

  private static func mergingDetails(_ previous: JSONValue?, _ next: JSONValue?) -> JSONValue {
    var fields = previous?.object ?? [:]
    for (key, value) in next?.object ?? [:]
    where !["text_tokens", "image_tokens"].contains(key) {
      fields[key] = value
    }
    for key in ["text_tokens", "image_tokens"] {
      if let n = next?[key]?.integer, (0...1_000_000_000).contains(n) {
        fields[key] = .number(Decimal(max(fields[key]?.integer ?? 0, n)))
      }
    }
    return .object(fields)
  }
  init(
    _ document: JSONValue, model: ImageConfiguration.Model, streaming: Bool = false,
    revision: Int64 = 1, images totalImages: Int64? = nil
  ) {
    let items = document["data"]?.array ?? (streaming ? [document] : [])
    images =
      totalImages
      ?? Int64(
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
      revision: revision, inputTokens: 0, outputTokens: 0, cachedTokens: 0,
      images: images, estimatedMicros: cost / 1_000_000 + (cost % 1_000_000 == 0 ? 0 : 1),
      completeness: input != nil && output != nil
        && (document["status"] == nil
          || ["completed", "failed", "cancelled"].contains(document["status"]?.string ?? ""))
        ? .complete : .partial,
      imageInputTokens: input, imageOutputTokens: output,
      imageInputTextTokens: count(document["usage"]?["input_tokens_details"]?["text_tokens"]),
      imageInputImageTokens: count(document["usage"]?["input_tokens_details"]?["image_tokens"]),
      nativeImages: true)
  }
}
