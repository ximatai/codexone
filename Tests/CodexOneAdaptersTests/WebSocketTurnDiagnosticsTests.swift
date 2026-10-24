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

@Test func preCreatedProviderRejectionsKeepPrivateFixedReasonsWithoutTrustingPayload() throws {
  for (error, detail): ([String: JSONValue], ProtocolRejectionDetail) in [
    (["param": .string("stream")], .upstreamTurnProviderStream),
    (["param": .string("reasoning.summary")], .upstreamTurnProviderReasoningSummary),
    (["code": .string("invalid_api_key")], .upstreamTurnProviderAuthentication),
    (["code": .string("rate_limit_exceeded")], .upstreamTurnProviderRateLimit),
    (
      ["param": .string("synthetic-secret"), "code": .string("synthetic-secret")],
      .upstreamTurnProviderError
    ),
  ] {
    for nested in [true, false] {
      let turns = WebSocketTurns()
      try turns.begin()
      var fields = error
      fields["message"] = .string("synthetic-private-provider-message")
      var event: [String: JSONValue] = nested ? ["error": .object(fields)] : fields
      event["type"] = .string("error")
      let failure = try turnFailure(turns, .object(event))
      #expect(failure.code == "invalid_upstream_turn" && failure.detail == detail)
      let metadata = ProtocolFailureDiagnostics.metadata(failure, requestID: UUID().uuidString)
      #expect(metadata["reason"]?.description == detail.rawValue)
      #expect(!metadata.description.contains("synthetic-private"))
      #expect(!metadata.description.contains("synthetic-secret"))
      #expect(
        protocolErrorEnvelope(failure, requestID: UUID().uuidString)["error"]?["reason"] == nil)
    }
  }
}

@Test func turnAssociationDiagnosticsDistinguishCreatedResponseAndItemFailures() throws {
  let waiting = WebSocketTurns()
  try waiting.begin()
  let early = try turnFailure(
    waiting,
    .object([
      "type": .string("response.completed"),
      "response": .object(["id": .string("synthetic-response")]),
    ]))
  #expect(early.detail == .upstreamTurnCreated)
  for (event, detail): (JSONValue, ProtocolRejectionDetail) in [
    (
      .object([
        "type": .string("response.completed"),
        "response": .object(["id": .string("synthetic-foreign")]),
      ]), .upstreamTurnResponseID
    ),
    (
      .object([
        "type": .string("response.output_item.added"), "item": .object(["id": .bool(false)]),
      ]), .upstreamTurnItemID
    ),
    (
      .object(["type": .string("response.output_text.delta"), "delta": .string("synthetic")]),
      .upstreamTurnMissingItemID
    ),
    (
      .object([
        "type": .string("response.output_text.delta"), "item_id": .string("synthetic-foreign"),
        "delta": .string("synthetic"),
      ]), .upstreamTurnUnknownItemID
    ),
  ] {
    let turns = WebSocketTurns()
    try turns.begin()
    _ = try turns.observe(
      JSONValue.object([
        "type": .string("response.created"),
        "response": .object(["id": .string("synthetic-response")]),
      ]).data())
    #expect(try turnFailure(turns, event).detail == detail)
  }
}
