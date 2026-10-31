import Foundation
import NIOHTTP1
import Testing

@testable import CodexOneAdapters

@Test func protocolExtensionNamesAreBoundedAndDeduplicated() {
  let registry = ClientProtocolExtensionRegistry()
  registry.record(name: "response.new", atUnixSeconds: 10)
  registry.record(name: "response.new", atUnixSeconds: 20)
  for name in ["", "bad\nname", "非ASCII", String(repeating: "x", count: 129)] {
    registry.record(name: name)
  }
  #expect(registry.snapshot().entries.count == 1)
  #expect(registry.snapshot().entries.first?.firstSeenUnixSeconds == 10)
  for index in 0..<31 { registry.record(name: "extension.\(index)", atUnixSeconds: 30) }
  #expect(!registry.snapshot().overflow)
  registry.record(name: "overflow")
  #expect(registry.snapshot().entries.count == 32)
  #expect(registry.snapshot().overflow)
  #expect(ClientProtocolExtensionRegistry().snapshot().entries.isEmpty)
}

@Test func protocolHeaderCollectionRetainsOnlyNames() {
  let registry = ClientProtocolExtensionRegistry()
  _ = forwardedClientHeaders(
    HTTPHeaders([
      ("x-codex-new-feature", "synthetic-private-value"),
      ("authorization", "synthetic-private-secret"),
      ("x-codex-turn-state", "known-value"),
    ]), registry: registry)
  #expect(registry.snapshot().entries.map(\.name) == ["x-codex-new-feature"])
  #expect(!String(describing: registry.snapshot()).contains("private"))
}

@Test func protocolCollectionIsConcurrencySafe() async {
  let registry = ClientProtocolExtensionRegistry()
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<100 {
      group.addTask { registry.record(name: "response.concurrent", atUnixSeconds: 1) }
    }
  }
  #expect(registry.snapshot().entries.count == 1)
}
