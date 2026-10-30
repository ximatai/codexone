import Foundation

/// Deliver each event before consuming later bytes: transport chunking cannot erase prior evidence.
struct SSEDecoder {
  var maximumEventBytes = 262_144
  var maximumTotalBytes = 8_388_608
  private var buffer: [UInt8] = []
  private var total = 0
  private(set) var sawDone = false

  /// Includes comment-only events and [DONE], which do not return a JSON value.
  var isAtEventBoundary: Bool { buffer.isEmpty }

  mutating func append(_ byte: UInt8) throws -> JSONValue? {
    guard total < maximumTotalBytes else {
      throw GatewayProtocolError(502, "upstream_response_too_large")
    }
    total += 1
    buffer.append(byte)
    let delimiter: Int
    if buffer.suffix(4).elementsEqual([13, 10, 13, 10]) {
      delimiter = 4
    } else if buffer.suffix(2).elementsEqual([10, 10]) {
      delimiter = 2
    } else {
      guard buffer.count <= maximumEventBytes + 4 else {
        throw GatewayProtocolError(502, "upstream_event_too_large")
      }
      return nil
    }
    guard buffer.count - delimiter <= maximumEventBytes else {
      throw GatewayProtocolError(502, "upstream_event_too_large")
    }
    guard let text = String(bytes: buffer.dropLast(delimiter), encoding: .utf8) else {
      throw GatewayProtocolError(502, "invalid_upstream_event")
    }
    buffer.removeAll(keepingCapacity: true)
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map
    {
      $0.hasSuffix("\r") ? String($0.dropLast()) : $0
    }
    let payload = lines.filter { $0.hasPrefix("data:") }.map { line in
      let rest = line.dropFirst(5)
      return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
    }.joined(separator: "\n")
    if payload.isEmpty { return nil }
    guard !sawDone else { throw GatewayProtocolError(502, "invalid_upstream_event") }
    if payload == "[DONE]" {
      sawDone = true
      return nil
    }
    do { return try JSONValue.decode(Data(payload.utf8)) } catch {
      throw GatewayProtocolError(502, "invalid_upstream_event")
    }
  }

  func finish() throws {
    guard buffer.isEmpty else { throw GatewayProtocolError(502, "incomplete_upstream_event") }
  }
}
