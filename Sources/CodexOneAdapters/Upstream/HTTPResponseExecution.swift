import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOHTTP1

struct HTTPResponseExecution: Sendable {
  let client: HTTPClient
  let configuration: SingleIdentityConfiguration
  let token: String?
  let report: @Sendable () -> ReadinessReport
  let gateway: SingleIdentityGateway

  func execute(
    _ request: ResponseRequest, requestID: String,
    emit: @escaping @Sendable (JSONValue) async throws -> Void
  ) async throws {
    guard let model = configuration.models.first(where: { $0.id == request.model }) else {
      throw GatewayProtocolError(403, "model_not_allowed")
    }
    try await gateway.execute(
      model: request.model, references: request.references, requestID: requestID
    ) { context in
      var upstream = HTTPClientRequest(url: configuration.upstreamBaseURL + "/responses")
      upstream.method = .POST
      upstream.headers = [
        "content-type": "application/json",
        "accept": request.streaming ? "text/event-stream" : "application/json",
      ]
      if let token { upstream.headers.add(name: "authorization", value: "Bearer " + token) }
      upstream.body = .bytes(ByteBuffer(data: try request.document.data()))
      let response = try await client.execute(upstream, deadline: .now() + .seconds(120))
      guard response.status == .ok else {
        if response.status == .tooManyRequests {
          throw GatewayProtocolError(429, "upstream_rate_limited")
        }
        throw GatewayProtocolError(502, "upstream_rejected")
      }
      if request.streaming {
        guard
          response.headers.first(name: "content-type")?.lowercased().hasPrefix("text/event-stream")
            == true
        else {
          throw GatewayProtocolError(502, "invalid_upstream_content_type")
        }
        var decoder = SSEDecoder()
        var terminal = false
        readUpstream: for try await chunk in response.body {
          try Task.checkCancellation()
          guard chunk.readableBytes <= 8_388_608 else {
            throw GatewayProtocolError(502, "upstream_response_too_large")
          }
          let events = try decoder.append(Data(chunk.readableBytesView))
          for event in events {
            guard !terminal else { throw GatewayProtocolError(502, "event_after_terminal") }
            // Trusted usage must survive later binding/output failures.
            if ["response.completed", "response.failed", "response.incomplete"].contains(
              event["type"]?.string ?? ""),
              let evidence = try ProviderObservation.usage(
                event["response"]?["usage"], model: model)
            {
              try context.observeUsage(evidence)
            }
            let observation = try ProviderObservation(
              event: event, model: model, functionNames: request.functionNames)
            for object in observation.bindings { try await context.bind(object) }
            terminal = observation.terminal
            try await emit(event)
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
        let body = try await response.body.collect(upTo: 262_144)
        let document: JSONValue
        do {
          document = try JSONValue.decode(Data(body.readableBytesView))
        } catch { throw GatewayProtocolError(502, "invalid_upstream_response") }
        let status = document["status"]?.string
        guard ["completed", "failed", "incomplete"].contains(status ?? "") else {
          throw GatewayProtocolError(502, "execution_indeterminate")
        }
        if let evidence = try ProviderObservation.usage(document["usage"], model: model) {
          try context.observeUsage(evidence)
        }
        let event = JSONValue.object(["type": .string("response." + status!), "response": document])
        let observation = try ProviderObservation(
          event: event, model: model, functionNames: request.functionNames)
        for object in observation.bindings { try await context.bind(object) }
        try await emit(document)
      }
      return nil
    }
  }
}
