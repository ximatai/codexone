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
    var receivedBytes = 0
    var expiry: Expiry?
  }
  struct Expiry: Sendable {
    let reason: String
    let receivedBytes: Int
    let elapsed: Duration
    let idle: Duration
  }
  private final class Storage: Sendable {
    let value = Mutex(State())
  }
  private let state: Storage
  private let monitor: RepeatedTask

  init(channel: any Channel) {
    let state = Storage()
    self.state = state
    let started = ContinuousClock.now
    let total = started.advanced(by: .seconds(120))
    monitor = channel.eventLoop.scheduleRepeatedTask(
      initialDelay: .milliseconds(100), delay: .milliseconds(100)
    ) { task in
      let expired = state.value.withLock { value in
        guard value.active,
          ContinuousClock.now >= total
            || ContinuousClock.now >= value.lastProgress.advanced(by: .seconds(10))
        else { return false }
        let now = ContinuousClock.now
        value.expiry = Expiry(
          reason: now >= total ? "total" : "idle", receivedBytes: value.receivedBytes,
          elapsed: started.duration(to: now), idle: value.lastProgress.duration(to: now))
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

  func note(bytes: Int = 0) {
    state.value.withLock {
      guard $0.active else { return }
      $0.lastProgress = .now
      $0.receivedBytes += min(max(0, bytes), Int.max - $0.receivedBytes)
    }
  }

  var expiry: Expiry? { state.value.withLock { $0.expiry } }

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
