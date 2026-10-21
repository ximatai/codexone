import CodexOneCore
import Foundation
import ServiceLifecycle
import Synchronization

/// One supervised worker; tickets account for active executions, queued work and the current write.
public final class ExecutionFinalizer: Service, FinalizationSink, Sendable {
  private enum TicketState { case reserved, queued }
  private struct State {
    var accepting = false
    var started = false
    var failed = false
    var tickets: [UUID: TicketState] = [:]
  }
  private struct Item: Sendable {
    let ticket: UUID
    let finalization: Finalization
  }
  private let state = Mutex(State())
  private let stream: AsyncStream<Item>
  private let continuation: AsyncStream<Item>.Continuation
  private let store: any ExecutionStore
  private let capacity: Int

  public init(store: any ExecutionStore, capacity: Int = 16) throws {
    guard (1...16).contains(capacity) else { throw ExecutionError.invalidCommand }
    self.store = store
    self.capacity = capacity
    let pair = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    stream = pair.stream
    continuation = pair.continuation
  }
  public var isAccepting: Bool { state.withLock { $0.accepting } }
  public var hasFailed: Bool { state.withLock { $0.failed } }
  public var outstanding: Int { state.withLock { $0.tickets.count } }

  public func reserve() throws -> UUID {
    try state.withLock { value in
      guard value.accepting, value.tickets.count < capacity else { throw ExecutionError.capacity }
      let ticket = UUID()
      value.tickets[ticket] = .reserved
      return ticket
    }
  }
  public func canExecute(_ ticket: UUID) -> Bool {
    state.withLock { $0.accepting && !$0.failed && $0.tickets[ticket] == .reserved }
  }
  public func abandon(_ ticket: UUID) {
    let finished = state.withLock { value in
      guard value.tickets[ticket] == .reserved else { return false }
      value.tickets.removeValue(forKey: ticket)
      return !value.accepting && value.tickets.isEmpty
    }
    if finished { continuation.finish() }
  }
  public func handoff(_ ticket: UUID, finalization: Finalization) {
    // Queue while holding the gate: shutdown cannot finish the stream between ownership transfer and yield.
    state.withLock { value in
      guard value.tickets[ticket] == .reserved else { return }
      value.tickets[ticket] = .queued
      switch continuation.yield(.init(ticket: ticket, finalization: finalization)) {
      case .enqueued: break
      default:
        value.failed = true
        value.accepting = false
      }
    }
  }
  public func stopAccepting() {
    let finished = state.withLock { value in
      value.accepting = false
      return value.tickets.isEmpty
    }
    if finished { continuation.finish() }
  }
  public func run() async throws {
    try state.withLock { value in
      guard !value.started else { throw ExecutionError.conflict }
      value.started = true
      value.accepting = true
    }
    defer {
      state.withLock {
        $0.accepting = false
        $0.tickets.removeAll()
      }
      continuation.finish()
    }
    try await withGracefulShutdownHandler {
      for await item in stream {
        do {
          try await store.finalize(
            attempt: item.finalization.attempt, evidence: item.finalization.evidence)
        } catch {
          // Durable intent is the recovery record; never depend on writing another pending marker.
          state.withLock {
            $0.failed = true
            $0.accepting = false
          }
          throw ExecutionError.storageUnavailable
        }
        let finished = state.withLock { value in
          value.tickets.removeValue(forKey: item.ticket)
          return !value.accepting && value.tickets.isEmpty
        }
        if finished { continuation.finish() }
      }
    } onGracefulShutdown: {
      self.stopAccepting()
    }
  }
}
