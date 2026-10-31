import Foundation
import NIOHTTP1
import Testing

@testable import CodexOneAdapters

@Test func clientPrefixHeadersAreBoundedAndHopByHopExcluded() {
  var headers = HTTPHeaders()
  headers.add(name: "x-codex-large", value: String(repeating: "a", count: 8193))
  headers.add(name: "connection", value: "x-codex-hop")
  headers.add(name: "x-codex-hop", value: "synthetic")
  for index in 0..<40 { headers.add(name: "x-codex-extension-\(index)", value: "synthetic") }
  let result = forwardedClientHeaders(headers)
  #expect(result.filter { $0.name.hasPrefix("x-codex-") }.count == 32)
  #expect(result["x-codex-large"].isEmpty && result["x-codex-hop"].isEmpty)
  #expect(result.first(name: "x-codex-extension-31") == "synthetic")
  #expect(result["x-codex-extension-32"].isEmpty)
}

@Test func protocolExtensionMetadataContainsOnlyIdentifiers() {
  let headers: HTTPHeaders = ["version": "synthetic.1", "user-agent": "Codex Desktop synthetic"]
  let metadata = ClientProtocolDiagnostics.metadata(
    name: "response.synthetic", outcome: "forwarded", headers: headers)
  #expect(metadata["protocol_name"]?.description == "response.synthetic")
  #expect(metadata["client_version"]?.description == "synthetic.1")
  #expect(metadata["client_category"]?.description == "codex")
  let unsafe = ClientProtocolDiagnostics.metadata(
    name: "private body\nsecret", outcome: "rejected", headers: ["version": "private body"])
  #expect(!unsafe.description.contains("private") && !unsafe.description.contains("secret"))
}

@Test func lateInterruptAcknowledgementsKeepTheirLaneAndBypassEvidence() throws {
  let turns = WebSocketTurns()
  try turns.begin(lane: "synthetic_lane")
  func event(_ type: String, response: Bool = false) throws -> Data {
    try JSONValue.object([
      "type": .string(type),
      response ? "response" : "response_id": response
        ? .object(["id": .string("synthetic_response")]) : .string("synthetic_response"),
      "stream_id": .string("synthetic_lane"),
    ]).data()
  }
  #expect(try turns.observe(event("response.created", response: true)) == "synthetic_lane")
  #expect(turns.interruptLane(responseID: "synthetic_response") == "synthetic_lane")
  turns.markInterrupted(responseID: "synthetic_response", lane: "synthetic_lane")
  #expect(turns.wasInterrupted(lane: "synthetic_lane"))
  #expect(try turns.delivery(event("response.interrupt.accepted"))?.detached == true)
  _ = try turns.observe(event("response.completed", response: true))
  #expect(turns.interruptLane(responseID: "synthetic_response") == nil)
  try turns.begin(lane: "synthetic_lane")
  turns.markInterrupted(responseID: "synthetic_response", lane: "synthetic_lane")
  #expect(!turns.wasInterrupted(lane: "synthetic_lane"))
  let late = try turns.delivery(event("response.interrupt.accepted"))
  #expect(late?.lane == "synthetic_lane" && late?.detached == true)
}

@Test(arguments: ["response.created", "response.queued", "response.in_progress"])
func interruptionRequiresCreatedAndUnexpectedLifecycleStopsDispatch(_ unexpectedType: String) throws
{
  let turns = WebSocketTurns()
  try turns.begin()
  _ = try turns.observe(
    JSONValue.object([
      "type": .string("response.in_progress"),
      "response": .object(["id": .string("synthetic_response")]),
    ]).data())
  #expect(turns.interruptLane(responseID: "synthetic_response") == nil)
  _ = try turns.observe(
    JSONValue.object([
      "type": .string("response.created"),
      "response": .object(["id": .string("synthetic_response")]),
    ]).data())
  #expect(turns.interruptLane(responseID: "synthetic_response") == "")
  #expect(throws: UnadmittedWebSocketResponse.self) {
    try turns.observe(
      JSONValue.object([
        "type": .string(unexpectedType),
        "response": .object(["id": .string("synthetic_unadmitted")]),
      ]).data())
  }
  #expect(turns.isClosed)
  #expect(throws: WebSocketUpstreamClosed.self) { try turns.begin(lane: "new_lane") }
}

