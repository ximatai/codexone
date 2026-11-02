import CodexOneCore
import Foundation
import NIOHTTP1
import Synchronization
import Testing

@testable import CodexOneAdapters

@Test func sessionLabelsAreKeyScopedBoundedAndExpire() throws {
  let time = Mutex(ContinuousClock.now)
  let affinity = SessionAffinity(now: { time.withLock { $0 } })
  let account = try AccountRouteIdentity(id: "a", namespace: "synthetic")
  affinity.observe(key: "one", headers: ["thread-id": "same"], account: account)
  #expect(affinity.preferred(key: "two", headers: ["thread-id": "same"]) == nil)
  #expect(affinity.preferred(key: "one", headers: ["session-id": "same"]) == nil)
  for index in 0..<1024 {
    time.withLock { $0 = $0.advanced(by: .seconds(1)) }
    affinity.observe(key: "one", headers: ["thread-id": "label-\(index)"], account: account)
  }
  #expect(affinity.preferred(key: "one", headers: ["thread-id": "same"]) == nil)
  #expect(affinity.preferred(key: "one", headers: ["thread-id": "label-1023"]) == account)
  time.withLock { $0 = $0.advanced(by: .seconds(3600)) }
  #expect(affinity.preferred(key: "one", headers: ["thread-id": "label-1023"]) == nil)
}

@Test func endpointHealthIsScopedBoundedAndExpires() throws {
  let time = Mutex(ContinuousClock.now)
  let health = ControlEndpointHealth(now: { time.withLock { $0 } })
  let account = try AccountRouteIdentity(id: "a", namespace: "synthetic")
  health.record(route: "search", account: account, seconds: 60)
  #expect(Set(health.cooldowns(route: "search").keys) == [account])
  #expect(health.cooldowns(route: "goal").isEmpty)
  for index in 0..<1024 {
    health.record(
      route: "search", account: try .init(id: "a-\(index)", namespace: "synthetic"), seconds: 60)
  }
  #expect(health.cooldowns(route: "search").count == 1024)
  time.withLock { $0 = $0.advanced(by: .seconds(60)) }
  #expect(health.cooldowns(route: "search").isEmpty)
}

@Test func routingResponseMetadataRespectsHopByHopAndSize() {
  #expect(
    forwardedResponseHeaders(["x-codex-turn-state": "synthetic"])["x-codex-turn-state"] == [
      "synthetic"
    ])
  #expect(
    forwardedResponseHeaders([
      "x-codex-turn-state": "synthetic", "connection": "X-Codex-Turn-State",
    ]).isEmpty)
  #expect(
    forwardedResponseHeaders(["x-codex-turn-state": String(repeating: "x", count: 8193)]).isEmpty)
  #expect(
    forwardedResponseHeaders(["set-cookie": "synthetic-private", "authorization": "synthetic"])
      .isEmpty)
}

@Test func turnStateSourceIsImmutableScopedExpiringAndBounded() throws {
  let clock = Mutex(ContinuousClock.now)
  let owners = TurnStateOwners(now: { clock.withLock { $0 } })
  let a = try AccountRouteIdentity(id: "a", namespace: "synthetic/a")
  let b = try AccountRouteIdentity(id: "b", namespace: "synthetic/b")
  owners.observe(key: "one", token: "state", account: a)
  #expect(try owners.owner(key: "one", token: "state") == a)
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "two", token: "state") }
  owners.observe(key: "one", token: "state", account: b)
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "one", token: "state") }
  clock.withLock { $0 = $0.advanced(by: .seconds(3600)) }
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "one", token: "state") }
  owners.observe(key: "one", token: "first", account: a)
  for index in 0..<1024 {
    clock.withLock { $0 = $0.advanced(by: .milliseconds(1)) }
    owners.observe(key: "one", token: "state-\(index)", account: a)
  }
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "one", token: "first") }
  #expect(try owners.owner(key: "one", token: "state-1023") == a)
}

@Test func processSeedDoesNotMoveWhenSiblingThreadFallsBack() throws {
  let affinity = SessionAffinity()
  let a = try AccountRouteIdentity(id: "a", namespace: "synthetic/a")
  let b = try AccountRouteIdentity(id: "b", namespace: "synthetic/b")
  affinity.observe(key: "key", headers: ["session-id": "root", "thread-id": "one"], account: a)
  affinity.observe(key: "key", headers: ["session-id": "root", "thread-id": "two"], account: b)
  #expect(affinity.preferred(key: "key", headers: ["session-id": "root"]) == a)
  #expect(affinity.preferred(key: "key", headers: ["session-id": "root", "thread-id": "two"]) == b)
}

@Test func turnStateCarriersRejectAmbiguityWithoutRewritingInput() throws {
  #expect(
    executionFailure(GatewayProtocolError(503, "continuation_owner_unavailable"))
      == .accountUnavailable)
  #expect(executionFailure(GatewayProtocolError(400, "conflicting_turn_state")) == .invalidRequest)
  let message = JSONValue.object([
    "client_metadata": .object(["x-codex-turn-state": .string("state")])
  ])
  #expect(try requestTurnState(headers: [:], document: message) == "state")
  #expect(throws: GatewayProtocolError.self) {
    try requestTurnState(headers: ["x-codex-turn-state": "other"], document: message)
  }
  #expect(throws: GatewayProtocolError.self) {
    try requestTurnState(
      headers: HTTPHeaders([("x-codex-turn-state", "a"), ("x-codex-turn-state", "b")]))
  }
  #expect(throws: GatewayProtocolError.self) {
    try requestTurnState(
      headers: [:],
      document: .object(["client_metadata": .object(["x-codex-turn-state": .bool(true)])]))
  }
}

