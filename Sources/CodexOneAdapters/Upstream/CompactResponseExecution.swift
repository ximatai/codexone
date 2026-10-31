import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1

extension HTTPResponseExecution {
  func compact(
    _ request: ResponseRequest, requestID: String,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    do { try await compactHTTP(request, requestID: requestID, emit: emit) } catch {
      await recordRejection(request, requestID: requestID, error: error)
      throw error
    }
  }
  private func compactHTTP(
    _ request: ResponseRequest, requestID: String,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard let gateway else { throw ExecutionError.unauthorized }
    let model = try executionModel(request)
    guard request.mode == .compact, !request.streamCompaction
    else { throw GatewayProtocolError(403, "model_not_allowed") }
    try await gateway.execute(
      model: request.model, references: request.references, affinityHints: request.affinityHints,
      requestID: requestID, mode: .compact,
      requirements: request.requirements
    ) { context, authorization in
      try await withProgressDeadline(budget: configuration.budget) { progress in
        var upstream = HTTPClientRequest(
          url: (authorization?.baseURL ?? configuration.upstreamBaseURL) + "/responses/compact")
        upstream.method = .POST
        upstream.headers = clientHeaders
        upstream.headers.add(name: "content-type", value: "application/json")
        upstream.headers.add(name: "accept", value: "application/json")
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
        upstream.body = .bytes(ByteBuffer(data: try request.document.data()))
        // The structured deadline owns classification; the client is a later transport fallback.
        let response = try await client.execute(
          upstream, deadline: .now() + .seconds(Int64(configuration.budget.total + 5)))
        guard response.status == .ok else {
          throw await ProviderError.failure(response: response, compact: true)
        }
        guard
          response.headers.first(name: "content-type")?.lowercased().hasPrefix("application/json")
            == true
        else { throw GatewayProtocolError(502, "invalid_upstream_content_type") }
        let body = try await collectProgressBody(
          response.body, progress: progress,
          maximum: ProviderObservation.maximumTextResponseBytes)
        context.observeUpstreamEvent()
        let document: JSONValue
        do { document = try JSONValue.decode(body) } catch {
          throw GatewayProtocolError(502, "invalid_upstream_response")
        }
        guard document["object"]?.string == "response.compaction" else {
          throw GatewayProtocolError(502, "invalid_upstream_compaction")
        }
        if let evidence = ProviderObservation.usage(document["usage"], model: model) {
          try context.observeUsage(evidence)
        }
        if let id = ProviderObservation.identifier(document["id"]) {
          try await context.bind(.init(type: "compaction", rawID: id))
        }
        for item in document["output"]?.array ?? [] {
          for binding in try ProviderObservation.itemBindings(item) {
            try await context.bind(binding)
          }
        }
        // The canonical compacted window is returned intact; it is not a generated response ID.
        try await emit(document)
      }
      return nil
    }
  }
}
