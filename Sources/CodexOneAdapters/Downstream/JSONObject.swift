import Foundation

/// Wire objects iterate in insertion order; replacing a value does not move its key.
/// Equality deliberately retains Dictionary's order-insensitive semantics.
struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral,
  RandomAccessCollection
{
  typealias Element = (key: String, value: JSONValue)
  private var names: [String] = []
  private var members: [String: JSONValue] = [:]

  init(dictionaryLiteral elements: (String, JSONValue)...) {
    for (key, value) in elements { self[key] = value }
  }
  /// Unordered, locally generated maps have no received order: use a deterministic fallback.
  init(_ dictionary: [String: JSONValue]) {
    for key in dictionary.keys.sorted() { self[key] = dictionary[key] }
  }
  var startIndex: Int { names.startIndex }
  var endIndex: Int { names.endIndex }
  subscript(position: Int) -> Element { (names[position], members[names[position]]!) }
  subscript(key: String) -> JSONValue? {
    get { members[key] }
    set {
      if let newValue {
        if members[key] == nil { names.append(key) }
        members[key] = newValue
      } else {
        _ = removeValue(forKey: key)
      }
    }
  }
  var keys: [String] { names }
  var values: [JSONValue] { names.map { members[$0]! } }
  @discardableResult mutating func removeValue(forKey key: String) -> JSONValue? {
    guard let old = members.removeValue(forKey: key) else { return nil }
    names.removeAll { $0 == key }
    return old
  }
  func filter(_ isIncluded: (Element) throws -> Bool) rethrows -> JSONObject {
    var result: JSONObject = [:]
    for entry in self where try isIncluded(entry) { result[entry.key] = entry.value }
    return result
  }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.members == rhs.members }
}
