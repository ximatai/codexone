import CodexOneCore
import Foundation
import NIOCore
import NIOWebSocket
import Synchronization

typealias ProtocolWebSocket = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>

/// Event-loop confined; validate wire properties before aggregation removes masking information.
private final class WebSocketWireGuard: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias InboundOut = WebSocketFrame
  private let masked: Bool
  init(masked: Bool) { self.masked = masked }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    guard (frame.maskKey != nil) == masked, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
      context.fireErrorCaught(GatewayProtocolError(400, "invalid_websocket_frame"))
      context.close(promise: nil)
      return
    }
    context.fireChannelRead(data)
  }
}

func configureWebSocket(_ channel: any Channel, client: Bool) throws -> ProtocolWebSocket {
  try channel.pipeline.syncOperations.addHandlers(
    WebSocketWireGuard(masked: !client),
    NIOWebSocketFrameAggregator(
      minNonFinalFragmentSize: 1, maxAccumulatedFrameCount: 1024,
      maxAccumulatedFrameSize: 524_288))
  return try .init(
    wrappingChannelSynchronously: channel,
    configuration: .init(backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4)))
}

/// One waiter and a byte/count-bounded queue; producer never creates a task or actor mailbox entry.
private final class WebSocketInbox: Sendable {
  private struct State {
    var queue: [Data] = []
    var bytes = 0
    var waiter: CheckedContinuation<Data, any Error>?
    var producer: (Int, CheckedContinuation<Void, any Error>)?
    var error: (any Error)?
  }
  private let state = Mutex(State())
  func push(_ data: Data) async throws {
    while true {
      let pushed = try state.withLock { value -> Bool in
        if let error = value.error { throw error }
        if let waiter = value.waiter {
          value.waiter = nil
          waiter.resume(returning: data)
          return true
        }
        guard value.queue.count < 4, data.count <= 1_048_576 - value.bytes else { return false }
        value.queue.append(data)
        value.bytes += data.count
        return true
      }
      if pushed { return }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          state.withLock { value in
            if let error = value.error {
              continuation.resume(throwing: error)
            } else if value.queue.count < 4, data.count <= 1_048_576 - value.bytes {
              continuation.resume()
            } else {
              value.producer = (data.count, continuation)
            }
          }
        }
      } onCancel: {
        self.finish(CancellationError(), discard: true)
      }
    }
  }
  func finish(_ error: any Error, discard: Bool = false) {
    let waiter = state.withLock { value in
      if value.error == nil { value.error = error }
      if discard {
        value.queue.removeAll()
        value.bytes = 0
      }
      let waiter = value.waiter
      value.waiter = nil
      value.producer?.1.resume(throwing: error)
      value.producer = nil
      return waiter
    }
    waiter?.resume(throwing: error)
  }
  func next() async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        state.withLock { value in
          if !value.queue.isEmpty {
            let data = value.queue.removeFirst()
            value.bytes -= data.count
            if let producer = value.producer, value.queue.count < 4,
              producer.0 <= 1_048_576 - value.bytes
            {
              value.producer = nil
              producer.1.resume()
            }
            continuation.resume(returning: data)
          } else if let error = value.error {
            continuation.resume(throwing: error)
          } else if value.waiter != nil {
            continuation.resume(throwing: ExecutionError.conflict)
          } else {
            value.waiter = continuation
          }
        }
      }
    } onCancel: {
      self.finish(CancellationError(), discard: true)
    }
  }
}

actor WebSocketWriter {
  private let writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>
  private let channel: any Channel
  private let client: Bool
  init(writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>, channel: any Channel, client: Bool) {
    self.writer = writer
    self.channel = channel
    self.client = client
  }
  func send(_ data: Data, opcode: WebSocketOpcode = .text) async throws {
    guard data.count <= 524_288 else {
      throw GatewayProtocolError(413, "websocket_message_too_large")
    }
    let deadline = channel.eventLoop.scheduleTask(in: .seconds(5)) {
      self.channel.close(promise: nil)
    }
    defer { deadline.cancel() }
    try await writer.write(
      .init(
        fin: true, opcode: opcode, maskKey: client ? .random() : nil, data: ByteBuffer(data: data)))
  }
}

struct WebSocketPeer: Sendable {
  private let inbox: WebSocketInbox
  let writer: WebSocketWriter
  private let turns: WebSocketTurns?
  func beginTurn() throws { try turns?.begin() }
  func next() async throws -> Data { try await inbox.next() }
  func send(_ value: JSONValue) async throws { try await writer.send(value.data()) }

  static func run(
    _ socket: ProtocolWebSocket, client: Bool,
    operation: @escaping @Sendable (WebSocketPeer) async throws -> Void
  ) async throws {
    let lifetime = socket.channel.eventLoop.scheduleTask(in: .seconds(3600)) {
      socket.channel.close(promise: nil)
    }
    defer { lifetime.cancel() }
    try await socket.executeThenClose { inbound, outbound in
      let inbox = WebSocketInbox()
      let turns = client ? WebSocketTurns() : nil
      let writer = WebSocketWriter(writer: outbound, channel: socket.channel, client: client)
      try await withThrowingTaskGroup(of: Bool.self) { tasks in
        tasks.addTask {
          do {
            for try await frame in inbound {
              let data = Data(frame.unmaskedData.readableBytesView)
              switch frame.opcode {
              case .text:
                guard String(data: data, encoding: .utf8) != nil else {
                  throw GatewayProtocolError(400, "invalid_websocket_text")
                }
                try turns?.observe(data)
                try await withExecutionDeadline(seconds: 5) { try await inbox.push(data) }
              case .ping: try await writer.send(data, opcode: .pong)
              case .pong: break
              case .connectionClose:
                try? await writer.send(data, opcode: .connectionClose)
                inbox.finish(GatewayProtocolError(502, "execution_indeterminate"))
                return !client
              default: throw GatewayProtocolError(400, "unsupported_websocket_frame")
              }
            }
          } catch { inbox.finish(error) }
          turns?.close()
          inbox.finish(GatewayProtocolError(502, "execution_indeterminate"))
          return !client
        }
        tasks.addTask {
          try await operation(.init(inbox: inbox, writer: writer, turns: turns))
          return true
        }
        tasks.addTask {
          await withTaskCancellationHandler {
            try? await socket.channel.closeFuture.get()
          } onCancel: {
            socket.channel.close(promise: nil)
          }
          if !client { inbox.finish(GatewayProtocolError(502, "execution_indeterminate")) }
          return !client
        }
        defer {
          turns?.close()
          inbox.finish(CancellationError())
          socket.channel.close(promise: nil)
          tasks.cancelAll()
        }
        while let done = try await tasks.next() { if done { break } }
      }
    }
  }
}
