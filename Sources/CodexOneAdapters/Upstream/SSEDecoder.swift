import Foundation

struct SSEDecoder {
  private var buffer = Data()
  private var total = 0
  private(set) var sawDone = false
  mutating func append(_ data: Data) throws -> [JSONValue] {
    guard data.count <= 8_388_608 - total else {
      throw GatewayProtocolError(502, "upstream_response_too_large")
    }
    total += data.count
    buffer.append(data)
    var output: [JSONValue] = []
    while true {
      let lf = buffer.range(of: Data([10, 10]))
      let crlf = buffer.range(of: Data([13, 10, 13, 10]))
      let delimiter: Range<Data.Index>?
      if let lf, let crlf {
        delimiter = lf.lowerBound < crlf.lowerBound ? lf : crlf
      } else {
        delimiter = lf ?? crlf
      }
      guard let delimiter else { break }
      let length = buffer.distance(from: buffer.startIndex, to: delimiter.lowerBound)
      guard length <= 262_144 else { throw GatewayProtocolError(502, "upstream_event_too_large") }
      let event = Data(buffer[..<delimiter.lowerBound])
      buffer.removeSubrange(..<delimiter.upperBound)
      guard let text = String(data: event, encoding: .utf8) else {
        throw GatewayProtocolError(502, "invalid_upstream_event")
      }
      let lines = text.components(separatedBy: "\n").map {
        $0.hasSuffix("\r") ? String($0.dropLast()) : $0
      }
      let payload = lines.filter { $0.hasPrefix("data:") }.map { line in
        let rest = line.dropFirst(5)
        return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
      }.joined(separator: "\n")
      if payload.isEmpty { continue }
      guard !sawDone else { throw GatewayProtocolError(502, "invalid_upstream_event") }
      if payload == "[DONE]" {
        sawDone = true
        continue
      }
      do { output.append(try JSONValue.decode(Data(payload.utf8))) } catch {
        throw GatewayProtocolError(502, "invalid_upstream_event")
      }
    }
    guard buffer.count <= 262_144 else {
      throw GatewayProtocolError(502, "upstream_event_too_large")
    }
    return output
  }
  func finish() throws {
    guard buffer.isEmpty else { throw GatewayProtocolError(502, "incomplete_upstream_event") }
  }
}