@Test func clientTurnStateIsValidatedBeforeFilteringAndReservesHeaderCapacity() throws {
  var headers = HTTPHeaders()
  for index in 0..<40 { headers.add(name: "x-codex-extension-\(index)", value: "synthetic") }
  headers.add(name: "x-codex-turn-state", value: "synthetic-state")
  let forwarded = try forwardedClientHeaders(headers)
  #expect(try requestTurnState(headers: forwarded) == "synthetic-state")
  #expect(forwarded.filter { $0.name.hasPrefix("x-codex-") }.count == 32)
  #expect(forwarded["x-codex-extension-31"].isEmpty)

  let oversized = String(repeating: "x", count: 8193)
  for invalid in [
    HTTPHeaders([("x-codex-turn-state", oversized)]),
    HTTPHeaders([("x-codex-turn-state", "synthetic"), ("x-codex-turn-state", oversized)]),
    HTTPHeaders([("x-codex-turn-state", "synthetic"), ("connection", "X-Codex-Turn-State")]),
  ] {
    #expect(throws: GatewayProtocolError.self) { try forwardedClientHeaders(invalid) }
  }
}

@Test func responseMetadataStateIgnoresUnknownMalformedAndAmbiguousEvents() {
  for type in ["response.metadata", "codex.response.metadata"] {
    let event = JSONValue.object([
      "type": .string(type), "headers": .object(["X-Codex-Turn-State": .string("synthetic")]),
    ])
    #expect(responseMetadataTurnState(event) == "synthetic")
  }
  for event in [
    JSONValue.object([
      "type": .string("synthetic.metadata"),
      "headers": .object(["x-codex-turn-state": .string("synthetic")]),
    ]),
    .object(["type": .string("response.metadata"), "headers": .bool(true)]),
    .object([
      "type": .string("response.metadata"),
      "headers": .object(["x-codex-turn-state": .bool(true)]),
    ]),
    .object([
      "type": .string("response.metadata"),
      "headers": .object([
        "x-codex-turn-state": .string("one"), "X-Codex-Turn-State": .string("two"),
      ]),
    ]),
  ] {
    #expect(responseMetadataTurnState(event) == nil)
  }
}

@Test func turnStateLookupSlidesTTLAndRefreshesEvictionOrder() throws {
  let clock = Mutex(ContinuousClock.now)
  let owners = TurnStateOwners(now: { clock.withLock { $0 } })
  let account = try AccountRouteIdentity(id: "a", namespace: "synthetic")
  owners.observe(key: "key", token: "live", account: account)
  for _ in 0..<3 {
    clock.withLock { $0 = $0.advanced(by: .seconds(3599)) }
    #expect(try owners.owner(key: "key", token: "live") == account)
  }
  for index in 0..<1023 {
    clock.withLock { $0 = $0.advanced(by: .milliseconds(1)) }
    owners.observe(key: "key", token: "state-\(index)", account: account)
  }
  clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
  #expect(try owners.owner(key: "key", token: "live") == account)
  owners.observe(key: "key", token: "new", account: account)
  #expect(try owners.owner(key: "key", token: "live") == account)
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "key", token: "state-0") }
  clock.withLock { $0 = $0.advanced(by: .seconds(3600)) }
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "key", token: "live") }
}

@Test func turnStateMissAndConflictLookupDoNotRefreshEntries() throws {
  let clock = Mutex(ContinuousClock.now)
  let owners = TurnStateOwners(now: { clock.withLock { $0 } })
  let a = try AccountRouteIdentity(id: "a", namespace: "synthetic")
  let b = try AccountRouteIdentity(id: "b", namespace: "synthetic")
  owners.observe(key: "key", token: "conflict", account: a)
  owners.observe(key: "key", token: "conflict", account: b)
  owners.observe(key: "key", token: "unused", account: a)
  clock.withLock { $0 = $0.advanced(by: .seconds(3599)) }
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "key", token: "conflict") }
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "other", token: "unused") }
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "key", token: "missing") }
  clock.withLock { $0 = $0.advanced(by: .seconds(1)) }
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "key", token: "unused") }
  // After the original tombstone expires, a new observation may establish an owner.
  owners.observe(key: "key", token: "conflict", account: a)
  #expect(try owners.owner(key: "key", token: "conflict") == a)
  #expect(throws: GatewayProtocolError.self) { try owners.owner(key: "key", token: "missing") }
}

@Test func responseMetadataArrayUsesOnlyFirstElementWithSameValidation() {
  for value in [JSONValue.string("synthetic"), .array([.string("synthetic"), .bool(true)])] {
    #expect(
      responseMetadataTurnState(
        .object([
          "type": .string("response.metadata"), "headers": .object(["x-codex-turn-state": value]),
        ])) == "synthetic")
  }
  for value in [
    JSONValue.array([]), .array([.bool(true), .string("synthetic")]),
    .array([.string("")]), .array([.string(String(repeating: "x", count: 8193))]),
    .array([.string("invalid\nstate")]), .object([:]), .null,
  ] {
    #expect(
      responseMetadataTurnState(
        .object([
          "type": .string("response.metadata"), "headers": .object(["x-codex-turn-state": value]),
        ])) == nil)
  }
}
