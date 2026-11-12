import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private let evolutionModel = SingleIdentityConfiguration.Model(
  id: "synthetic", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)

@Test func unknownEventsPreserveContentWithoutGrantingKnownSemantics() throws {
  for type in ["response.synthetic_extension", "synthetic.started", "response.future.completed"] {
    let event = try JSONValue.decode(
      Data(
        """
        {"type":"\(type)","item_id":"synthetic-unowned","item":{"id":"synthetic-unowned",
        "call_id":"synthetic-call","type":"image_generation_call","status":"completed","result":false},
        "usage":{"future":{"count":9007199254740993,"nullable":null}},"future":[true,"合成"]}
        """.utf8))
    let observation = try ProviderObservation(
      event: event, model: evolutionModel, allowImages: true)
    #expect(observation.bindings.isEmpty)
    #expect(observation.usage == nil && !observation.terminal)
    #expect(ProviderObservation.clientOutput(event) == event)
    #expect(try JSONValue.decode(event.data()) == event)
  }
}

@Test func usageExtensionsSurviveKnownCounterRepairWithoutChangingEvidence() throws {
  let original = try JSONValue.decode(
    Data(
      #"{"usage":{"input_tokens":5,"output_tokens":3,"future":{"large":9007199254740993,"nullable":null},"input_tokens_details":{"cached_tokens":0,"future":1,"cache_write_tokens_details":{"future":2,"ttl_30m_tokens":-1}},"output_tokens_details":{"future":3,"reasoning_tokens":"bad"}}}"#
        .utf8))
  let repaired = ProviderObservation.clientOutput(original)
  #expect(repaired["usage"]?["future"] == original["usage"]?["future"])
  #expect(repaired["usage"]?["input_tokens_details"]?["future"] == .number(1))
  #expect(
    repaired["usage"]?["input_tokens_details"]?["cache_write_tokens_details"]
      == .object(["future": .number(2)]))
  #expect(repaired["usage"]?["output_tokens_details"] == .object(["future": .number(3)]))
  #expect(
    ProviderObservation.usage(original["usage"], model: evolutionModel)
      == ProviderObservation.usage(repaired["usage"], model: evolutionModel))
}

@Test func unknownApplicationEventsBlockSizeFallbackEvenBeforeKnownStart() throws {
  for started in [false, true] {
    for type in ["response.future.started", "synthetic.started"] {
      for id in [nil, "synthetic-current", "synthetic-unresolved"] as [String?] {
        let turns = WebSocketTurns()
        try turns.begin()
        turns.markDispatched(lane: "")
        if started {
          _ = try turns.observe(
            JSONValue.object([
              "type": .string("response.created"),
              "response": .object(["id": .string("synthetic-current")]),
            ]).data())
        }
        var event: JSONObject = ["type": .string(type)]
        if let id { event["response_id"] = .string(id) }
        // A foreign identity after start is still rejected, rather than forwarded into this turn.
        if started, id == "synthetic-unresolved" {
          #expect(throws: GatewayProtocolError.self) {
            try turns.observe(JSONValue.object(event).data())
          }
        } else {
          _ = try turns.observe(JSONValue.object(event).data())
        }
        #expect(!turns.mayAcceptSizeRefusal(lane: ""))
      }
    }
  }
}

@Test func staleEventsDoNotContaminateSizeRefusalForNextTurn() throws {
  let turns = WebSocketTurns()
  try turns.begin()
  for type in ["response.created", "response.completed"] {
    _ = try turns.observe(
      JSONValue.object([
        "type": .string(type), "response": .object(["id": .string("synthetic-old")]),
      ]).data())
  }
  try turns.begin()
  turns.markDispatched(lane: "")
  let stale: JSONValue = .object([
    "type": .string("synthetic.future"), "response_id": .string("synthetic-old"),
  ])
  #expect(try turns.delivery(stale.data())?.detached == true)
  #expect(turns.mayAcceptSizeRefusal(lane: ""))
  // A known metadata name cannot disguise unresolved application identity.
  _ = try turns.observe(
    JSONValue.object([
      "type": .string("response.metadata"), "response_id": .string("synthetic-unresolved"),
    ]).data())
  #expect(!turns.mayAcceptSizeRefusal(lane: ""))
}

