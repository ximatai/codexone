import Foundation
import Testing

@testable import CodexOneAdapters

/// Wire-only JSON tree. Domain commands never carry a downstream or provider document.
private indirect enum LegacyJSONValue: Sendable, Codable, Equatable {
  case object([String: LegacyJSONValue])
  case array([LegacyJSONValue])
  case string(String)
  case number(Decimal)
  case bool(Bool)
  case null

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
    } else if let array = try? value.decode([LegacyJSONValue].self) {
      self = .array(array)
    } else {
      self = .object(try value.decode([String: LegacyJSONValue].self))
    }
  }
  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let object): try value.encode(object)
    case .array(let array): try value.encode(array)
    case .string(let string): try value.encode(string)
    case .number(let number): try value.encode(number)
    case .bool(let bool): try value.encode(bool)
    case .null: try value.encodeNil()
    }
  }
  var object: [String: LegacyJSONValue]? {
    if case .object(let object) = self { object } else { nil }
  }
  var array: [LegacyJSONValue]? { if case .array(let array) = self { array } else { nil } }
  var string: String? { if case .string(let string) = self { string } else { nil } }
  var bool: Bool? { if case .bool(let bool) = self { bool } else { nil } }
  var integer: Int64? {
    guard case .number(let decimal) = self else { return nil }
    return Int64(NSDecimalNumber(decimal: decimal).stringValue)
  }
  subscript(_ key: String) -> LegacyJSONValue? { object?[key] }
  static func decode(_ data: Data) throws -> LegacyJSONValue {
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
    return try JSONDecoder().decode(Self.self, from: data)
  }
  func data(escapingSlashes: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    if !escapingSlashes { encoder.outputFormatting = [.withoutEscapingSlashes] }
    return try encoder.encode(self)
  }
}

extension LegacyJSONValue {
  fileprivate var current: JSONValue {
    switch self {
    case .object(let object): .object(object.mapValues { $0.current })
    case .array(let array): .array(array.map { $0.current })
    case .string(let value): .string(value)
    case .number(let value): .number(value)
    case .bool(let value): .bool(value)
    case .null: .null
    }
  }
}

