import Foundation
import Testing

@testable import CodexOneAdapters

@Test func explicitUpstreamProxyRejectsCredentialsAndRoutingOverrides() throws {
  for value in ["http://127.0.0.1:7890", "http://proxy.example:8080/", "http://[::1]:7890"] {
    let proxy = try UpstreamHTTPProxy(url: value)
    #expect(proxy.description == "UpstreamHTTPProxy(redacted)")
    #expect(proxy.debugDescription == proxy.description)
  }
  for value in [
    "", "http://proxy.example", "https://proxy.example:8080", "socks5://proxy.example:7890",
    "http://user:synthetic-secret@proxy.example:8080", "http://proxy.example:0",
    "http://proxy.example:65536", "http://proxy.example:80/path",
    "http://proxy.example:80?secret=x",
    "http://proxy.example:80#secret", "http://proxy.example:80\u{0}",
  ] {
    #expect(throws: (any Error).self) { try UpstreamHTTPProxy(url: value) }
  }
}