@Test func opaqueImageOutputDoesNotUseReferenceInputCodec() throws {
  let outputs = [
    Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8),
    Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!,
    Data("synthetic-future-output-container".utf8),
  ]
  for bytes in outputs {
    let item: JSONValue = .object([
      "type": .string("image_generation_call"), "status": .string("completed"),
      "result": .string(bytes.base64EncodedString()),
    ])
    #expect(try imageResult(item) == bytes.base64EncodedString())
    #expect(throws: GatewayProtocolError.self) {
      try ImagePayload(bytes: bytes, maximumBytes: ImageLimits.imageBytes)
    }
  }
  for result in ["", "invalid", "Zh=="] {
    #expect(throws: GatewayProtocolError.self) {
      try imageResult(.object(["result": .string(result)]))
    }
  }
}

@Test func unknownEventsCannotExtendFirstOrIdleDeadline() async throws {
  for started in [false, true] {
    do {
      let _: Bool = try await withProgressDeadline(
        budget: ExecutionBudget(total: 4, first: 1, idle: 1)
      ) { progress in
        progress.requestSent()
        if started { progress.note(event: .object(["type": .string("response.created")])) }
        for _ in 0..<12 {
          progress.note(
            event: .object([
              "type": .string("response.future.delta"), "delta": .string("synthetic"),
            ]))
          try await Task.sleep(for: .milliseconds(150))
        }
        return true
      }
      Issue.record("Unknown events extended the response deadline")
    } catch let error as GatewayProtocolError {
      #expect(
        error.code == (started ? "execution_progress_timeout" : "execution_first_response_timeout"))
    }
  }
}

@Test func cleanSizeRefusalEvidenceSurvivesTransportClose() throws {
  let turns = WebSocketTurns()
  try turns.begin()
  turns.markDispatched(lane: "")
  _ = try turns.observe(JSONValue.object(["type": .string("rate_limits.updated")]).data())
  turns.close()
  #expect(turns.mayAcceptSizeRefusal(lane: ""))
}

@Test func partialImageCountersRetainAllObservedSubtotals() throws {
  let configuration = try syntheticImageConfiguration()
  let request = try ResponseRequest(
    data: Data(
      #"{"model":"synthetic","input":"synthetic","tools":[{"type":"image_generation"}]}"#.utf8),
    imageConfiguration: configuration)
  let valid: JSONValue = .object([
    "type": .string("image_generation_call"), "status": .string("completed"),
    "result": .string("c3ludGhldGlj"),
    "usage": .object(["input_tokens": .number(2), "output_tokens": .number(3)]),
  ])
  let invalid: JSONValue = .object([
    "type": .string("image_generation_call"), "status": .string("completed"),
    "result": .string("c3ludGhldGlj"),
    "usage": .object(["input_tokens": .number(4), "output_tokens": .number(-1)]),
  ])
  for (items, input) in [
    ([valid, invalid], Int64(6)),
    ([valid, .object(["type": .string("synthetic-future")])], Int64(2)),
  ] {
    let response: JSONValue = .object([
      "status": .string("completed"), "output": .array(items),
      "usage": .object([
        "input_tokens": .number(5), "output_tokens": .number(7),
        "input_tokens_details": .object(["cached_tokens": .number(0)]),
      ]),
    ])
    let usage = try #require(
      try request.usage(response, model: evolutionModel, configuration: configuration))
    #expect(usage.imageInputTokens == input && usage.imageOutputTokens == 3)
    #expect(usage.completeness == .partial)
  }
}

