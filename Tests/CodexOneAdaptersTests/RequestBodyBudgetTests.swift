import Foundation
import NIOCore
import NIOEmbedded
import NIOWebSocket
import Testing

@testable import CodexOneAdapters

private func maskedFrame(_ size: Int, opcode: UInt8 = 1, final: Bool = true) -> ByteBuffer {
  var buffer = ByteBuffer()
  buffer.writeInteger((final ? UInt8(128) : 0) | opcode)
  if size < 126 {
    buffer.writeInteger(UInt8(size) | 128)
  } else if size <= 65535 {
    buffer.writeInteger(UInt8(254))
    buffer.writeInteger(UInt16(size))
  } else {
    buffer.writeInteger(UInt8(255))
    buffer.writeInteger(UInt64(size))
  }
  buffer.writeBytes([UInt8](repeating: 0, count: 4))
  return buffer
}

@Test func websocketBudgetPrecedesSingleFrameBufferingAndDisconnectReturnsIt() throws {
  let size = 20 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: size)
  let reservations = WebSocketBodyReservations()
  let channel = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: reservations))
  try channel.writeInbound(maskedFrame(size))
  #expect(budget.occupiedBytes == size)
  let other = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: .init()))
  try other.writeInbound(maskedFrame(size))
  #expect(try other.readOutbound(as: WebSocketFrame.self) == nil)
  #expect(budget.waitingCount == 1)
  other.embeddedEventLoop.advanceTime(by: .seconds(5))
  let error = try #require(try other.readOutbound(as: WebSocketFrame.self))
  #expect(try JSONValue.decode(Data(error.data.readableBytesView))["status"]?.integer == 503)
  #expect(budget.occupiedBytes == size)
  _ = try channel.finish()
  #expect(budget.occupiedBytes == 0)
  _ = try other.finish()
}

@Test func websocketWaitingGrantAndDisconnectRemoveTickets() throws {
  let size = 9 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: size)
  let held = budget.lease()
  try held.reserve(size)
  let channel = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: .init()))
  try channel.writeInbound(maskedFrame(size))
  try channel.writeInbound(ByteBuffer(repeating: 65, count: 1024))
  #expect(budget.waitingCount == 1)
  #expect(try channel.readOutbound(as: WebSocketFrame.self) == nil)
  held.release()
  channel.embeddedEventLoop.advanceTime(by: .milliseconds(25))
  #expect(budget.waitingCount == 0)
  #expect(budget.occupiedBytes == size)
  _ = try channel.finish()
  #expect(budget.occupiedBytes == 0)
  try held.reserve(size)
  let disconnected = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: .init()))
  try disconnected.writeInbound(maskedFrame(size))
  #expect(budget.waitingCount == 1)
  _ = try disconnected.finish()
  #expect(budget.waitingCount == 0)
  held.release()
}

@Test func websocketWaitingStagingOverflowDrainsAndRecovers() throws {
  let size = 9 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: size)
  let held = budget.lease()
  try held.reserve(size)
  let reservations = WebSocketBodyReservations()
  let channel = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: reservations))
  try channel.writeInbound(maskedFrame(size))
  try channel.writeInbound(ByteBuffer(repeating: 65, count: size))
  #expect(budget.waitingCount == 0)
  #expect(try channel.readOutbound(as: WebSocketFrame.self) != nil)
  try channel.writeInbound(maskedFrame(2))
  try channel.writeInbound(ByteBuffer(string: "{}"))
  #expect(try channel.readInbound(as: WebSocketFrame.self)?.data.readableBytes == 2)
  reservations.take()?.release()
  held.release()
  _ = try channel.finish()
  #expect(budget.occupiedBytes == 0)
}

@Test func bodyCapacityQueueIsBoundedFIFOAndCancellationSafe() async throws {
  let size = 9 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: size)
  let held = budget.lease()
  try held.reserve(size)
  let first = budget.lease()
  let firstTicket = try #require(try first.beginWaiting(size))
  let second = budget.lease()
  let secondTicket = try #require(try second.beginWaiting(size))
  let third = try #require(try budget.lease().beginWaiting(size))
  let fourth = try #require(try budget.lease().beginWaiting(size))
  #expect(throws: GatewayProtocolError.self) { try budget.lease().beginWaiting(size) }
  held.release()
  #expect(!second.reserveIfReady(size, ticket: secondTicket))
  #expect(first.reserveIfReady(size, ticket: firstTicket))
  first.release()
  budget.cancelWait(secondTicket)
  budget.cancelWait(third)
  budget.cancelWait(fourth)
  try held.reserve(size)
  let waiting = Task { try await second.reserveWaiting(size) }
  while budget.waitingCount == 0 { await Task.yield() }
  waiting.cancel()
  await #expect(throws: CancellationError.self) { try await waiting.value }
  #expect(budget.waitingCount == 0)
  await #expect(throws: GatewayProtocolError.self) {
    try await second.reserveWaiting(size, timeout: .milliseconds(30))
  }
  #expect(budget.waitingCount == 0)
  held.release()
  #expect(budget.occupiedBytes == 0)
}

