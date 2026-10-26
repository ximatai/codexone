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
      maxAccumulatedFrameSize: ImageLimits.eventBytes))
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
      (queues[lane]?.count ?? 0) < 4 && count < 64 && bytes <= ImageLimits.eventBytes - self.bytes
    }
  }
  private let state = Mutex(State())
  func push(_ data: Data, lane: String = "") async throws {
    while true {
      let result = try state.withLock { value -> (Bool, CheckedContinuation<Data, any Error>?) in
        if let error = value.error { throw error }
        if let waiter = value.waiters.removeValue(forKey: lane) { return (true, waiter) }
        guard value.hasSpace(lane: lane, bytes: data.count) else { return (false, nil) }
        guard value.queues[lane] != nil || value.queues.count < 33 else {
          throw ExecutionError.capacity
        }
        value.queues[lane, default: []].append(data)
        value.bytes += data.count
        value.count += 1
        return (true, nil)
      }
      result.1?.resume(returning: data)
      if result.0 { return }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          let ready = state.withLock { value -> Result<Void, any Error>? in
            if let error = value.error { return .failure(error) }
            if value.hasSpace(lane: lane, bytes: data.count) { return .success(()) }
            if value.producer != nil { return .failure(ExecutionError.conflict) }
            value.producer = (lane, data.count, continuation)
            return nil
          }
          if let ready { continuation.resume(with: ready) }
        }
      } onCancel: {
        self.finish(CancellationError(), discard: true)
      }
    }
  }
  func finish(_ error: any Error, discard: Bool = false) {
    let pending = state.withLock { value in
      if value.error == nil { value.error = error }
      if discard {
        value.queues.removeAll()
        value.bytes = 0
        value.count = 0
      }
      let waiters = Array(value.waiters.values)
      let producer = value.producer?.continuation
      value.waiters.removeAll()
      value.producer = nil
      return (waiters, producer)
    }
    // Resuming can synchronously interact with task cancellation. Never do it under the inbox lock.
    for waiter in pending.0 { waiter.resume(throwing: error) }
    pending.1?.resume(throwing: error)
  }
  func next(lane: String = "") async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let ready = state.withLock {
          value -> (Result<Data, any Error>?, CheckedContinuation<Void, any Error>?) in
          if value.queues[lane]?.isEmpty == false {
            let data = value.queues[lane]!.removeFirst()
            value.bytes -= data.count
            value.count -= 1
            var producer: CheckedContinuation<Void, any Error>?
            if let waiting = value.producer,
              value.hasSpace(lane: waiting.lane, bytes: waiting.bytes)
            {
              producer = waiting.continuation
              value.producer = nil
            }
            return (.success(data), producer)
          }
          if let error = value.error { return (.failure(error), nil) }
          if value.waiters[lane] != nil || value.waiters.count >= 33 {
            return (.failure(ExecutionError.conflict), nil)
          }
          value.waiters[lane] = continuation
          return (nil, nil)
        }
        ready.1?.resume()
        if let result = ready.0 { continuation.resume(with: result) }
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
  func send(_ data: Data, opcode: WebSocketOpcode = .text, normalizedImage: Bool = false)
    async throws
  {
    guard
      data.count
        <= (client && normalizedImage ? ImageLimits.normalizedRequestBytes : ImageLimits.eventBytes)
    else {
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
  func beginTurn(lane: String = "", compaction: Bool = false) throws {
    try turns?.begin(lane: lane, compaction: compaction)
  }
  func attachEvidence(lane: String, handler: @escaping @Sendable (JSONValue) throws -> Void) throws
  {
    try turns?.attachEvidence(lane: lane, handler: handler)
  }
  func detachEvidence(lane: String) { turns?.detachEvidence(lane: lane) }
  func next(lane: String = "") async throws -> Data { try await inbox.next(lane: lane) }
  func send(_ value: JSONValue, normalizedImage: Bool = false) async throws {
    try await writer.send(
      value.data(escapingSlashes: !normalizedImage), normalizedImage: normalizedImage)
  }

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
                guard let lane = try turns.map({ try $0.observe(data) }) ?? "" else { continue }
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
