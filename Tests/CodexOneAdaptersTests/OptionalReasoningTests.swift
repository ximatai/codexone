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
