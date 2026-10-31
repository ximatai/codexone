import NIOHTTP1
import Testing

@testable import CodexOneAdapters

/// Codex Desktop custom providers set `x-openai-actor-authorization` only to unlock local tools.
/// It is a client-side gate marker, never a provider credential, so it must not cross upstream.
@Test func clientGateAndCredentialHeadersNeverCrossUpstream() {
  let forwarded = forwardedClientHeaders([
    "user-agent": "synthetic-desktop",
    "originator": "synthetic-originator",
    "x-codex-image-turn-id": "synthetic-turn",
    "x-openai-actor-authorization": "synthetic-gate",
    "X-OpenAI-Actor-Authorization": "synthetic-gate-mixed-case",
    "authorization": "Bearer synthetic-key",
    "chatgpt-account-id": "forged-downstream-account",
    "x-client-private": "synthetic-client-header",
  ])
  #expect(
    forwarded.first(name: "user-agent")
      == "codex_cli_rs/0.163.0 (Mac OS 26.5.0; arm64) iTerm.app/3.6.10")
  #expect(forwarded.first(name: "originator") == "codex_cli_rs")
  #expect(forwarded.first(name: "x-codex-image-turn-id") == "synthetic-turn")
  for name in [
    "x-openai-actor-authorization", "authorization", "chatgpt-account-id", "x-client-private",
  ] {
    #expect(forwarded[name].isEmpty, "\(name) must not be forwarded")
  }
}
