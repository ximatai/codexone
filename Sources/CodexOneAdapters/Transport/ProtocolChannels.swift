import CodexOneCore
import NIOCore
import Synchronization

/// Own accepted and connecting sockets even before protocol negotiation yields an async channel.
final class ProtocolChannels: Sendable {
  private struct State {
    var channels: [ObjectIdentifier: any Channel] = [:]
    var draining = false
  }
  private let state = Mutex(State())
  private let limit: Int
  init(limit: Int) { self.limit = limit }

  func register(_ channel: any Channel) -> Bool {
    let id = ObjectIdentifier(channel)
    let accepted = state.withLock { value in
      guard !value.draining, value.channels.count < limit else { return false }
      value.channels[id] = channel
      return true
    }
    if accepted {
      channel.closeFuture.whenComplete { _ in
        self.state.withLock { _ = $0.channels.removeValue(forKey: id) }
      }
    }
    return accepted
  }

  func close() {
    let channels = state.withLock { value in
      value.draining = true
      return Array(value.channels.values)
    }
    for channel in channels { channel.close(promise: nil) }
  }

  func shutdown() async {
    let channels = state.withLock { value in
      value.draining = true
      return Array(value.channels.values)
    }
    for channel in channels { channel.close(promise: nil) }
    for channel in channels { try? await channel.closeFuture.get() }
  }
}
