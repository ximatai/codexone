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

@Test func optionalReasoningNullDoesNotRelaxUnknownMembersTypesOrCompact() {
  for reasoning in [
    #"{"effort":false}"#, #"{"effort":[]}"#, #"{"summary":false}"#,
    #"{"summary":[]}"#, #"{"summary":"invented"}"#, #"{"summary":null,"private":null}"#,
    #"[]"#, #""synthetic""#,
  ] {
    #expect(throws: (any Error).self) {
      try ResponseRequest(
        data: Data("{\"model\":\"synthetic\",\"input\":\"text\",\"reasoning\":\(reasoning)}".utf8))
    }
  }
  #expect(throws: (any Error).self) {
    try ResponseRequest(
      data: Data(#"{"model":"synthetic","input":"text","reasoning":{"effort":null}}"#.utf8),
      mode: .compact)
  }
}

@Test func knownOptionalControlsNormalizeWithoutRelaxingRequiredFields() throws {
  let request = try ResponseRequest(
    data: Data(
      #"{"model":"synthetic","input":"text","text":{"verbosity":null,"format":null},"tool_choice":null,"parallel_tool_calls":null}"#
        .utf8))
  #expect(request.document["text"] == .object([:]))
  #expect(request.document["tool_choice"] == nil)
  #expect(request.document["parallel_tool_calls"] == nil)
  for extra in [
    #""text":{"verbosity":false}"#, #""text":{"format":false}"#, #""tool_choice":false"#,
    #""parallel_tool_calls":"false"#, #""tools":null"#, #""store":null"#, #""stream":null"#,
  ] {
    #expect(throws: (any Error).self) {
      try ResponseRequest(data: Data((#"{"model":"synthetic","input":"text","# + extra + "}").utf8))
    }
  }
}

@Test func reasoningRejectionsCarryOnlyFixedDiagnosticReasons() {
  for (reasoning, detail) in [
    (#"[]"#, ProtocolRejectionDetail.reasoningObject),
    (#"{"private":null}"#, .reasoningMembers),
    (#"{"effort":false}"#, .reasoningEffort),
    (#"{"summary":false}"#, .reasoningSummaryType),
    (#"{"summary":"synthetic-private-value"}"#, .reasoningSummaryValue),
  ] {
    do {
      _ = try ResponseRequest(
        data: Data((#"{"model":"synthetic","input":"text","reasoning":"# + reasoning + "}").utf8))
      Issue.record("Expected rejection")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "unsupported_reasoning")
      #expect(error.detail == detail)
    } catch { Issue.record("Unexpected error") }
  }
}
