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

/// One producer; named queues share count/byte limits before any task or actor mailbox entry.
final class WebSocketInbox: Sendable {
  private struct State {
    var queues: [String: [Data]] = [:]
    var bytes = 0
    var count = 0
    var waiters: [String: CheckedContinuation<Data, any Error>] = [:]
    var producer: (lane: String, bytes: Int, continuation: CheckedContinuation<Void, any Error>)?
    var error: (any Error)?
    func hasSpace(lane: String, bytes: Int) -> Bool {
      (queues[lane]?.count ?? 0) < 4 && count < 64 && bytes <= 1_048_576 - self.bytes
    }
  }
  private let state = Mutex(State())
  func push(_ data: Data, lane: String = "") async throws {
    while true {
      let pushed = try state.withLock { value -> Bool in
        if let error = value.error { throw error }
        if let waiter = value.waiters.removeValue(forKey: lane) {
          waiter.resume(returning: data)
          return true
        }
        guard value.hasSpace(lane: lane, bytes: data.count) else { return false }
        guard value.queues[lane] != nil || value.queues.count < 33 else {
          throw ExecutionError.capacity
        }
        value.queues[lane, default: []].append(data)
        value.bytes += data.count
        value.count += 1
        return true
      }
      if pushed { return }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          state.withLock { value in
            if let error = value.error {
              continuation.resume(throwing: error)
            } else if value.hasSpace(lane: lane, bytes: data.count) {
              continuation.resume()
            } else if value.producer != nil {
              continuation.resume(throwing: ExecutionError.conflict)
            } else {
              value.producer = (lane, data.count, continuation)
            }
          }
        }
      } onCancel: {
        self.finish(CancellationError(), discard: true)
      }
    }
  }
  func finish(_ error: any Error, discard: Bool = false) {
    state.withLock { value in
      if value.error == nil { value.error = error }
      if discard {
        value.queues.removeAll()
        value.bytes = 0
        value.count = 0
      }
      for waiter in value.waiters.values { waiter.resume(throwing: error) }
      value.waiters.removeAll()
      value.producer?.continuation.resume(throwing: error)
      value.producer = nil
    }
  }
  func next(lane: String = "") async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        state.withLock { value in
          if value.queues[lane]?.isEmpty == false {
            let data = value.queues[lane]!.removeFirst()
            value.bytes -= data.count
            value.count -= 1
            if let producer = value.producer,
              value.hasSpace(lane: producer.lane, bytes: producer.bytes)
            {
              value.producer = nil
              producer.continuation.resume()
            }
            continuation.resume(returning: data)
          } else if let error = value.error {
            continuation.resume(throwing: error)
          } else if value.waiters[lane] != nil || value.waiters.count >= 33 {
            continuation.resume(throwing: ExecutionError.conflict)
          } else {
            value.waiters[lane] = continuation
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
  func beginTurn(lane: String = "") throws { try turns?.begin(lane: lane) }
  func attachEvidence(lane: String, handler: @escaping @Sendable (JSONValue) throws -> Void) throws
  {
    try turns?.attachEvidence(lane: lane, handler: handler)
  }
  func detachEvidence(lane: String) { turns?.detachEvidence(lane: lane) }
  func next(lane: String = "") async throws -> Data { try await inbox.next(lane: lane) }
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
                let lane = try turns?.observe(data) ?? ""
                try await withExecutionDeadline(seconds: 5) {
                  try await inbox.push(data, lane: lane)
                }
              case .ping: try await writer.send(data, opcode: .pong)
              case .pong: break
              case .connectionClose:
                turns?.close()
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
