import Foundation

/// Wire-only JSON tree. Domain commands never carry a downstream or provider document.
indirect enum JSONValue: Sendable, Codable, Equatable {
  case object(JSONObject)
  case array([JSONValue])
  case string(String)
  case number(Decimal)
  case bool(Bool)
  case null

  // Codable is for local configuration/fingerprints; wire input must use decode(_:) below.
  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let bool = try? value.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? value.decode(Decimal.self) {
      self = .number(number)
    } else if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let array = try? value.decode([JSONValue].self) {
      self = .array(array)
    } else {
      self = .object(JSONObject(try value.decode([String: JSONValue].self)))
    }
  }
  // Keyed encoding is intentionally limited to local Codable consumers, never wire sends.
  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let object):
      try value.encode(Dictionary(uniqueKeysWithValues: object.map { ($0.key, $0.value) }))
    case .array(let array): try value.encode(array)
    case .string(let string): try value.encode(string)
    case .number(let number): try value.encode(number)
    case .bool(let bool): try value.encode(bool)
    case .null: try value.encodeNil()
    }
  }
  var object: JSONObject? { if case .object(let object) = self { object } else { nil } }
  var array: [JSONValue]? { if case .array(let array) = self { array } else { nil } }
  var string: String? { if case .string(let string) = self { string } else { nil } }
  var bool: Bool? { if case .bool(let bool) = self { bool } else { nil } }
  var integer: Int64? {
    guard case .number(let decimal) = self else { return nil }
    return Int64(NSDecimalNumber(decimal: decimal).stringValue)
  }
  subscript(_ key: String) -> JSONValue? { object?[key] }
  static func decode(_ data: Data, rejectingDuplicateRootKeys: Set<String> = []) throws -> JSONValue
  {
    var depth = 0
    var quoted = false
    var escaped = false
    for byte in data {
      if quoted {
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          quoted = false
        }
      } else if byte == 34 {
        quoted = true
      } else if byte == 123 || byte == 91 {
        depth += 1
        guard depth <= 64 else { throw GatewayProtocolError(400, "json_too_deep") }
      } else if byte == 125 || byte == 93 {
        depth -= 1
      }
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    var scanner = JSONOrderScanner(data, trackedRootKeys: rejectingDuplicateRootKeys)
    let ordered = try scanner.restore(value)
    guard scanner.duplicateRootKeys.isDisjoint(with: rejectingDuplicateRootKeys) else {
      throw GatewayProtocolError(400, "invalid_json")
    }
    // Foundation owns the semantics on every platform; order is never worth a changed document.
    return ordered == value ? ordered : value
  }
  func data(escapingSlashes: Bool = true) throws -> Data {
    var writer = JSONOrderedWriter(escapingSlashes: escapingSlashes)
    try writer.write(self)
    return Data(writer.bytes)
  }

  // Only for locally generated, unordered maps. Wire documents always use JSONObject.
  @_disfavoredOverload
  static func object(_ dictionary: [String: JSONValue]) -> JSONValue {
    .object(JSONObject(dictionary))
  }
}