@Test(arguments: [false, true])
func unattributedApplicationRiskCoversDispatchedNamedLanesWithoutDelivery(idleDefault: Bool) throws
{
  let turns = WebSocketTurns()
  if idleDefault {
    try turns.begin()
    for type in ["response.created", "response.completed"] {
      _ = try turns.observe(
        JSONValue.object([
          "type": .string(type), "response": .object(["id": .string("synthetic-old")]),
        ]).data())
    }
  }
  for lane in ["first", "second"] {
    try turns.begin(lane: lane)
    turns.markDispatched(lane: lane)
  }
  try turns.begin(lane: "unsent")
  let event: JSONValue = .object(["type": .string("synthetic.future.started")])
  #expect(try turns.delivery(event.data()) == nil)
  for lane in ["first", "second"] { #expect(!turns.mayAcceptSizeRefusal(lane: lane)) }
}

@Test func knownMetadataAliasesRemainInertWithoutApplicationIdentity() throws {
  for type in [
    "response.metadata", "codex.response.metadata", "rate_limits.updated", "codex.rate_limits",
  ] {
    let turns = WebSocketTurns()
    try turns.begin()
    turns.markDispatched(lane: "")
    _ = try turns.observe(JSONValue.object(["type": .string(type)]).data())
    #expect(turns.mayAcceptSizeRefusal(lane: ""))
  }
}

@Test func recognizedAuxiliaryEventsGrantNoResponseFactsOrReplayException() throws {
  for type in [
    "response.metadata", "codex.response.metadata", "responsesapi.websocket_timing",
    "response.output_item.interrupted",
  ] {
    let registry = ClientProtocolExtensionRegistry()
    let event = JSONValue.object([
      "type": .string(type), "response_id": .string("synthetic-response"),
      "usage": .object(["input_tokens": .number(5), "output_tokens": .number(3)]),
    ])
    let semantics = ProviderEventSemantics(event)
    #expect(semantics.recognizedType)
    #expect(!semantics.known && !semantics.connectionMetadata)
    #expect(semantics.progress == .none)
    let observation = try ProviderObservation(
      event: event, model: evolutionModel, allowImages: true)
    #expect(observation.bindings.isEmpty && observation.usage == nil && !observation.terminal)
    registry.recordUpstreamEvent(event)

    let turns = WebSocketTurns()
    for lane in ["first", "second"] {
      try turns.begin(lane: lane)
      turns.markDispatched(lane: lane)
    }
    #expect(try turns.delivery(event.data()) == nil)
    turns.close()
    for lane in ["first", "second"] { #expect(!turns.mayAcceptSizeRefusal(lane: lane)) }
    #expect(registry.snapshot().entries.isEmpty)
  }
}

@Test func timingWithoutResponseIdentityStillClosesEveryDispatchedLanesReplayGate() throws {
  let event: JSONValue = .object(["type": .string("responsesapi.websocket_timing")])
  let semantics = ProviderEventSemantics(event)
  #expect(semantics.recognizedType && !semantics.known && !semantics.connectionMetadata)
  #expect(semantics.progress == .none)
  let turns = WebSocketTurns()
  for lane in ["first", "second"] {
    try turns.begin(lane: lane)
    turns.markDispatched(lane: lane)
  }
  _ = try turns.delivery(event.data())
  turns.close()
  for lane in ["first", "second"] { #expect(!turns.mayAcceptSizeRefusal(lane: lane)) }
}

@Test func upstreamExtensionObservationsRetainOnlyBoundedNames() {
  let registry = ClientProtocolExtensionRegistry()
  registry.recordUpstreamEvent(.object(["type": .string("response.created")]))
  #expect(registry.snapshot().entries.isEmpty)
  for index in 0..<40 {
    registry.recordUpstreamEvent(
      .object([
        "type": .string("synthetic.future.\(index)"),
        "secret": .string("synthetic-value-never-stored"),
      ]))
  }
  let snapshot = registry.snapshot()
  #expect(snapshot.entries.count == 32 && snapshot.overflow)
  #expect(snapshot.entries.allSatisfy { $0.name.hasPrefix("upstream_event.synthetic.future.") })
}

@Test func connectionSizeRefusalCannotClearSeveralDispatchedTurns() throws {
  let turns = WebSocketTurns()
  for lane in ["first", "second"] {
    try turns.begin(lane: lane)
    turns.markDispatched(lane: lane)
  }
  turns.close()
  for lane in ["first", "second"] { #expect(!turns.mayAcceptSizeRefusal(lane: lane)) }
}

@Test func anUnsentLaneCannotAbsorbAnotherTurnsProcessingRisk() throws {
  let turns = WebSocketTurns()
  try turns.begin(lane: "sent")
  turns.markDispatched(lane: "sent")
  try turns.begin(lane: "unsent")
  _ = try turns.observe(
    JSONValue.object([
      "type": .string("synthetic.future.started"), "stream_id": .string("unsent"),
    ]).data())
  turns.close()
  #expect(!turns.mayAcceptSizeRefusal(lane: "sent"))
}

@Test func completeImageUsageKeepsItsPriceAndCompletenessAcrossFoundationPlatforms() throws {
  let configuration = try syntheticImageConfiguration()
  let request = try ResponseRequest(
    data: Data(
      #"{"model":"synthetic","input":"synthetic","tools":[{"type":"image_generation"}]}"#.utf8),
    imageConfiguration: configuration)
  let response: JSONValue = .object([
    "status": .string("completed"),
    "output": .array([
      .object([
        "type": .string("image_generation_call"), "status": .string("completed"),
        "result": .string("c3ludGhldGlj"),
        "usage": .object(["input_tokens": .number(2), "output_tokens": .number(3)]),
      ])
    ]),
    "usage": .object([
      "input_tokens": .number(5), "output_tokens": .number(7),
      "input_tokens_details": .object(["cached_tokens": .number(0)]),
    ]),
  ])
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 1_000_000, outputMicrosPerMillion: 1_000_000)
  let usage = try #require(try request.usage(response, model: model, configuration: configuration))
  #expect(usage.completeness == .complete)
  #expect(usage.estimatedMicros == 25)
}
