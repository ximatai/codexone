import CodexOneCore
import Foundation
import Synchronization

let testUnixSeconds: Int64 = 1_800_000_000
let testClock = WallClock { TimeInterval(testUnixSeconds) }

/// Each test owns its mutable time; advancing never waits for the host clock.
final class TestWallClock: Sendable {
  private let time: Mutex<TimeInterval>
  init(_ seconds: Int64 = testUnixSeconds) { time = Mutex(TimeInterval(seconds)) }
  var clock: WallClock { WallClock { self.time.withLock { $0 } } }
  func advance(seconds: Int64) { time.withLock { $0 += TimeInterval(seconds) } }
}
