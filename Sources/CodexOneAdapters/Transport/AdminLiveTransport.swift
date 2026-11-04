import CodexOneCore
import Foundation
import NIOCore
import NIOWebSocket
import Synchronization

/// Reject before aggregation: control frames only, no fragmentation/extensions/application data.
final class AdminLiveWireGuard: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias InboundOut = WebSocketFrame
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    guard frame.maskKey != nil, frame.fin, !frame.rsv1, !frame.rsv2, !frame.rsv3,
      frame.data.readableBytes <= 125,
      [.ping, .pong, .connectionClose].contains(frame.opcode)
    else {
      context.close(promise: nil)
      return
    }
    context.fireChannelRead(data)
  }
}

struct AdminLiveTransport: Sendable {
  let socket: ProtocolWebSocket
  let id: UUID
  let sessions: AdminSessions
  let overview: OverviewLive
  static func close(_ channel: any Channel, code: UInt16) {
    channel.eventLoop.execute {
      let bytes = ByteBuffer(bytes: [UInt8(code >> 8), UInt8(code & 255)])
      channel.writeAndFlush(
        WebSocketFrame(fin: true, opcode: .connectionClose, data: bytes), promise: nil)
      _ = channel.eventLoop.scheduleTask(in: .seconds(2)) { channel.close(promise: nil) }
    }
  }
  func run() async throws {
    let mailbox = OverviewMailbox { code in Self.close(socket.channel, code: code) }
    do { try await overview.subscribe(id: id, mailbox: mailbox) } catch {
      sessions.releaseLive(id)
      Self.close(socket.channel, code: 1013)
      throw error
    }
    do {
      try await withTaskCancellationHandler {
        try await socket.executeThenClose { inbound, _ in
          let heartbeat = Mutex((sent: ContinuousClock.Instant?.none, pong: false))
          try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask {
              var window = ContinuousClock.now
              var controls = 0
              for try await frame in inbound {
                if window.duration(to: .now) >= .seconds(1) {
                  window = .now
                  controls = 0
                }
                controls += 1
                guard controls <= 64 else {
                  Self.close(socket.channel, code: 1008)
                  return
                }
                switch frame.opcode {
                case .pong: heartbeat.withLock { $0.pong = true }
                case .ping:
                  try await send(Data(frame.unmaskedData.readableBytesView), opcode: .pong)
                case .connectionClose:
                  let closing = socket.channel.eventLoop.scheduleTask(in: .seconds(2)) {
                    socket.channel.close(promise: nil)
                  }
                  defer { closing.cancel() }
                  try await send(
                    Data(frame.unmaskedData.readableBytesView), opcode: .connectionClose)
                  return
                default: return
                }
              }
            }
            tasks.addTask {
              var sequence: Int64 = 0
              let epoch = overview.epoch
              while let message = await mailbox.next() {
                sequence += 1
                let prefix =
                  "{\"protocol\":1,\"epoch\":\"\(epoch)\",\"sequence\":\(sequence),\"kind\":\"\(message.snapshot ? "snapshot" : "update")\",\"sections\":"
                var data = Data(prefix.utf8)
                data.append(message.data)
                data.append(125)
                try await send(data)
              }
            }
            tasks.addTask {
              var nextPing = ContinuousClock.now.advanced(by: .seconds(15))
              while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                guard sessions.withLive(id) else {
                  Self.close(socket.channel, code: 1008)
                  return
                }
                let expired = heartbeat.withLock { value in
                  value.sent.map { !value.pong && $0.advanced(by: .seconds(10)) <= .now } ?? false
                }
                if expired { return }
                if ContinuousClock.now >= nextPing {
                  guard sessions.withLive(id, touch: true) else {
                    Self.close(socket.channel, code: 1008)
                    return
                  }
                  heartbeat.withLock {
                    $0.sent = .now
                    $0.pong = false
                  }
                  try await send(Data(), opcode: .ping)
                  nextPing = .now.advanced(by: .seconds(15))
                }
              }
            }
            _ = try await tasks.next()
            tasks.cancelAll()
            mailbox.finish()
            socket.channel.close(promise: nil)
          }
        }
      } onCancel: {
        mailbox.finish()
        Self.close(socket.channel, code: 1001)
      }
    } catch {
      mailbox.finish()
      socket.channel.close(promise: nil)
    }
    sessions.releaseLive(id)
    await overview.unsubscribe(id: id)
  }
  private func send(_ data: Data, opcode: WebSocketOpcode = .text) async throws {
    guard data.count <= 1_048_576 else { throw ExecutionError.capacity }
    let channel = socket.channel
    let promise = channel.eventLoop.makePromise(of: Void.self)
    let deadline = channel.eventLoop.scheduleTask(in: .seconds(5)) {
      Self.close(channel, code: 1013)
      channel.close(promise: nil)
    }
    defer { deadline.cancel() }
    guard
      sessions.withLive(
        id,
        operation: {
          channel.writeAndFlush(
            WebSocketFrame(fin: true, opcode: opcode, data: ByteBuffer(data: data)),
            promise: promise)
        })
    else {
      Self.close(channel, code: 1008)
      throw ExecutionError.unauthorized
    }
    try await promise.futureResult.get()
  }
}