@Test func jsonOrderRetainsNestedReceivedOrderAndMutationPositions() throws {
  let raw =
    #"{"z":0,"a":{"y":1,"b":{"q":2,"c":3}},"tools":[{"parameters":{"properties":{"zeta":{},"alpha":{},"middle":{}}}}]}"#
  let value = try JSONValue.decode(Data(raw.utf8))
  #expect(try value.data() == Data(raw.utf8))
  var object = value.object!
  object["z"] = .number(4)
  object.removeValue(forKey: "a")
  object["new"] = .bool(true)
  #expect(
    try JSONValue.object(object).data()
      == Data(
        raw.replacingOccurrences(of: #""z":0,"a":{"y":1,"b":{"q":2,"c":3}},"#, with: #""z":4,"#)
          .dropLast().appending(#","new":true}"#).utf8))
  #expect(
    JSONValue.object(["z": .number(1), "a": .number(2)])
      == .object(["a": .number(2), "z": .number(1)]))
}

@Test func jsonOrderFilteringPreservesProviderErrorAndUsagePositions() throws {
  let raw =
    #"{"usage":{"output_tokens_details":{"reasoning_tokens":1},"output_tokens":3,"input_tokens_details":{"cache_write_tokens":1,"cached_tokens":0},"input_tokens":5},"error":{"message":"synthetic","private":"synthetic","type":"synthetic","code":"synthetic"}}"#
  let value = ProviderObservation.textOutput(try JSONValue.decode(Data(raw.utf8)))
  #expect(
    try value.data()
      == Data(raw.replacingOccurrences(of: #","private":"synthetic""#, with: "").utf8))
  let failure = GatewayProtocolError(400, "synthetic", providerError: value["error"])
  let envelope = protocolErrorEnvelope(failure, requestID: "synthetic", diagnostics: false)
  #expect(
    try envelope.data()
      == Data(
        #"{"error":{"message":"synthetic","type":"synthetic","code":"synthetic","request_id":"synthetic"}}"#
          .utf8))
}

@Test func jsonOrderDifferentialInputSemantics() throws {
  var corpus = [
    #"{"z":{"b":1,"a":2},"z":{"x":3},"a":4}"#,
    #"{"z":[{"b":1,"a":2}],"z":true}"#,
    #"{"z":null,"z":{"b":2}}"#,
    #"{"a":1,"\u0061":2}"#,
    #"{"é":{"z":1,"a":2},"e\u0301":{"x":3}}"#,
    #"{"\"":1,"\\":2,"\/":3,"\u0000":4,"😀":5}"#,
    #"{"\uD83D\uDE00":"\u2028\u2029","x":"合成/文本"}"#,
    #"[0,-0,1.25,1e30,1e-30,123456789012345678901234567890123456789,1e128,1e-129]"#,
    #"[true,false,null,"",{},[]]"#, #"{"a":1,}"#, "[1,]",
    "", " ", "{", "[", "01", "+1", "NaN", "1e9999", "1e-9999",
    #"{"a":undefined}"#, #"{"a":1}false"#, #"{"a" 1}"#, "[1,,2]",
    #""\uD800""#, #""\uDC00""#, #""\uD800x""#, #""\x00""#,
    "[/*synthetic*/1]", "true false", "\"\u{01}\"",
  ].map { Data($0.utf8) }
  for depth in [63, 64, 65, 100] {
    corpus.append(
      Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
    )
    corpus.append(
      Data(
        (String(repeating: #"{"z":"[\"","a":"#, count: depth) + "0"
          + String(repeating: "}", count: depth)).utf8))
  }
  let unicode = #"{"z":{"y":1,"a":2},"合成":"😀"}"#
  for encoding in [
    String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32, .utf32LittleEndian,
    .utf32BigEndian,
  ] {
    corpus.append(unicode.data(using: encoding)!)
  }
  corpus += [Data([0x22, 0xFF, 0x22]), Data([0xEF, 0xBB, 0xBF]) + Data(unicode.utf8)]
  for data in corpus {
    let before = Result { try LegacyJSONValue.decode(data) }
    let after = Result { try JSONValue.decode(data) }
    switch (before, after) {
    case (.success(let old), .success(let new)):
      #expect(old.current == new, "Differential semantic mismatch: \(data)")
      for escaping in [true, false] {
        #expect(try LegacyJSONValue.decode(new.data(escapingSlashes: escaping)) == old)
      }
    case (.failure(let old), .failure(let new)):
      if let old = old as? GatewayProtocolError {
        #expect((new as? GatewayProtocolError)?.code == old.code)
        #expect((new as? GatewayProtocolError)?.status == old.status)
      }
    default: Issue.record("Differential acceptance mismatch: \(data)")
    }
  }
  // Scalar escaping/Decimal output uses the previous byte representation in both modes.
  for raw in [#""a/b\\c\n\u0000\u001f\u2028😀""#, "1.2500", "-0", "1e30", "1e-30"] {
    let data = Data(raw.utf8)
    for escaping in [true, false] {
      #expect(
        try JSONValue.decode(data).data(escapingSlashes: escaping)
          == LegacyJSONValue.decode(data).data(escapingSlashes: escaping))
    }
  }
}

@Test func jsonOrderSyntheticMegabyteBenchmark() throws {
  let tool =
    #"{"type":"function","name":"synthetic","description":"PLACEHOLDER","parameters":{"type":"object","properties":{"zeta":{"type":"string"},"alpha":{"type":"integer"},"middle":{"type":"object","properties":{"z":{},"a":{}}}}}}"#
    .replacingOccurrences(of: "PLACEHOLDER", with: String(repeating: "x", count: 2400))
  let data = Data(
    (#"{"model":"synthetic","tools":["# + Array(repeating: tool, count: 400).joined(separator: ",")
      + "]}").utf8)
  func measure(_ operation: () throws -> Data) throws -> Double {
    _ = try operation()
    let start = ContinuousClock.now
    for _ in 0..<10 { _ = try operation() }
    let elapsed = start.duration(to: .now).components
    return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 10
  }
  let old = try measure { try LegacyJSONValue.decode(data).data() }
  let new = try measure { try JSONValue.decode(data).data() }
  print(
    "JSON_ORDER_BENCH bytes=\(data.count) tools=400 iterations=10 legacy_ms=\(old) ordered_ms=\(new)"
  )
}
