import Foundation
import Synchronization

/// A pinned socket cannot accept more turns after one of its requests is force-stopped.
public final class AccountExecutionConnection: Sendable {
  private let retired = Mutex(false)
  public init() {}
  public var isRetired: Bool { retired.withLock { $0 } }
  fileprivate func retire() { retired.withLock { $0 = true } }
}

/// One owned request. The caller always joins the work and releases its registration.
public final class AccountExecution: Sendable {
  fileprivate let id = UUID()
  private let state = Mutex(
    (forced: false, finished: false, cancel: (@Sendable () -> Void)?.none))

  public let connection: AccountExecutionConnection?

  public init(connection: AccountExecutionConnection? = nil) {
    self.connection = connection
  }
  public var wasForced: Bool { state.withLock { $0.forced } }

  fileprivate func prepareCancellation() -> (@Sendable () -> Void)? {
    state.withLock { value in
      guard !value.forced, !value.finished else { return nil }
      connection?.retire()
      value.forced = true
      return value.cancel ?? {}
    }
  }

  fileprivate func finish() {
    state.withLock { $0.finished = true }
  }

  public func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let task = Task {
      guard !wasForced else { throw AccountExecutionStopped() }
      try Task.checkCancellation()
      return try await operation()
    }
    let alreadyForced = state.withLock { value in
      value.cancel = { task.cancel() }
      return value.forced
    }
    if alreadyForced { task.cancel() }
    defer { state.withLock { $0.cancel = nil } }
    do {
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      if wasForced { throw AccountExecutionStopped() }
      throw error
    }
  }
}

public struct AccountExecutionStopped: Error, Sendable {
  public init() {}
}

/// Entries are bounded by existing durable admission tickets and auxiliary request permits.
public final class AccountExecutions: Sendable {
  private let entries = Mutex([String: [UUID: AccountExecution]]())

  public init() {}

  public func register(_ execution: AccountExecution, account: String) {
    entries.withLock { $0[account, default: [:]][execution.id] = execution }
  }

  public func finish(_ execution: AccountExecution, account: String) {
    entries.withLock {
      execution.finish()
      $0[account]?.removeValue(forKey: execution.id)
      if $0[account]?.isEmpty == true { $0.removeValue(forKey: account) }
    }
  }

  public func count(account: String) -> Int {
    entries.withLock { $0[account]?.count ?? 0 }
  }

  /// Capture inside the same serialized command that checks mode and revision.
  public func cancellation(account: String) -> @Sendable () -> Int {
    let signals = entries.withLock {
      $0[account]?.values.compactMap { $0.prepareCancellation() } ?? []
    }
    return {
      for signal in signals { signal() }
      return signals.count
    }
  }
}
