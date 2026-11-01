import CodexOneCore
import ServiceLifecycle
import Synchronization

/// One structured worker; bounded observation hints never create per-account tasks.
public final class QuotaPrimingSupervisor: Service, QuotaPrimingScheduling, Sendable {
  private let store: any QuotaPrimingStore
  private let executor: any QuotaPrimingExecuting
  private let clock: WallClock
  private let hints: AsyncStream<String>
  private let hint: AsyncStream<String>.Continuation
  private let accepting = Mutex(false)
  public var isAccepting: Bool { accepting.withLock { $0 } }
  public init(
    store: any QuotaPrimingStore, executor: any QuotaPrimingExecuting, clock: WallClock = .system
  ) {
    self.store = store
    self.executor = executor
    self.clock = clock
    (hints, hint) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(64))
  }
  public func observedQuota(id: String) {
    if isAccepting && ManagedAccount.validID(id) { hint.yield(id) }
  }
  public func cycleAccount(_ id: String) async throws {
    guard isAccepting, store.allowsOptionalStorageWork else { return }
    let saved = try await store.quotaPrimingState(id: id)
    guard saved.settings.enabled else { return }
    guard let model = saved.settings.model ?? executor.defaultModel, executor.models.contains(model)
    else {
      try await store.disableQuotaPriming(id: id, revision: saved.revision)
      return
    }
    let account = try await store.accountCredential(id: id).account
    guard account.mode == .enabled, account.authorization == .ready else { return }
    let observation = try await store.quotaObservation(id: id)
    guard !saved.eligible(observation, now: clock.unixSeconds).isEmpty else { return }
    try Task.checkCancellation()
    guard isAccepting else { return }
    // Admission repeats all durable checks. No retries, including timeout or unknown completion.
    do {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        defer { tasks.cancelAll() }
        tasks.addTask { try await self.executor.executePriming(id: id, settings: saved.settings) }
        tasks.addTask {
          try await Task.sleep(for: .seconds(20))
          throw QuotaObservationFailure.unavailable
        }
        _ = try await tasks.next()
      }
    } catch is CancellationError { throw CancellationError() } catch {
      if error as? ExecutionError == .storageUnavailable { throw error }
    }
  }
  private func stopAccepting() {
    accepting.withLock { $0 = false }
    hint.finish()
  }
  public func run() async throws {
    accepting.withLock { $0 = true }
    defer {
      stopAccepting()
    }
    do {
      try await cancelWhenGracefulShutdown {
        try await withTaskCancellationHandler {
          try await withThrowingTaskGroup(of: Void.self) { tasks in
            defer { tasks.cancelAll() }
            // Both scans and hints run in this one worker, preventing parallel generation.
            tasks.addTask {
              for await id in self.hints {
                try Task.checkCancellation()
                do { try await self.cycleAccount(id) } catch is CancellationError {
                  throw CancellationError()
                } catch {
                  if error as? ExecutionError == .storageUnavailable { throw error }
                  // CAS races, maintenance and bounded capacity are retried only on a later hint.
                }
              }
            }
            tasks.addTask {
              while !Task.isCancelled {
                do {
                  for account in try await self.store.listAccounts(after: nil) {
                    self.observedQuota(id: account.id)
                  }
                } catch is CancellationError { throw CancellationError() } catch {
                  if error as? ExecutionError == .storageUnavailable { throw error }
                }
                try await Task.sleep(for: .seconds(60))
              }
            }
            _ = try await tasks.next()
          }
        } onCancel: {
          self.stopAccepting()
        }
      }
    } catch is CancellationError {}
  }
}
