import CodexOneCore
import Crypto
import Foundation
import NIOHTTP1
import Synchronization

/// Soft routing only. Key-scoped digests, one-hour TTL, at most 1024 labels per service.
final class ControlAffinity: Sendable {
  private struct Entry {
    let account: AccountRouteIdentity
    let at: ContinuousClock.Instant
  }
  private let entries = Mutex<[String: Entry]>([:])
  private func labels(key: String, headers: HTTPHeaders) -> [String] {
    ["x-codex-turn-state", "session_id", "x-session-id", "conversation_id", "x-conversation-id"]
      .compactMap { name in
        guard let value = headers.first(name: name), !value.isEmpty, value.utf8.count <= 8192 else {
          return nil
        }
        return SHA256.hash(data: Data((key + "\0" + name + "\0" + value).utf8))
          .map { String(format: "%02x", $0) }.joined()
      }
  }
  func preferred(key: String, headers: HTTPHeaders) -> AccountRouteIdentity? {
    let labels = labels(key: key, headers: headers)
    return entries.withLock { entries in
      entries = entries.filter { $0.value.at.duration(to: .now) < .seconds(3600) }
      return labels.compactMap { entries[$0]?.account }.first
    }
  }
  func observe(key: String, headers: HTTPHeaders, account: AccountRouteIdentity) {
    let labels = labels(key: key, headers: headers)
    entries.withLock { entries in
      for label in labels {
        if entries.count >= 1024, entries[label] == nil,
          let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key
        {
          entries.removeValue(forKey: oldest)
        }
        entries[label] = Entry(account: account, at: .now)
      }
    }
  }
}