@Test func websocketFragmentRejectionDiscardsMessageAndRecoversBudgetAndConnection() throws {
  let size = 5 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: 9 * 1024 * 1024)
  let reservations = WebSocketBodyReservations()
  let channel = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: reservations))
  try channel.writeInbound(maskedFrame(size, final: false))
  try channel.writeInbound(ByteBuffer(repeating: 65, count: size))
  #expect(budget.occupiedBytes == 0)
  try channel.writeInbound(maskedFrame(size, opcode: 0))
  #expect(budget.occupiedBytes == 0)
  let error = try #require(try channel.readOutbound(as: WebSocketFrame.self))
  #expect(
    try JSONValue.decode(Data(error.data.readableBytesView))["error"]?["code"]?.string
      == "capacity_exhausted")
  try channel.writeInbound(ByteBuffer(repeating: 65, count: size))
  #expect(try channel.readInbound(as: WebSocketFrame.self) == nil)
  try channel.writeInbound(maskedFrame(2))
  try channel.writeInbound(ByteBuffer(string: "{}"))
  #expect(try channel.readInbound(as: WebSocketFrame.self)?.data.readableBytes == 2)
  reservations.take()?.release()
  #expect(budget.occupiedBytes == 0)
  _ = try channel.finish()
}

@Test func websocketOversizeFrameIsDrainedAndNextMessageRetainsItsLeaseUntilDispatch() throws {
  let budget = RequestBodyBudget()
  let reservations = WebSocketBodyReservations()
  let channel = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: reservations))
  let size = RequestBodyLimits.maximumBytes + 1
  try channel.writeInbound(maskedFrame(size))
  let error = try #require(try channel.readOutbound(as: WebSocketFrame.self))
  #expect(try JSONValue.decode(Data(error.data.readableBytesView))["status"]?.integer == 413)
  for _ in 0..<32 { try channel.writeInbound(ByteBuffer(repeating: 65, count: 1024 * 1024)) }
  try channel.writeInbound(ByteBuffer(repeating: 65, count: 1))
  try channel.writeInbound(maskedFrame(9 * 1024 * 1024))
  for _ in 0..<9 { try channel.writeInbound(ByteBuffer(repeating: 65, count: 1024 * 1024)) }
  #expect(try channel.readInbound(as: WebSocketFrame.self)?.data.readableBytes == 9 * 1024 * 1024)
  let lease = try #require(reservations.take())
  #expect(budget.occupiedBytes == 9 * 1024 * 1024)
  lease.release()
  lease.release()
  #expect(budget.occupiedBytes == 0)
  _ = try channel.finish()
}

@Test func bodyDiagnosticsDistinguishCapacityBoundaries() {
  let mib = 1024 * 1024
  for (bytes, bucket) in [
    (16 * mib, "at_most_16_mib"), (16 * mib + 1, "16_to_24_mib"),
    (24 * mib, "16_to_24_mib"), (24 * mib + 1, "24_to_32_mib"),
    (32 * mib, "24_to_32_mib"), (32 * mib + 1, "over_32_mib"),
  ] {
    #expect(ProtocolFailureDiagnostics.sizeBucket(bytes) == bucket)
  }
}

@Test func websocketHugeContinuationSizeDiagnosticDoesNotOverflow() throws {
  let budget = RequestBodyBudget()
  let channel = EmbeddedChannel(
    handler: DownstreamWebSocketDecoder(budget: budget, reservations: .init()))
  try channel.writeInbound(maskedFrame(1, final: false))
  try channel.writeInbound(ByteBuffer(repeating: 65, count: 1))
  // Only a header is supplied: rejecting its size must not allocate or add Int.max to 1.
  try channel.writeInbound(maskedFrame(Int.max, opcode: 0))
  let error = try #require(try channel.readOutbound(as: WebSocketFrame.self))
  #expect(try JSONValue.decode(Data(error.data.readableBytesView))["status"]?.integer == 413)
  #expect(budget.occupiedBytes == 0)
  _ = try channel.finish()
}

@Test func parsedWebsocketBodyDiscardsSharedBytesButTurnRetainsBudget() throws {
  let size = 9 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: size)
  let lease = budget.lease()
  try lease.reserve(size)
  let body = WebSocketBody(Data(repeating: 65, count: size), lease: lease)
  let handshakeOwner = body
  body.discardData()
  #expect(handshakeOwner.data.isEmpty)
  #expect(budget.occupiedBytes == size)
  let competing = budget.lease()
  #expect(throws: GatewayProtocolError.self) { try competing.reserve(size) }
  body.release()
  body.release()
  #expect(budget.occupiedBytes == 0)
  try competing.reserve(size)
  competing.release()
}

@Test func bodyCapacityWaitingAcquiresReleasedSpace() async throws {
  let size = 9 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: size)
  let held = budget.lease()
  try held.reserve(size)
  let next = budget.lease()
  let task = Task { try await next.reserveWaiting(size) }
  while budget.waitingCount == 0 { await Task.yield() }
  held.release()
  try await task.value
  #expect(budget.waitingCount == 0)
  #expect(budget.occupiedBytes == size)
  next.release()
  #expect(budget.occupiedBytes == 0)
}

@Test func sharedBodyBudgetHoldsTwoMaximumRequestsAndQueuesTheThird() async throws {
  let budget = RequestBodyBudget()
  let first = budget.lease()
  let second = budget.lease()
  let third = budget.lease()
  try first.reserve(RequestBodyLimits.maximumBytes)
  try second.reserve(RequestBodyLimits.maximumBytes)
  #expect(budget.occupiedBytes == 64 * 1024 * 1024)
  let waiting = Task { try await third.reserveWaiting(RequestBodyLimits.maximumBytes) }
  while budget.waitingCount == 0 { await Task.yield() }
  first.release()
  try await waiting.value
  #expect(budget.occupiedBytes == 64 * 1024 * 1024)
  second.release()
  third.release()
  #expect(budget.occupiedBytes == 0)
}
