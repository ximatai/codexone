import Foundation

struct ImagePart {
  let name: String
  let contentType: String?
  let data: Data
}
/// Strict, bounded multipart parser. No nested bodies, transfer encodings or duplicate headers.
func imageMultipart(_ data: Data, contentType: String) throws -> [ImagePart] {
  let parameters = contentType.split(separator: ";", omittingEmptySubsequences: false).map {
    $0.trimmingCharacters(in: .whitespaces)
  }
  guard parameters.count == 2, parameters[0].lowercased() == "multipart/form-data",
    parameters[1].hasPrefix("boundary=")
  else { throw GatewayProtocolError(400, "invalid_multipart") }
  var boundary = String(parameters[1].dropFirst(9))
  if boundary.hasPrefix("\""), boundary.hasSuffix("\"") {
    boundary = String(boundary.dropFirst().dropLast())
  }
  guard (1...70).contains(boundary.utf8.count),
    boundary.utf8.allSatisfy({
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [39, 40, 41, 43, 95, 44, 45, 46, 47, 58, 61, 63].contains($0)
    })
  else { throw GatewayProtocolError(400, "invalid_multipart") }
  let first = Data(("--" + boundary + "\r\n").utf8)
  let delimiter = Data(("\r\n--" + boundary).utf8)
  guard data.starts(with: first) else { throw GatewayProtocolError(400, "invalid_multipart") }
  var offset = first.count
  var result: [ImagePart] = []
  while offset < data.count {
    guard result.count < 24,
      let end = data.range(of: Data("\r\n\r\n".utf8), in: offset..<data.count),
      end.lowerBound - offset <= 4096,
      let header = String(data: data[offset..<end.lowerBound], encoding: .utf8)
    else { throw GatewayProtocolError(400, "invalid_multipart") }
    var headers: [String: String] = [:]
    for line in header.components(separatedBy: "\r\n") {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw GatewayProtocolError(400, "invalid_multipart") }
      let key = parts[0].lowercased()
      guard ["content-disposition", "content-type"].contains(key), headers[key] == nil else {
        throw GatewayProtocolError(400, "invalid_multipart")
      }
      headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    let disposition = (headers["content-disposition"] ?? "").components(separatedBy: ";").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard disposition.first == "form-data", (2...3).contains(disposition.count) else {
      throw GatewayProtocolError(400, "invalid_multipart")
    }
    var attrs: [String: String] = [:]
    for entry in disposition.dropFirst() {
      let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, ["name", "filename"].contains(String(parts[0])),
        attrs[String(parts[0])] == nil,
        parts[1].hasPrefix("\""), parts[1].hasSuffix("\"")
      else { throw GatewayProtocolError(400, "invalid_multipart") }
      let value = String(parts[1].dropFirst().dropLast())
      guard !value.contains("\""), !value.contains("\r"), !value.contains("\n") else {
        throw GatewayProtocolError(400, "invalid_multipart")
      }
      attrs[String(parts[0])] = value
    }
    let start = end.upperBound
    guard let name = attrs["name"], !name.isEmpty,
      let next = data.range(of: delimiter, in: start..<data.count)
    else { throw GatewayProtocolError(400, "invalid_multipart") }
    result.append(
      .init(
        name: name, contentType: headers["content-type"], data: Data(data[start..<next.lowerBound]))
    )
    offset = next.upperBound
    if data[offset...].starts(with: Data("--".utf8)) {
      offset += 2
      guard offset == data.count || Data(data[offset...]) == Data("\r\n".utf8) else {
        throw GatewayProtocolError(400, "invalid_multipart")
      }
      return result
    }
    guard data[offset...].starts(with: Data("\r\n".utf8)) else {
      throw GatewayProtocolError(400, "invalid_multipart")
    }
    offset += 2
  }
  throw GatewayProtocolError(400, "invalid_multipart")
}
