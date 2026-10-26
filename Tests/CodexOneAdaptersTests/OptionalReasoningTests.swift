import Foundation
import Testing

@testable import CodexOneAdapters

@Test func optionalReasoningNullNormalizesWithoutSynthesizingTools() throws {
  for (reasoning, expected) in [
    (#"{"effort":null,"summary":null}"#, #"{}"#),
    (#"{"effort":"high","summary":null}"#, #"{"effort":"high"}"#),
    (#"{"effort":null,"summary":"auto"}"#, #"{"summary":"auto"}"#),
    (#"{"effort":"ultra","summary":"none"}"#, #"{"effort":"ultra","summary":"none"}"#),
  ] {
    for tools in ["", #", "tools":[]"#] {
      let request = try ResponseRequest(
        data: Data(
          "{\"model\":\"synthetic\",\"input\":\"text\",\"reasoning\":\(reasoning)\(tools)}".utf8))
      #expect(request.document["reasoning"] == (try JSONValue.decode(Data(expected.utf8))))
      #expect(request.document["tools"] == (tools.isEmpty ? nil : .array([])))
    }
  }
}

@Test func knownOptionalControlsNormalizeAndNonBooleanModesStillFail() throws {
  let request = try ResponseRequest(
    data: Data(
      #"{"model":"synthetic","input":"text","text":{"verbosity":null,"format":null},"tool_choice":null,"parallel_tool_calls":null}"#
        .utf8))
  #expect(request.document["text"] == .object([:]))
  #expect(request.document["tool_choice"] == nil)
  #expect(request.document["parallel_tool_calls"] == nil)
  for extra in [#""store":"false""#, #""stream":1"#, #""background":"true""#] {
    #expect(throws: (any Error).self) {
      try ResponseRequest(data: Data((#"{"model":"synthetic","input":"text","# + extra + "}").utf8))
    }
  }
}

@Test func codexReasoningContextAndSummaryDeliveryPreserveKnownWireControls() throws {
  for context in ["auto", "current_turn", "all_turns"] {
    let request = try ResponseRequest(
      data: Data(
        (#"{"model":"synthetic","input":"text","reasoning":{"context":""# + context
          + #""},"stream_options":{"reasoning_summary_delivery":"sequential_cutoff","include_usage":false}}"#)
          .utf8))
    #expect(request.document["reasoning"]?["context"]?.string == context)
    #expect(
      request.document["stream_options"]?["reasoning_summary_delivery"]?.string
        == "sequential_cutoff")
    #expect(request.document["stream_options"]?["include_usage"]?.bool == false)
  }
  let request = try ResponseRequest(
    data: Data(
      #"{"model":"synthetic","input":"text","reasoning":{"context":null},"stream_options":{"reasoning_summary_delivery":"sequential_cutoff"}}"#
        .utf8))
  #expect(request.document["reasoning"] == .object([:]))
}

@Test func futureControlsAndMembersAreForwardedForTheProviderToJudge() throws {
  for extra in [
    #""reasoning":{"context":"future_mode","effort":"xhigh","private":null}"#,
    #""stream_options":{"future_delivery":"synthetic"}"#,
    #""text":{"verbosity":"max","future":true}"#, #""tool_choice":{"type":"web_search"}"#,
    #""include":["reasoning.encrypted_content","web_search_call.action.sources"]"#,
    #""service_tier":"flex","user":"synthetic","safety_identifier":"synthetic""#,
  ] {
    let raw = #"{"model":"synthetic","input":"text","# + extra + "}"
    let request = try ResponseRequest(data: Data(raw.utf8))
    let original = try JSONValue.decode(Data(raw.utf8))
    for key in original.object!.keys where key != "reasoning" {
      #expect(request.document[key] == original[key])
    }
  }
}
