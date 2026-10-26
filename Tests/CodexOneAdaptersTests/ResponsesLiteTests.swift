import Foundation
import Testing

@testable import CodexOneAdapters

private let liteFunction: JSONValue = .object([
  "type": .string("function"), "name": .string("synthetic_echo"),
  "parameters": .object(["type": .string("object")]),
])
private func litePackage(_ tools: [JSONValue]) -> JSONValue {
  .object([
    "type": .string("additional_tools"), "role": .string("developer"),
    "id": .string("at_client_local"), "tools": .array(tools),
  ])
}
private func liteRequest(_ items: [JSONValue], extra: [String: JSONValue] = [:]) throws
  -> ResponseRequest
{
  var value: [String: JSONValue] = ["model": .string("synthetic"), "input": .array(items)]
  value.merge(extra) { _, new in new }
  return try ResponseRequest(data: JSONValue.object(value).data())
}

@Test func liteDeclarationsPreservePositionAndDoNotCreateObjectOwnership() throws {
  let message: JSONValue = .object(["role": .string("developer"), "content": .string("synthetic")])
  let package = litePackage([
    .object([
      "type": .string("namespace"), "name": .string("synthetic_ns"),
      "tools": .array([liteFunction]),
    ])
  ])
  let request = try liteRequest([message, package, message])
  #expect(request.usesResponsesLite)
  #expect(request.references.isEmpty && request.affinityHints.isEmpty)
  #expect(request.document["tools"] == nil)
  var expected = package.object!
  expected.removeValue(forKey: "id")
  #expect(request.document["input"] == .array([message, .object(expected), message]))
  let explicit = try liteRequest([package], extra: ["tools": .array([])])
  #expect(explicit.document["tools"] == .array([]))
}

@Test func liteDeclarationsForwardProviderToolsButNeverImageGeneration() throws {
  // Large descriptions, built-in tools and future members are the provider's contract.
  var described = liteFunction.object!
  described["description"] = .string(String(repeating: "é", count: 262_144))
  described["synthetic_future_member"] = .bool(true)
  let tools: [JSONValue] = [
    .object(described), .object(["type": .string("web_search")]),
    .object(["type": .string("tool_search")]), liteFunction, liteFunction,
  ]
  let request = try liteRequest([litePackage(tools)], extra: ["tools": .array([liteFunction])])
  #expect(request.document["input"]?.array?.first?["tools"] == .array(tools))
  for package in [
    litePackage([.object(["type": .string("image_generation")])]),
    litePackage([
      .object([
        "type": .string("namespace"), "name": .string("synthetic_ns"),
        "tools": .array([.object(["type": .string("image_generation")])]),
      ])
    ]),
  ] {
    do {
      _ = try liteRequest([package])
      Issue.record("Image generation escaped its permissioned declaration")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "unsupported_tools" && error.detail == .toolsImage)
    }
  }
}

@Test func providerCallsForUndeclaredToolsAreForwardedToTheClient() throws {
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)
  let call: JSONValue = .object([
    "type": .string("function_call"), "name": .string("synthetic_echo"),
    "call_id": .string("call_synthetic"), "id": .string("fc_synthetic"), "arguments": .string("{}"),
  ])
  let observation = try ProviderObservation(
    event: .object(["type": .string("response.output_item.done"), "item": call]), model: model)
  #expect(
    observation.bindings == [
      .init(type: "item", rawID: "fc_synthetic"),
      .init(type: "function_call", rawID: "call_synthetic"),
    ])
}

@Test func liteCompactKeepsDeclarationsButNotClientLocalPackageIDs() throws {
  let request = try ResponseRequest(
    data: JSONValue.object([
      "model": .string("synthetic"), "input": .array([litePackage([liteFunction])]),
    ]).data(), mode: .compact)
  #expect(request.usesResponsesLite && request.references.isEmpty)
  #expect(request.document["input"]?.array?.first?["id"] == nil)
}

@Test func webSocketLiteModeInheritsOnlyFromTheLastSuccessfulSameModelResponse() throws {
  let state = WebSocketToolState()
  let first = try liteRequest([litePackage([liteFunction])])
  func terminal(_ type: String, _ status: String, _ id: String) -> JSONValue {
    .object([
      "type": .string(type),
      "response": .object([
        "id": .string(id), "status": .string(status),
      ]),
    ])
  }
  state.observe(terminal("response.created", "in_progress", "resp_ignore"), request: first)
  state.observe(terminal("response.failed", "failed", "resp_ignore"), request: first)
  #expect(state.snapshot == nil)
  state.observe(terminal("response.completed", "completed", "resp_warmup"), request: first)
  func next(_ changes: [String: JSONValue] = [:], snapshot: ClientToolSnapshot? = nil) throws
    -> ResponseRequest
  {
    var fields: [String: JSONValue] = [
      "type": .string("response.create"),
      "model": .string("synthetic"), "input": .array([]),
      "previous_response_id": .string("resp_warmup"),
    ]
    fields.merge(changes) { _, new in new }
    return try webSocketCreate(JSONValue.object(fields).data(), previousTools: snapshot)
  }
  let continued = try next(snapshot: state.snapshot)
  #expect(continued.usesResponsesLite)
  #expect(continued.document["tools"] == nil && continued.document["input"] == .array([]))
  for changes: [String: JSONValue] in [
    ["model": .string("different")], ["previous_response_id": .string("resp_other")],
    ["previous_response_id": .null], ["tools": .array([])],
  ] {
    #expect(try !next(changes, snapshot: state.snapshot).usesResponsesLite)
  }
  #expect(try !next(snapshot: WebSocketToolState().snapshot).usesResponsesLite)
}