@Test func activeInterruptRoutingSurvivesRecentHistoryEviction() throws {
  let turns = WebSocketTurns()
  func observe(_ type: String, id: String, lane: String) throws {
    _ = try turns.observe(
      JSONValue.object([
        "type": .string(type), "stream_id": .string(lane),
        "response": .object(["id": .string(id)]),
      ]).data())
  }
  try turns.begin(lane: "long")
  try observe("response.created", id: "synthetic_long", lane: "long")
  for index in 0..<1024 {
    try turns.begin(lane: "short")
    try observe("response.created", id: "synthetic_\(index)", lane: "short")
    try observe("response.completed", id: "synthetic_\(index)", lane: "short")
  }
  let ack = try turns.delivery(
    JSONValue.object([
      "type": .string("response.interrupt.accepted"), "response_id": .string("synthetic_long"),
    ]).data())
  #expect(ack?.lane == "long" && ack?.detached == true)
  #expect(turns.interruptLane(responseID: "synthetic_long") == "long")
  try observe("response.completed", id: "synthetic_long", lane: "long")
  let late = try turns.delivery(
    JSONValue.object([
      "type": .string("response.interrupt.accepted"), "response_id": .string("synthetic_long"),
    ]).data())
  #expect(late?.lane == "long" && late?.detached == true)
}

@Test(.timeLimit(.minutes(1))) func cancellingOneLaneDoesNotCancelSiblingInbox() async throws {
  let inbox = WebSocketInbox()
  let cancelled = Task { try await inbox.next(lane: "cancelled") }
  let sibling = Task { try await inbox.next(lane: "sibling") }
  cancelled.cancel()
  do {
    _ = try await cancelled.value
    Issue.record("Cancelled lane continued")
  } catch is CancellationError {}
  let data = Data("synthetic".utf8)
  try await inbox.push(data, lane: "sibling")
  #expect(try await sibling.value == data)
}

@Test(.timeLimit(.minutes(1))) func closingPeerWakesAllRemainingWaitersAfterOneCancels()
  async throws
{
  let turns = WebSocketTurns()
  let cancelled = Task { await turns.waitForClose() }
  let first = Task { await turns.waitForClose() }
  let second = Task { await turns.waitForClose() }
  cancelled.cancel()
  await cancelled.value
  #expect(!turns.isClosed)
  turns.close()
  await first.value
  await second.value
  #expect(turns.isClosed)
}

@Test func disconnectSettlementUsesOnlyTheCurrentDispatchedTurn() throws {
  let turns = WebSocketTurns()
  func observe(_ type: String) throws {
    _ = try turns.observe(
      JSONValue.object([
        "type": .string(type), "response": .object(["id": .string("synthetic_response")]),
      ]).data())
  }
  func finished() -> Bool {
    if case .finished = turns.settlement(lane: "") { return true }
    return false
  }
  #expect(finished())
  try turns.begin()
  #expect(finished())  // Admission/preparation has not written a request.
  turns.markDispatched(lane: "")
  if case .awaitingIdentity = turns.settlement(lane: "") {
  } else {
    Issue.record("Dispatched turn did not wait for its identity")
  }
  try observe("response.created")
  if case .interrupt(let id) = turns.settlement(lane: "") {
    #expect(id == "synthetic_response")
  } else {
    Issue.record("Active turn lost its interrupt identity")
  }
  turns.markInterrupted(responseID: "synthetic_response", lane: "")
  if case .interrupted = turns.settlement(lane: "") {
  } else {
    Issue.record("Already forwarded interrupt was not retained")
  }
  try observe("response.completed")
  #expect(finished())
  try turns.begin()
  #expect(finished())  // Neither dispatch nor interrupt markers cross into the next turn.
}
