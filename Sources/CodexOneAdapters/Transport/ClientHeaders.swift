import Foundation
import NIOHTTP1

/// Client metadata only; credentials, routing and arbitrary internal headers never cross.
func forwardedClientHeaders(
  _ headers: HTTPHeaders, fingerprint: ClientFingerprint = .init().resolved(models: []),
  registry: ClientProtocolExtensionRegistry? = nil
) throws -> HTTPHeaders {
  let turnState = try requestTurnState(headers: headers)
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
  // Reserve a slot before optional extension headers consume the shared limit.
  if let turnState { result.add(name: "x-codex-turn-state", value: turnState) }
  var codexCount = turnState == nil ? 0 : 1
  for header in headers
  where
    (allowed.contains(header.name.lowercased()) || header.name.lowercased().hasPrefix("x-codex-"))
    && !connectionHeaders.contains(header.name.lowercased())
    && header.name.lowercased() != "x-codex-turn-state"
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

/// Return only validated routing and requested model metadata.
func forwardedResponseHeaders(_ headers: HTTPHeaders, includeModel: Bool = false) -> HTTPHeaders {
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
  let models = headers["openai-model"]
  if includeModel, !connection.contains("openai-model"), models.count == 1,
    let model = models.first, (1...128).contains(model.utf8.count),
    model.utf8.allSatisfy({
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [45, 46, 95].contains($0)
    })
  {
    result.add(name: "openai-model", value: model)
  }
  return result
}
