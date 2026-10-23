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
      model: request.model, references: request.references, requestID: requestID, mode: .compact,
      requirements: request.requirements
    ) { context, authorization in
      try await withProgressDeadline(budget: configuration.budget) { progress in
        var upstream = HTTPClientRequest(
          url: (authorization?.baseURL ?? configuration.upstreamBaseURL) + "/responses/compact")
        upstream.method = .POST
        upstream.headers = ["content-type": "application/json", "accept": "application/json"]
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
          throw upstreamRejection(status: response.status, headers: response.headers, compact: true)
        }
        guard
          response.headers.first(name: "content-type")?.lowercased().hasPrefix("application/json")
            == true
        else { throw GatewayProtocolError(502, "invalid_upstream_content_type") }
        let body = try await collectProgressBody(
          response.body, progress: progress, maximum: 262_144)
        let document: JSONValue
        do { document = try JSONValue.decode(body) } catch {
          throw GatewayProtocolError(502, "invalid_upstream_response")
        }
        guard document["object"]?.string == "response.compaction" else {
          throw GatewayProtocolError(502, "invalid_upstream_compaction")
        }
        if let evidence = try ProviderObservation.usage(document["usage"], model: model) {
          try context.observeUsage(evidence)
        }
        try ProviderObservation.validateUsageContainer(document["usage"])
        guard let output = document["output"]?.array, output.count <= 256,
          document.object?.keys.allSatisfy({
            ["id", "object", "created_at", "output", "usage"].contains($0)
          }) == true
        else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
        if let created = document["created_at"] {
          guard let value = created.integer, value >= 0 else {
            throw GatewayProtocolError(502, "invalid_upstream_compaction")
          }
        }
        if let id = document["id"] {
          guard let id = id.string, !id.isEmpty, id.utf8.count <= 256 else {
            throw GatewayProtocolError(502, "invalid_upstream_compaction")
          }
          try await context.bind(.init(type: "compaction", rawID: id))
        }
        var functions = Set<String>()
        var custom = Set<String>()
        for item in request.document["input"]?.array ?? [] {
          if let name = item["name"]?.string {
            let key = try ClientTools.key(name: name, namespace: item["namespace"]?.string)
            if item["type"]?.string == "function_call" { functions.insert(key) }
            if item["type"]?.string == "custom_tool_call" { custom.insert(key) }
          }
        }
        for item in output {
          let bindings = try ProviderObservation.itemBindings(
            item, functionNames: functions, customToolNames: custom, retained: true)
          for binding in bindings where !request.references.contains(binding) {
            // Compaction may retain prior calls; it cannot invent a new client tool execution.
            guard binding.type != "function_call" else {
              throw GatewayProtocolError(502, "unsupported_upstream_object")
            }
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
