import Foundation

/// Restore order only after Foundation has accepted the document and chosen all semantic values.
/// This scanner never makes validity, duplicate-value or number-conversion decisions.
struct JSONOrderScanner {
  private let bytes: [UInt8]
  private var index = 0
  private let decoder = JSONDecoder()

  init(_ data: Data) {
    // JSONDecoder accepts UTF-8/16/32, with or without a BOM. Normalize only this order scan.
    let prefix = Array(data.prefix(4))
    let encoding: String.Encoding?
    if prefix.starts(with: [0, 0, 254, 255]) || prefix.starts(with: [0, 0, 0]) {
      encoding = .utf32BigEndian
    } else if prefix.starts(with: [255, 254, 0, 0])
      || (prefix.count == 4 && prefix[1...3].allSatisfy({ $0 == 0 }))
    {
      encoding = .utf32LittleEndian
    } else if prefix.starts(with: [254, 255]) || prefix.first == 0 {
      encoding = .utf16BigEndian
    } else if prefix.starts(with: [255, 254]) || (prefix.count >= 2 && prefix[1] == 0) {
      encoding = .utf16LittleEndian
    } else {
      encoding = nil
    }
    var normalized =
      encoding.flatMap { String(data: data, encoding: $0).map { Array($0.utf8) } } ?? Array(data)
    if normalized.starts(with: [239, 187, 191]) { normalized.removeFirst(3) }
    bytes = normalized
  }

  private mutating func whitespace() {
    while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
  private mutating func string(decode: Bool = true) throws -> String {
    let start = index
    index += 1
    var escaped = false
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte == 92 {
        escaped = true
        index += 1
      } else if byte == 34 {
        break
      }
    }
    guard decode else { return "" }
    if !escaped { return String(decoding: bytes[(start + 1)..<(index - 1)], as: UTF8.self) }
    return try decoder.decode(String.self, from: Data(bytes[start..<index]))
  }

  mutating func restore(_ value: JSONValue?) throws -> JSONValue {
    whitespace()
    guard index < bytes.count else { return value ?? .null }
    if bytes[index] == 123 {
      index += 1
      var object: JSONObject = [:]
      whitespace()
      while index < bytes.count && bytes[index] != 125 {
        let key = try string()
        whitespace()
        index += 1  // colon (the complete document was already validated)
        // Foundation resolves duplicates to the first member; later occurrences are scanned only.
        let member = try restore(object[key] == nil ? value?[key] : nil)
        if object[key] == nil { object[key] = member }
        whitespace()
        if index < bytes.count && bytes[index] == 44 {
          index += 1
          whitespace()
        }
      }
      index += 1
      return value == nil ? .null : .object(object)
    }
    if bytes[index] == 91 {
      index += 1
      var array: [JSONValue] = []
      whitespace()
      while index < bytes.count && bytes[index] != 93 {
        let position = array.count
        let reference = value?.array
        array.append(try restore(reference.flatMap { position < $0.count ? $0[position] : nil }))
        whitespace()
        if index < bytes.count && bytes[index] == 44 {
          index += 1
          whitespace()
        }
      }
      index += 1
      return value == nil ? .null : .array(array)
    }
    if bytes[index] == 34 {
      _ = try string(decode: false)
    } else {
      while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
        index += 1
      }
    }
    return value ?? .null
  }
}
