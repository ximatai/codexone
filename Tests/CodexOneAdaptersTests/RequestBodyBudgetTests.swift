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
  let error = try #require(try other.readOutbound(as: WebSocketFrame.self))
  #expect(try JSONValue.decode(Data(error.data.readableBytesView))["status"]?.integer == 503)
  #expect(budget.occupiedBytes == size)
  _ = try channel.finish()
  #expect(budget.occupiedBytes == 0)
  _ = try other.finish()
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
