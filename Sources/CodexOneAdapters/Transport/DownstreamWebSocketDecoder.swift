import Foundation
import NIOCore
import NIOWebSocket
import Synchronization

/// Only completed bodies cross the async channel; partial uploads stay owned by the wire reader.
final class WebSocketBodyReservations: Sendable {
  private let leases = Mutex<[RequestBodyLease]>([])
  func append(_ lease: RequestBodyLease) { leases.withLock { $0.append(lease) } }
  func take() -> RequestBodyLease? { leases.withLock { $0.isEmpty ? nil : $0.removeFirst() } }
  func close() { leases.withLock { $0.removeAll() } }
}

/// Incremental masked-frame reader. Admission precedes buffering even for a single large frame.
final class DownstreamWebSocketDecoder: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = WebSocketFrame
  private let budget: RequestBodyBudget
  private let reservations: WebSocketBodyReservations
  private var header = [UInt8]()
  private var remaining = 0
  private var offset = 0
  private var mask = [UInt8]()
  private var opcode: UInt8 = 0
  private var final = false
  private var active = false
  private var fragments = 0
  private var body = Data()
  private var control = Data()
  private var lease: RequestBodyLease?
  private var rejected = false
  private var messageBytes = 0
  init(budget: RequestBodyBudget, reservations: WebSocketBodyReservations) {
    self.budget = budget
    self.reservations = reservations
  }
  func channelInactive(context: ChannelHandlerContext) {
    lease = nil
    reservations.close()
    context.fireChannelInactive()
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var input = unwrapInboundIn(data)
    do {
      while input.readableBytes > 0 {
        if remaining == 0 {
          while input.readableBytes > 0 {
            header.append(input.readInteger(as: UInt8.self)!)
            if header.count >= 2 {
              let code = header[1] & 127
              let needed = 2 + (code == 126 ? 2 : code == 127 ? 8 : 0) + 4
              if header.count == needed { break }
            }
          }
          guard header.count >= 2 else { return }
          let code = header[1] & 127
          let needed = 2 + (code == 126 ? 2 : code == 127 ? 8 : 0) + 4
          guard header.count == needed else { return }
          guard header[0] & 0x70 == 0, header[1] & 0x80 != 0 else {
            throw GatewayProtocolError(400, "invalid_websocket_frame")
          }
          opcode = header[0] & 15
          final = header[0] & 128 != 0
          var length = UInt64(code)
          if code >= 126 {
            length = 0
            for byte in header[2..<(needed - 4)] { length = (length << 8) | UInt64(byte) }
            guard length <= UInt64(Int.max), length >= (code == 126 ? 126 : 65536) else {
              throw GatewayProtocolError(400, "invalid_websocket_frame")
            }
          }
          guard [0, 1, 8, 9, 10].contains(opcode),
            opcode < 8 || (final && length <= 125),
            opcode != 0 || active, opcode != 1 || !active
          else { throw GatewayProtocolError(400, "invalid_websocket_frame") }
          mask = Array(header.suffix(4))
          header.removeAll(keepingCapacity: true)
          remaining = Int(length)
          offset = 0
          if opcode < 8 {
            if opcode == 1 {
              active = true
              lease = budget.lease()
              fragments = 0
              messageBytes = 0
            }
            fragments += 1
            if !rejected {
              do {
                guard remaining <= RequestBodyLimits.maximumBytes - messageBytes,
                  fragments <= 1024
                else { throw GatewayProtocolError(413, "request_too_large") }
                messageBytes += remaining
                try lease?.reserve(messageBytes)
              } catch {
                rejected = true
                body = Data()
                lease = nil
                let failure = protocolFailure(error)
                let envelope: JSONValue = .object([
                  "type": .string("error"), "status": .number(Decimal(failure.status)),
                  "error": protocolErrorEnvelope(error, requestID: UUID().uuidString)["error"]!,
                ])
                let deadline = context.eventLoop.scheduleTask(in: .seconds(5)) {
                  [channel = context.channel] in
                  channel.close(promise: nil)
                }
                let written = context.channel.writeAndFlush(
                  WebSocketFrame(
                    fin: true, opcode: .text, data: ByteBuffer(data: try envelope.data())))
                written.whenComplete { _ in deadline.cancel() }
              }
            }
          } else {
            control.removeAll(keepingCapacity: true)
          }
        }
        let count = min(remaining, input.readableBytes)
        if count > 0 {
          let bytes = input.readBytes(length: count)!
          if opcode >= 8 || !rejected {
            let decoded = bytes.enumerated().map { $0.element ^ mask[(offset + $0.offset) % 4] }
            if opcode >= 8 {
              control.append(contentsOf: decoded)
            } else {
              body.append(contentsOf: decoded)
            }
          }
          offset += count
          remaining -= count
        }
        if remaining == 0 {
          if opcode >= 8 {
            if opcode == 8 {
              guard control.count != 1 else {
                throw GatewayProtocolError(400, "invalid_websocket_frame")
              }
              if control.count >= 2 {
                let code = Int(control[0]) * 256 + Int(control[1])
                guard (1000..<5000).contains(code), ![1004, 1005, 1006, 1015].contains(code),
                  code < 1016 || code >= 3000,
                  String(data: control.dropFirst(2), encoding: .utf8) != nil
                else { throw GatewayProtocolError(400, "invalid_websocket_frame") }
              }
            }
            let kind: WebSocketOpcode = opcode == 8 ? .connectionClose : opcode == 9 ? .ping : .pong
            context.fireChannelRead(
              wrapInboundOut(.init(fin: true, opcode: kind, data: ByteBuffer(data: control))))
          } else if final {
            if !rejected {
              guard String(data: body, encoding: .utf8) != nil else {
                throw GatewayProtocolError(400, "invalid_websocket_text")
              }
              if let lease { reservations.append(lease) }
              context.fireChannelRead(
                wrapInboundOut(.init(fin: true, opcode: .text, data: ByteBuffer(data: body))))
            }
            body = Data()
            lease = nil
            active = false
            rejected = false
          }
        }
      }
    } catch {
      lease = nil
      context.fireErrorCaught(error)
      context.close(promise: nil)
    }
  }
}
