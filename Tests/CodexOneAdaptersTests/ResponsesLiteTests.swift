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
  #expect(request.functionNames == ["synthetic_ns:synthetic_echo"])
  #expect(request.references.isEmpty)
  #expect(request.document["tools"] == nil)
  var expected = package.object!
  expected.removeValue(forKey: "id")
  #expect(request.document["input"] == .array([message, .object(expected), message]))
  let explicit = try liteRequest([package], extra: ["tools": .array([])])
  #expect(explicit.document["tools"] == .array([]))
}

@Test func liteDeclarationsRejectUnsupportedControlsAndPrivateReferences() throws {
  for change: [String: JSONValue] in [
    ["role": .string("user")], ["tools": .null], ["id": .bool(false)],
    ["status": .string("completed")], ["file_id": .string("synthetic-private")],
    ["tools": .array([.object(["type": .string("image_generation")])])],
    ["tools": .array([.object(["type": .string("web_search")])])],
    ["tools": .array([.object(["type": .string("tool_search")])])],
  ] {
    var package = litePackage([liteFunction]).object!
    package.merge(change) { _, new in new }
    #expect(throws: (any Error).self) { try liteRequest([.object(package)]) }
  }
  #expect(throws: (any Error).self) {
    try liteRequest([litePackage([liteFunction])], extra: ["tools": .null])
  }
}

@Test func liteDeclarationsShareCapacityAndRejectAmbiguousToolsAcrossAllSources() throws {
  let declarations = (0..<64).map { index -> JSONValue in
    var value = liteFunction.object!
    value["name"] = .string("synthetic_\(index)")
    return .object(value)
  }
  #expect(try liteRequest([litePackage(declarations)]).functionNames.count == 64)
  #expect(throws: (any Error).self) {
    try liteRequest([litePackage(declarations)], extra: ["tools": .array([liteFunction])])
  }
  #expect(throws: (any Error).self) {
    try liteRequest([litePackage([liteFunction]), litePackage([liteFunction])])
  }
  #expect(throws: (any Error).self) {
    try liteRequest([litePackage([liteFunction])], extra: ["tools": .array([liteFunction])])
  }
}

@Test func liteToolChoicesAndProviderCallsUseTheSameDeclaredIdentities() throws {
  let choice: JSONValue = .object(["type": .string("function"), "name": .string("synthetic_echo")])
  let request = try liteRequest([litePackage([liteFunction])], extra: ["tool_choice": choice])
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)
  let call: JSONValue = .object([
    "type": .string("function_call"), "name": .string("synthetic_echo"),
    "call_id": .string("call_synthetic"), "id": .string("fc_synthetic"), "arguments": .string("{}"),
  ])
  _ = try ProviderObservation(
    event: .object(["type": .string("response.output_item.done"), "item": call]), model: model,
    functionNames: request.functionNames)
  #expect(throws: (any Error).self) {
    try ProviderObservation(
      event: .object(["type": .string("response.output_item.done"), "item": call]), model: model,
      functionNames: [])
  }
  #expect(throws: (any Error).self) {
    try liteRequest([litePackage([])], extra: ["tool_choice": choice])
  }
}

@Test func liteCompactKeepsDeclarationsButNotClientLocalPackageIDs() throws {
  let request = try ResponseRequest(
    data: JSONValue.object([
      "model": .string("synthetic"), "input": .array([litePackage([liteFunction])]),
    ]).data(), mode: .compact)
  #expect(request.usesResponsesLite && request.references.isEmpty)
  #expect(request.document["input"]?.array?.first?["id"] == nil)
}

@Test func liteMetadataCapacityIsRejectedBeforeExecution() {
  let metadata = Dictionary(
    uniqueKeysWithValues: (0..<32).map { ("synthetic_\($0)", JSONValue.string("v")) })
  #expect(throws: (any Error).self) {
    try liteRequest([litePackage([liteFunction])], extra: ["client_metadata": .object(metadata)])
  }
}

@Test func clientToolDescriptionsHaveABoundedUTF8Capacity() throws {
  var tool = liteFunction.object!
  tool["description"] = .string(String(repeating: "é", count: 65_536))
  #expect(try liteRequest([litePackage([.object(tool)])]).functionNames.count == 1)
  #expect(try liteRequest([], extra: ["tools": .array([.object(tool)])]).functionNames.count == 1)
  // The description budget is separate from the complete text envelope, which still has overhead.
  tool["description"] = .string(String(repeating: "é", count: 262_144))
  #expect(try ClientTools(.array([.object(tool)])).functions.count == 1)
  tool["description"] = .string(String(repeating: "é", count: 262_144) + "x")
  #expect(throws: (any Error).self) { try ClientTools(.array([.object(tool)])) }
}

@Test func toolDescriptionBudgetIncludesNamespacesAndAllDeclarationSources() throws {
  var function = liteFunction.object!
  function["description"] = .string(String(repeating: "x", count: 262_144))
  let leaf: JSONValue = .object([
    "type": .string("custom"), "name": .string("synthetic_custom"),
    "description": .string(String(repeating: "é", count: 65_536)),
  ])
  var namespace: [String: JSONValue] = [
    "type": .string("namespace"), "name": .string("synthetic_ns"),
    "description": .string(String(repeating: "x", count: 131_072)),
    "tools": .array([leaf]),
  ]
  let boundary = try ClientTools(.array([.object(function), .object(namespace)]))
  #expect(boundary.functions == ["synthetic_echo"])
  #expect(boundary.custom == ["synthetic_ns:synthetic_custom"])
  namespace["description"] = .string(String(repeating: "x", count: 131_073))
  for (items, extra): ([JSONValue], [String: JSONValue]) in [
    ([litePackage([.object(namespace)])], ["tools": .array([.object(function)])]),
    ([litePackage([.object(function)]), litePackage([.object(namespace)])], [:]),
  ] {
    do {
      _ = try liteRequest(items, extra: extra)
      Issue.record("Description budget was reset at a declaration source or namespace")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "unsupported_tools" && error.detail == .toolsDescriptionSize)
    }
  }
}

@Test func webSocketToolsInheritOnlyTheLastSuccessfulSameModelResponse() throws {
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
      "tool_choice": .object(["type": .string("function"), "name": .string("synthetic_echo")]),
    ]
    fields.merge(changes) { _, new in new }
    return try webSocketCreate(JSONValue.object(fields).data(), previousTools: snapshot)
  }
  let continued = try next(snapshot: state.snapshot)
  #expect(continued.functionNames == first.functionNames && continued.usesResponsesLite)
  #expect(continued.document["tools"] == nil && continued.document["input"] == .array([]))
  for changes: [String: JSONValue] in [
    ["model": .string("different")], ["previous_response_id": .string("resp_other")],
    ["previous_response_id": .null], ["tools": .array([])],
    ["input": .array([litePackage([])])],
  ] {
    #expect(throws: (any Error).self) { try next(changes, snapshot: state.snapshot) }
  }
  #expect(throws: (any Error).self) { try next(snapshot: WebSocketToolState().snapshot) }
  state.observe(terminal("response.completed", "completed", "resp_next"), request: continued)
  #expect(throws: (any Error).self) { try next(snapshot: state.snapshot) }
}
