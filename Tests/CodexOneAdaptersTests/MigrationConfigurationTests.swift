import CodexOneCore
import Foundation
import NIOHTTP1
import Testing

@testable import CodexOneAdapters

@Test func nativeFingerprintSignalsAreExplicitAndCaseSensitive() {
  for prefix in [
    "codex_cli_rs", "codex-tui", "codex_exec", "codex_sdk_ts", "codex_vscode", "Codex Desktop",
    "Codex ",
  ] {
    #expect(ClientFingerprint.isNative(["USER-AGENT": prefix + "/synthetic"]))
    #expect(!ClientFingerprint.isNative(["user-agent": "proxy " + prefix]))
  }
  for originator in [
    "codex_cli_rs", "codex_vscode", "codex_sdk_ts", "codex_exec", "codex_chatgpt_desktop",
    "Codex Desktop",
  ] {
    #expect(ClientFingerprint.isNative(["Originator": originator]))
    #expect(!ClientFingerprint.isNative(["originator": originator + "-proxy"]))
  }
  for ua in ["", "Claude Code", "CODEX_CLI_RS/1", "codex desktop", "Codex"] {
    #expect(!ClientFingerprint.isNative(["user-agent": ua, "x-codex-turn-state": "synthetic"]))
  }
  let native: HTTPHeaders = [
    "user-agent": "Codex Desktop synthetic", "originator": "custom", "version": "original",
  ]
  let forwarded = forwardedClientHeaders(native)
  for name in ["user-agent", "originator", "version"] { #expect(forwarded[name] == native[name]) }
  let headers = forwardedClientHeaders([
    "x-codex-turn-state": "synthetic", "x-stainless-lang": "typescript",
    "x-openai-client-user-agent": "private", "cookie": "private", "proxy-authorization": "private",
  ])
  #expect(headers.first(name: "originator") == "codex_cli_rs")
  #expect(headers.first(name: "x-codex-turn-state") == "synthetic")
  for name in ["x-stainless-lang", "x-openai-client-user-agent", "cookie", "proxy-authorization"] {
    #expect(headers[name].isEmpty)
  }
}

@Test func migrationConfigurationBoundsInBothPrivateFormats() throws {
  let pool: [String: Any] = [
    "models": [["id": "synthetic", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0]],
    "reservedMicros": 1,
  ]
  let single = pool.merging([
    "principal": "p", "keyID": "k", "keySHA256": String(repeating: "a", count: 64),
    "namespace": "synthetic", "identity": "i", "upstreamBaseURL": "http://127.0.0.1:9/v1",
  ]) { a, _ in a }
  for (base, isPool) in [(pool, true), (single, false)] {
    func decode(_ fields: [String: Any]) throws -> ResponsesConfiguration {
      let data = try JSONSerialization.data(withJSONObject: fields)
      if isPool {
        return try JSONDecoder().decode(AccountPoolConfiguration.self, from: data).responses
      }
      let value = try JSONDecoder().decode(SingleIdentityConfiguration.self, from: data)
      try value.validate()
      return value.responses
    }
    let defaults = try decode(base)
    #expect(defaults.dataConnections == 128)
    #expect(
      defaults.clientFingerprint.userAgent
        == "codex_cli_rs/0.163.0 (Mac OS 26.5.0; arm64) iTerm.app/3.6.10")
    for count in [8, 128, 1024] {
      #expect(
        try decode(base.merging(["dataConnections": count]) { _, b in b }).dataConnections == count)
    }
    for count: Any in [0, 7, 1025, "128", 8.5] {
      #expect(throws: (any Error).self) {
        try decode(base.merging(["dataConnections": count]) { _, b in b })
      }
    }
    for field in ["version", "os", "arch", "terminal"] {
      for bad in ["", "bad\r\nheader", "bad\u{7f}", "非ASCII", String(repeating: "a", count: 129)] {
        #expect(throws: (any Error).self) {
          try decode(base.merging(["clientFingerprint": [field: bad]]) { _, b in b })
        }
      }
      let valid = try decode(
        base.merging(["clientFingerprint": [field: String(repeating: "a", count: 128)]]) { _, b in b
        })
      #expect(valid.clientFingerprint.version != nil)
    }
  }
  var model = SingleIdentityConfiguration.Model(
    id: "synthetic", inputMicrosPerMillion: 0, outputMicrosPerMillion: 0)
  model.profileProvenance = .init(
    source: "synthetic", revision: "v1", capturedAtUnixSeconds: 1,
    clientVersions: ["0.9.0", "0.163.0", "0.99.0"], sha256: "synthetic", overridden: false)
  #expect(ClientFingerprint().resolved(models: [model]).version == "0.163.0")
  #expect(ClientFingerprint(version: "custom").resolved(models: [model]).version == "custom")
}
