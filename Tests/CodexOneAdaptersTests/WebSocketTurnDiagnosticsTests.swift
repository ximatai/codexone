import Foundation
import Testing

@testable import CodexOneAdapters

private func turnFailure(_ turns: WebSocketTurns, _ event: JSONValue) throws -> GatewayProtocolError
{
  do {
    _ = try turns.observe(event.data())
    throw CocoaError(.coderInvalidValue)
  } catch let error as GatewayProtocolError { return error }
}

private func created(_ turns: WebSocketTurns, _ id: String = "synthetic-response") throws {
  #expect(
    try turns.observe(
      JSONValue.object([
        "type": .string("response.created"), "response": .object(["id": .string(id)]),
      ]).data()) == "")
}

@Test func providerErrorEventsEndTheTurnWithActionableSanitizedErrors() throws {
  for (fields, status, code, forwarded): ([String: JSONValue], Int?, String, Bool) in [
    (
      ["type": .string("usage_limit_reached"), "resets_in_seconds": .number(120)], 429,
      "upstream_rate_limited", true
    ),
    (["code": .string("rate_limit_exceeded")], nil, "upstream_rate_limited", true),
    (["code": .string("context_length_exceeded")], 400, "upstream_rejected", true),
    (["code": .string("invalid_api_key")], 401, "upstream_authentication_rejected", false),
    (["code": .string("server_is_overloaded")], 503, "upstream_unavailable", true),
  ] {
    for nested in [true, false] {
      let turns = WebSocketTurns()
      try turns.begin()
      var error = fields
      error["message"] = .string("Limit for org-SyntheticOrg123 reached; contact a@example.com")
      var event: [String: JSONValue] = nested ? ["error": .object(error)] : error
      event["type"] = .string("error")
      if let status { event["status"] = .number(Decimal(status)) }
      // The error belongs to the waiting turn, which becomes idle for the next request.
      #expect(try turns.observe(JSONValue.object(event).data()) == "")
      try turns.begin()
      let failure = ProviderObservation.providerFailure(.object(event))
      #expect(failure.code == code)
      #expect((failure.providerError != nil) == forwarded)
      let envelope = protocolErrorEnvelope(failure, requestID: UUID().uuidString)
      let text = String(decoding: try envelope.data(), as: UTF8.self)
      #expect(!text.contains("SyntheticOrg123") && !text.contains("a@example.com"))
      #expect(envelope["error"]?["request_id"]?.string != nil)
      if forwarded {
        #expect(envelope["error"]?["message"]?.string?.contains("[redacted]") == true)
      }
      let metadata = ProtocolFailureDiagnostics.metadata(failure, requestID: UUID().uuidString)
      #expect(!metadata.description.contains("contact"))
    }
  }
  let limited = ProviderObservation.providerFailure(
    .object([
      "type": .string("error"), "status": .number(429),
      "error": .object([
        "type": .string("usage_limit_reached"), "resets_in_seconds": .number(90),
      ]),
    ]))
  #expect(limited.status == 429 && limited.cooldownSeconds == 90)
  #expect(
    ProtocolFailureDiagnostics.metadata(limited, requestID: UUID().uuidString)["provider_code"]?
      .description == "usage_limit_reached")
}

@Test func turnOwnershipAcceptsProviderExtensionsAndRejectsForeignResponses() throws {
  let turns = WebSocketTurns()
  // Outside a turn, provider notices such as rate-limit updates are dropped, not fatal.
  #expect(
    try turns.observe(JSONValue.object(["type": .string("codex.rate_limits")]).data()) == nil)
  try turns.begin()
  #expect(
    try turns.observe(JSONValue.object(["type": .string("response.metadata")]).data()) == "")
  try created(turns)
  for event: JSONValue in [
    .object(["type": .string("response.output_text.delta"), "delta": .string("synthetic")]),
    .object([
      "type": .string("response.output_text.annotation.added"),
      "item_id": .string("synthetic-unannounced"),
    ]),
    .object([
      "type": .string("response.output_item.added"),
      "item": .object(["type": .string("web_search_call"), "id": .string("ws_synthetic")]),
    ]),
  ] {
    #expect(try turns.observe(event.data()) == "")
  }
  let foreign = try turnFailure(
    turns,
    .object([
      "type": .string("response.completed"),
      "response": .object(["id": .string("synthetic-foreign")]),
    ]))
  #expect(foreign.detail == .upstreamTurnResponseID)
}

@Test func terminalWithoutCreatedStillClosesTheTurn() throws {
  let turns = WebSocketTurns()
  try turns.begin()
  #expect(
    try turns.observe(
      JSONValue.object([
        "type": .string("response.failed"),
        "response": .object(["id": .string("synthetic-response"), "status": .string("failed")]),
      ]).data()) == "")
  try turns.begin()
}
