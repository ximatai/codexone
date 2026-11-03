import Foundation

/// Keyed Encoder containers have no ordering contract, including for nested Encodable values.
/// Only scalar Decimal encoding delegates to Foundation, preserving its numeric behavior.
struct JSONOrderedWriter {
  var bytes: [UInt8] = []
  let escapingSlashes: Bool
  private let encoder = JSONEncoder()
  init(escapingSlashes: Bool) { self.escapingSlashes = escapingSlashes }

  mutating func write(_ value: JSONValue) throws {
    switch value {
    case .object(let object):
      bytes.append(123)
      for (index, entry) in object.enumerated() {
        if index != 0 { bytes.append(44) }
        string(entry.key)
        bytes.append(58)
        try write(entry.value)
      }
      bytes.append(125)
    case .array(let array):
      bytes.append(91)
      for (index, value) in array.enumerated() {
        if index != 0 { bytes.append(44) }
        try write(value)
      }
      bytes.append(93)
    case .string(let value): string(value)
    case .number(let value): bytes.append(contentsOf: try encoder.encode(value))
    case .bool(let value):
      bytes.append(contentsOf: value ? [116, 114, 117, 101] : [102, 97, 108, 115, 101])
    case .null: bytes.append(contentsOf: [110, 117, 108, 108])
    }
  }

  private mutating func string(_ value: String) {
    bytes.append(34)
    for byte in value.utf8 {
      switch byte {
      case 34, 92: bytes.append(contentsOf: [92, byte])
      case 47 where escapingSlashes: bytes.append(contentsOf: [92, byte])
      case 8: bytes.append(contentsOf: [92, 98])
      case 9: bytes.append(contentsOf: [92, 116])
      case 10: bytes.append(contentsOf: [92, 110])
      case 12: bytes.append(contentsOf: [92, 102])
      case 13: bytes.append(contentsOf: [92, 114])
      case 0..<32:
        let hex = Array("0123456789abcdef".utf8)
        bytes.append(contentsOf: [92, 117, 48, 48, hex[Int(byte / 16)], hex[Int(byte % 16)]])
      default: bytes.append(byte)
      }
    }
    bytes.append(34)
  }
}
