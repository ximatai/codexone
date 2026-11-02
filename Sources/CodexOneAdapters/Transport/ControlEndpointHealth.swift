import CodexOneCore
import Synchronization

/// Service-owned endpoint cooldowns. No timers, credentials or request bodies; restart clears them.
final class ControlEndpointHealth: Sendable {
  private struct Key: Hashable {
    let route: String
    let account: AccountRouteIdentity
  }
  private let values = Mutex<[Key: ContinuousClock.Instant]>([:])
  private let now: @Sendable () -> ContinuousClock.Instant
  init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) { self.now = now }
  func cooldowns(route: String) -> [AccountRouteIdentity: Double] {
    values.withLock { values in
      values = values.filter { $0.value > now() }
      return Dictionary(
        uniqueKeysWithValues: values.filter { $0.key.route == route }.map {
          let duration = now().duration(to: $0.value).components
          return ($0.key.account, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        })
    }
  }
  func record(route: String, account: AccountRouteIdentity, seconds: Int64?) {
    values.withLock { values in
      values = values.filter { $0.value > now() }
      let key = Key(route: route, account: account)
      let until = now().advanced(by: .seconds(min(3600, max(1, seconds ?? 15))))
      if values.count >= 1024, values[key] == nil,
        let first = values.min(by: { $0.value < $1.value })?.key
      {
        values.removeValue(forKey: first)
      }
      values[key] = max(values[key] ?? until, until)
    }
  }
}
