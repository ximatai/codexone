import CodexOneCore
import Crypto
import Foundation
import NIOHTTP1
import Synchronization

func validTurnState(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 8192
    && value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
}

/// Transport metadata is routing evidence, never object authorization.
func requestTurnState(headers: HTTPHeaders, document: JSONValue? = nil) throws -> String? {
  let values = headers["x-codex-turn-state"]
  guard values.count <= 1 else { throw GatewayProtocolError(400, "conflicting_turn_state") }
  func token(_ value: JSONValue?) throws -> String? {
    guard let value, value != .null else { return nil }
    guard let string = value.string, validTurnState(string)
    else { throw GatewayProtocolError(400, "invalid_turn_state") }
    return string
  }
  let header = try token(values.first.map(JSONValue.string))
  if header != nil,
    headers["connection"].contains(where: {
      $0.lowercased().split(separator: ",").contains {
        $0.trimmingCharacters(in: .whitespaces) == "x-codex-turn-state"
      }
    })
  {
    throw GatewayProtocolError(400, "invalid_turn_state")
  }
  if header != nil, let metadata = document?["client_metadata"], metadata != .null,
    metadata.object == nil
  {
    throw GatewayProtocolError(400, "invalid_client_metadata")
  }
  let message = try token(document?["client_metadata"]?["x-codex-turn-state"])
  guard header == nil || message == nil || header == message else {
    throw GatewayProtocolError(400, "conflicting_turn_state")
  }
  return message ?? header
}

/// Only known metadata events can supply a state; other fields stay opaque to routing.
func responseMetadataTurnState(_ event: JSONValue) -> String? {
  guard ["response.metadata", "codex.response.metadata"].contains(event["type"]?.string ?? ""),
    let fields = event["headers"]?.object
  else { return nil }
  let tokens = fields.filter { $0.key.lowercased() == "x-codex-turn-state" }
  guard tokens.count == 1, let token = tokens.first?.value.string, validTurnState(token) else {
    return nil
  }
  return token
}

/// Key-scoped source records, independently bounded from soft session locality.
final class TurnStateOwners: Sendable {
  private struct Entry {
    let account: AccountRouteIdentity?
    let at: ContinuousClock.Instant
  }
  private let entries = Mutex<[String: Entry]>([:])
  private let now: @Sendable () -> ContinuousClock.Instant
  init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) { self.now = now }
  private func digest(key: String, token: String) -> String {
    SHA256.hash(data: Data((key + "\0" + token).utf8)).map { String(format: "%02x", $0) }.joined()
  }
  func owner(key: String, token: String) throws -> AccountRouteIdentity {
    try entries.withLock { entries in
      entries = entries.filter { $0.value.at.duration(to: now()) < .seconds(3600) }
      guard let account = entries[digest(key: key, token: token)]?.account else {
        throw GatewayProtocolError(503, "continuation_owner_unavailable")
      }
      return account
    }
  }
  func observe(key: String, token: String, account: AccountRouteIdentity) {
    entries.withLock { entries in
      entries = entries.filter { $0.value.at.duration(to: now()) < .seconds(3600) }
      let label = digest(key: key, token: token)
      if let existing = entries[label] {
        entries[label] = Entry(account: existing.account == account ? account : nil, at: now())
      } else {
        if entries.count >= 1024, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
          entries.removeValue(forKey: oldest)
        }
        entries[label] = Entry(account: account, at: now())
      }
    }
  }
}
