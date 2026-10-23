import AsyncHTTPClient
import CodexOneCore
import Foundation

/// Trusted process configuration only. Never accepted from a downstream request.
public struct UpstreamHTTPProxy: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let host: String
  let port: Int
  public var description: String { "UpstreamHTTPProxy(redacted)" }
  public var debugDescription: String { description }

  public init(url: String) throws {
    guard url.utf8.count <= 2048, !url.utf8.contains(0),
      let parts = URLComponents(string: url), parts.scheme == "http",
      let host = parts.host, !host.isEmpty, let port = parts.port, (1...65535).contains(port),
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      ["", "/"].contains(parts.path), !host.contains("%"),
      host.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
    else { throw ExecutionError.invalidCommand }
    self.host =
      host.hasPrefix("[") && host.hasSuffix("]")
      ? String(host.dropFirst().dropLast()) : host
    self.port = port
  }

  var clientProxy: HTTPClient.Configuration.Proxy { .server(host: host, port: port) }
}
