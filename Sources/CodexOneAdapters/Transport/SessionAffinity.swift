import CodexOneCore
import Crypto
import Foundation
import NIOHTTP1
import Synchronization

/// Soft routing only. Key-scoped digests, one-hour TTL, at most 1024 labels per service.
final class SessionAffinity: Sendable {
  private struct Entry {
    let account: AccountRouteIdentity
    let at: ContinuousClock.Instant
  }
  private let now: @Sendable () -> ContinuousClock.Instant
  init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) { self.now = now }
  private let entries = Mutex<[String: Entry]>([:])
  private func labels(key: String, headers: HTTPHeaders) -> [(id: String, isThread: Bool)] {
    [
      "thread-id", "session-id", "session_id", "x-session-id",
      "conversation_id", "x-conversation-id",
    ]
    .compactMap { name in
      guard let value = headers.first(name: name), !value.isEmpty, value.utf8.count <= 8192 else {
        return nil
      }
      let id = SHA256.hash(data: Data((key + "\0" + name + "\0" + value).utf8))
        .map { String(format: "%02x", $0) }.joined()
      return (id, name == "thread-id")
    }
  }
  func preferred(key: String, headers: HTTPHeaders) -> AccountRouteIdentity? {
    let labels = labels(key: key, headers: headers)
    return entries.withLock { entries in
      entries = entries.filter { $0.value.at.duration(to: now()) < .seconds(3600) }
      return labels.compactMap { entries[$0.id]?.account }.first
    }
  }
  func observe(
    key: String, headers: HTTPHeaders, account: AccountRouteIdentity
  ) {
    let labels = labels(key: key, headers: headers)
    entries.withLock { entries in
      entries = entries.filter { $0.value.at.duration(to: now()) < .seconds(3600) }
      for (label, isThread) in labels {
        guard isThread || entries[label] == nil else { continue }
        if entries.count >= 1024, entries[label] == nil,
          let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key
        {
          entries.removeValue(forKey: oldest)
        }
        entries[label] = Entry(account: account, at: now())
      }
    }
  }
}
