import Foundation
import NIOCore
import Synchronization

/// One monitor per inbound request. Expiry finishes the reader, leaving output open for JSON.
/// A locked completion barrier prevents a buffered end racing expiry from reaching admission.
final class HTTPRequestReadDeadline: Sendable {
  private struct State {
    var active = true
    var expired = false
    var lastProgress = ContinuousClock.now
  }
  private final class Storage: Sendable {
    let value = Mutex(State())
  }
  private let state: Storage
  private let monitor: RepeatedTask

  init(channel: any Channel) {
    let state = Storage()
    self.state = state
    let total = ContinuousClock.now.advanced(by: .seconds(120))
    monitor = channel.eventLoop.scheduleRepeatedTask(
      initialDelay: .milliseconds(100), delay: .milliseconds(100)
    ) { task in
      let expired = state.value.withLock { value in
        guard value.active,
          ContinuousClock.now >= total
            || ContinuousClock.now >= value.lastProgress.advanced(by: .seconds(10))
        else { return false }
        value.active = false
        value.expired = true
        return true
      }
      if expired {
        task.cancel()
        channel.pipeline.fireErrorCaught(GatewayProtocolError(408, "request_body_timeout"))
      }
    }
  }

  func note() { state.value.withLock { if $0.active { $0.lastProgress = .now } } }

  func complete() throws {
    let expired = state.value.withLock { value in
      value.active = false
      return value.expired
    }
    monitor.cancel()
    if expired { throw GatewayProtocolError(408, "request_body_timeout") }
  }

  func cancel() {
    state.value.withLock { $0.active = false }
    monitor.cancel()
  }
}
