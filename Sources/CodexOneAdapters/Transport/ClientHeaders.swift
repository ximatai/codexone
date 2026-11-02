import Foundation
import NIOHTTP1

/// Client metadata only; credentials, routing and arbitrary internal headers never cross.
func forwardedClientHeaders(
  _ headers: HTTPHeaders, fingerprint: ClientFingerprint = .init().resolved(models: []),
  registry: ClientProtocolExtensionRegistry? = nil
) -> HTTPHeaders {
  let allowed: Set<String> = [
    "user-agent", "originator", "version", "session_id", "x-codex-turn-metadata",
    "x-codex-beta-features", "x-codex-window-id", "x-codex-parent-thread-id",
    "x-codex-image-turn-id", "x-codex-turn-state", "x-session-id", "conversation_id",
    "x-conversation-id", "session-id", "thread-id", "openai-beta",
    "x-openai-subagent", "x-openai-memgen-request",
  ]
  let connectionHeaders = Set(
    headers["connection"].flatMap {
      $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    })
  var result = HTTPHeaders()
  var codexCount = 0
  for header in headers
  where
    (allowed.contains(header.name.lowercased()) || header.name.lowercased().hasPrefix("x-codex-"))
    && !connectionHeaders.contains(header.name.lowercased())
  {
    guard header.value.utf8.count <= 8192 else { continue }
    if header.name.lowercased().hasPrefix("x-codex-") {
      guard codexCount < 32 else { continue }
      codexCount += 1
      if !allowed.contains(header.name.lowercased()) {
        registry?.record(name: header.name.lowercased())
        ClientProtocolDiagnostics.record(
          name: header.name.lowercased(), outcome: "forwarded", headers: headers)
      }
    }
    result.add(name: header.name, value: header.value)
  }
  if !ClientFingerprint.isNative(headers) {
    for name in ["user-agent", "originator", "version"] { result.remove(name: name) }
    result.add(name: "user-agent", value: fingerprint.userAgent)
    result.add(name: "originator", value: "codex_cli_rs")
    result.add(name: "version", value: fingerprint.version!)
  }
  return result
}

/// Return only routing metadata; provider credentials and arbitrary headers stay private.
func forwardedResponseHeaders(_ headers: HTTPHeaders) -> HTTPHeaders {
  let connection = Set(
    headers["connection"].flatMap {
      $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    })
  var result = HTTPHeaders()
  if !connection.contains("x-codex-turn-state"),
    let value = headers.first(name: "x-codex-turn-state"), validTurnState(value)
  {
    result.add(name: "x-codex-turn-state", value: value)
  }
  return result
}
