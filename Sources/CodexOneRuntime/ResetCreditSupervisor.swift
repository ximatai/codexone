import CodexOneCore
import Foundation
import Logging
import ServiceLifecycle
import Synchronization

/// No queued mutations: a shared four-work gate and one operation per account.
public final class ResetCreditSupervisor: Service, AccountResetCreditManaging,
  AccountResetCreditScheduling, Sendable
{
  private struct Job: Sendable {
    let stop: AsyncStream<Void>
    let signal: AsyncStream<Void>.Continuation
    let done: AsyncStream<Void>
    let completed: AsyncStream<Void>.Continuation
    init() {
      (stop, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
      (done, completed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
  }
  private struct State {
    var started = false
    var accepting = false
    var stopping = false
    var active: [String: Job] = [:]
    var lastCycle: [String: Int64] = [:]
  }
  private let state = Mutex(State())
  private let store: any AccountResetCreditStore
  private let credentials: AccountCredentials
  private let provider: any AccountResetCreditProvider
  private let clock: WallClock
  private let intervalSeconds: Int64
  private let hints: AsyncStream<String>
  private let hint: AsyncStream<String>.Continuation
  private let logger = Logger(label: "codexone.reset-credits")
  public var isAccepting: Bool { state.withLock { $0.accepting } }
  public var activeOperations: Int { state.withLock { $0.active.count } }
  public init(
    store: any AccountResetCreditStore, credentials: AccountCredentials,
    provider: any AccountResetCreditProvider, clock: WallClock = .system,
    intervalSeconds: Int64 = 1800
  ) throws {
    guard (1...3600).contains(intervalSeconds) else { throw ExecutionError.invalidCommand }
    self.store = store
    self.credentials = credentials
    self.provider = provider
    self.clock = clock
    self.intervalSeconds = intervalSeconds
    (hints, hint) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(64))
  }
  public func observedResetCredits(id: String) {
    guard ManagedAccount.validID(id), isAccepting else { return }
    hint.yield(id)
  }
  private func acquire(_ id: String) throws -> Job {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    guard store.allowsOptionalStorageWork else { throw ExecutionError.capacity }
    return try state.withLock { value in
      guard value.accepting else { throw QuotaObservationFailure.closed }
      guard value.active[id] == nil else { throw ExecutionError.conflict }
      guard value.active.count < 4 else { throw ExecutionError.capacity }
      let job = Job()
      value.active[id] = job
      return job
    }
  }
  private func release(_ id: String, _ job: Job) {
    state.withLock { _ = $0.active.removeValue(forKey: id) }
    job.signal.finish()
    job.completed.finish()
  }
  public func listResetCredits(id: String) async throws -> ResetCreditList {
    let job = try acquire(id)
    defer { release(id, job) }
    let work = try await credentials.prepareObservation(id: id)
    return try await bounded(job) { try await self.provider.resetCredits(work) }
  }
  public func consumeResetCredit(id: String, creditID: String?) async throws -> ResetCreditResult {
    let job = try acquire(id)
    defer { release(id, job) }
    return try await consume(id: id, creditID: creditID, automatic: false, job: job)
  }
  private func consume(
    id: String, creditID: String?, automatic: Bool, job: Job, expectedRevision: Int64? = nil
  ) async throws
    -> ResetCreditResult
  {
    let work = try await credentials.prepareObservation(id: id)
    if let expectedRevision, work.account.revision != expectedRevision {
      throw ExecutionError.conflict
    }
    try Task.checkCancellation()
    guard isAccepting else { throw QuotaObservationFailure.closed }
    let attempt = try await store.beginResetCreditAttempt(
      account: work.account, creditID: creditID, automatic: automatic)
    let result: ResetCreditResult
    do {
      result = try await bounded(job) {
        try await self.provider.consumeResetCredit(work, intent: attempt.intent)
      }
    } catch { result = try .init(code: .unknown) }
    // Completion has its own preallocated audit row and critical DB capacity. Cancellation
    // cannot erase the durable intent or turn a lost response into a fresh request.
    try await store.finishResetCreditAttempt(id: id, attempt: attempt, result: result)
    logger.info(
      "reset_credit_result",
      metadata: [
        "account_id": .string(id), "credit_hash": .string(attempt.creditHash ?? "default"),
        "result": .string(result.code.rawValue),
      ])
    return result
  }
  private func bounded<T: Sendable>(_ job: Job, operation: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    try await withThrowingTaskGroup(of: T.self) { tasks in
      defer { tasks.cancelAll() }
      tasks.addTask {
        guard self.isAccepting else { throw QuotaObservationFailure.closed }
        try Task.checkCancellation()
        return try await operation()
      }
      tasks.addTask {
        for await _ in job.stop { break }
        throw QuotaObservationFailure.closed
      }
      tasks.addTask {
        try await Task.sleep(for: .seconds(20))
        throw QuotaObservationFailure.unavailable
      }
      guard let result = try await tasks.next() else { throw QuotaObservationFailure.closed }
      return result
    }
  }
  /// Sequential bounded scan. Clock controls decisions; sleeps use monotonic time.
  public func scheduleCycle() async throws {
    guard isAccepting else { throw QuotaObservationFailure.closed }
    guard store.allowsOptionalStorageWork else { return }
    let accounts = try await store.listAccounts(after: nil)
    guard accounts.count <= 64 else { throw ExecutionError.capacity }
    for account in accounts {
      try Task.checkCancellation()
      try await cycleAccount(account.id)
    }
  }
  private func cycleAccount(_ id: String) async throws {
    do { try await automaticCycle(id) } catch is CancellationError {
      throw CancellationError()
    } catch {
      // An account removed or edited mid-scan only skips that account; storage failure alone
      // stops the Runtime, as in the other owners.
      if error as? ExecutionError == .storageUnavailable { throw error }
    }
  }
  private func automaticCycle(_ id: String) async throws {
    guard isAccepting, store.allowsOptionalStorageWork else { return }
    let account = try await store.accountCredential(id: id).account
    guard account.mode == .enabled, account.authorization == .ready else { return }
    let saved = try await store.resetCreditState(id: id)
    guard saved.settings.autoUseBeforeExpiry, saved.intent?.automatic != false else { return }
    let now = clock.unixSeconds
    let eligible = state.withLock { value in
      guard value.active[id] == nil, value.active.count < 4 else { return false }
      if let last = value.lastCycle[id], now < last || now - last < intervalSeconds { return false }
      value.lastCycle[id] = now
      return true
    }
    guard eligible else { return }
    let job: Job
    do { job = try acquire(id) } catch ExecutionError.conflict { return } catch ExecutionError
      .capacity
    { return }
    defer { release(id, job) }
    do {
      if saved.intent != nil {
        _ = try await consume(
          id: id, creditID: nil, automatic: true, job: job, expectedRevision: account.revision)
      } else {
        let work = try await credentials.prepareObservation(id: id)
        let list = try await bounded(job) { try await self.provider.resetCredits(work) }
        try await store.recordResetCreditPollSuccess(id: id)
        if let credit = list.expiringCredit(
          now: clock.unixSeconds, leadHours: saved.settings.leadHours)
        {
          _ = try await consume(
            id: id, creditID: credit.id, automatic: true, job: job,
            expectedRevision: account.revision)
        }
      }
    } catch {
      if error as? ExecutionError == .storageUnavailable { throw error }
      if !isAccepting || Task.isCancelled { return }
      try await store.recordResetCreditPollFailure(id: id)
    }
  }
  public func stopAccepting() {
    let jobs = state.withLock { value in
      value.accepting = false
      value.stopping = true
      return Array(value.active.values)
    }
    hint.finish()
    for job in jobs {
      job.signal.yield(())
      job.signal.finish()
    }
  }
  public func run() async throws {
    try state.withLock { value in
      guard !value.started, !value.stopping else { throw QuotaObservationFailure.closed }
      value.started = true
      value.accepting = true
    }
    do {
      try await withGracefulShutdownHandler {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
          tasks.addTask {
            while self.isAccepting && !Task.isCancelled {
              do { try await self.scheduleCycle() } catch ExecutionError.capacity {}
              try await Task.sleep(for: .seconds(self.intervalSeconds))
            }
          }
          tasks.addTask {
            for await id in self.hints {
              do { try await self.cycleAccount(id) } catch ExecutionError.capacity {}
            }
          }
          tasks.addTask { try await gracefulShutdown() }
          defer {
            self.stopAccepting()
            tasks.cancelAll()
          }
          _ = try await tasks.next()
        }
      } onGracefulShutdown: {
        self.stopAccepting()
      }
    } catch is CancellationError {
      // All structured workers are awaited before external API operations are joined below.
    } catch {
      stopAccepting()
      let jobs = state.withLock { Array($0.active.values) }
      for job in jobs { for await _ in job.done {} }
      throw error
    }
    stopAccepting()
    let jobs = state.withLock { Array($0.active.values) }
    for job in jobs { for await _ in job.done {} }
  }
}
