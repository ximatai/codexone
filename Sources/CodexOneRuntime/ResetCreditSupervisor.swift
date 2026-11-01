import CodexOneCore
import Foundation
import Logging
import ServiceLifecycle
import Synchronization

/// No queued mutations: a shared four-work gate and one operation per account.
public final class ResetCreditSupervisor: Service, AccountResetCreditManaging,
  AccountResetCreditScheduling, Sendable
{
  private final class Job: Sendable {
    private struct State {
      var stopped = false
      var signal: AsyncStream<Void>.Continuation?
    }
    private let state = Mutex(State())
    let done: AsyncStream<Void>
    let completed: AsyncStream<Void>.Continuation
    init() {
      (done, completed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func listen(_ signal: AsyncStream<Void>.Continuation) {
      let stopped = state.withLock { value in
        value.signal = signal
        return value.stopped
      }
      if stopped { signal.finish() }
    }
    func clearListener() { state.withLock { $0.signal = nil } }
    func stop() {
      let signal = state.withLock { value in
        value.stopped = true
        return value.signal
      }
      signal?.yield(())
      signal?.finish()
    }
  }
  private struct Target: Sendable {
    let id: String
    let expiresAt: TimeInterval
  }
  private struct Schedule: Sendable {
    let revision: Int64
    var nextPoll: Int64
    var due: TimeInterval?
    var target: Target?
    var retryAt: Int64?
  }
  private struct State {
    var started = false
    var accepting = false
    var stopping = false
    var active: [String: Job] = [:]
    var schedules: [String: Schedule] = [:]
  }
  private var nowTime: TimeInterval { Double(clock.unixMicroseconds) / 1_000_000 }
  private let state = Mutex(State())
  private let store: any AccountResetCreditStore
  private let credentials: AccountCredentials
  private let provider: any AccountResetCreditProvider
  private let clock: WallClock
  private let sleep: @Sendable (Int64) async throws -> Void
  private let intervalSeconds: Int64
  private let hints: AsyncStream<String>
  private let hint: AsyncStream<String>.Continuation
  private let logger = Logger(label: "codexone.reset-credits")
  public var isAccepting: Bool { state.withLock { $0.accepting } }
  public var activeOperations: Int { state.withLock { $0.active.count } }
  public init(
    store: any AccountResetCreditStore, credentials: AccountCredentials,
    provider: any AccountResetCreditProvider, clock: WallClock = .system,
    intervalSeconds: Int64 = 1800,
    sleep: @escaping @Sendable (Int64) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) throws {
    guard (1...3600).contains(intervalSeconds) else { throw ExecutionError.invalidCommand }
    self.store = store
    self.credentials = credentials
    self.provider = provider
    self.clock = clock
    self.intervalSeconds = intervalSeconds
    self.sleep = sleep
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
    job.stop()
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
    id: String, creditID: String?, automatic: Bool, job: Job, expectedRevision: Int64? = nil,
    expiresAt: TimeInterval? = nil, attemptNumber: Int = 1
  ) async throws
    -> ResetCreditResult
  {
    let work = try await credentials.prepareObservation(id: id)
    if let expectedRevision, work.account.revision != expectedRevision {
      throw ExecutionError.conflict
    }
    try Task.checkCancellation()
    guard isAccepting else { throw QuotaObservationFailure.closed }
    if let expiresAt, nowTime >= expiresAt {
      throw ExecutionError.conflict
    }
    let attempt = try await store.beginResetCreditAttempt(
      account: work.account, creditID: creditID, automatic: automatic)
    let result: ResetCreditResult
    do {
      result = try await bounded(job) {
        // The durable transaction and credential preparation can cross expiry.
        if let expiresAt, self.nowTime >= expiresAt {
          throw ExecutionError.conflict
        }
        return try await self.provider.consumeResetCredit(work, intent: attempt.intent)
      }
    } catch { result = try .init(code: .unknown) }
    // Completion has its own preallocated audit row and critical DB capacity. Cancellation
    // cannot erase the durable intent or turn a lost response into a fresh request.
    try await store.finishResetCreditAttempt(id: id, attempt: attempt, result: result)
    logger.info(
      "reset_credit_result",
      metadata: [
        "account_id": .string(id), "credit_hash": .string(attempt.creditHash ?? "default"),
        "result": .string(result.code.rawValue), "attempt": .string(String(attemptNumber)),
      ])
    return result
  }
  private func bounded<T: Sendable>(_ job: Job, operation: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    // AsyncStream cancellation finishes that stream globally. Give each sequential
    // list/consume request its own listener so cancelling a finished list's waiter
    // cannot close the subsequent consume or reconciliation request.
    let (stop, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    job.listen(signal)
    defer { job.clearListener() }
    return try await withThrowingTaskGroup(of: T.self) { tasks in
      defer { tasks.cancelAll() }
      tasks.addTask {
        guard self.isAccepting else { throw QuotaObservationFailure.closed }
        try Task.checkCancellation()
        return try await operation()
      }
      tasks.addTask {
        for await _ in stop { break }
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
  /// Bounded scan. Clock controls decisions; sleeps use monotonic time.
  public func scheduleCycle() async throws {
    guard isAccepting else { throw QuotaObservationFailure.closed }
    guard store.allowsOptionalStorageWork else { return }
    let accounts = try await store.listAccounts(after: nil)
    guard accounts.count <= 64 else { throw ExecutionError.capacity }
    let ids = Set(accounts.map(\.id))
    state.withLock { $0.schedules = $0.schedules.filter { ids.contains($0.key) } }
    // Give already learned deadlines priority over routine discovery. At most four
    // structured workers exist; each still acquires the shared manual/automatic gate.
    let ordered = state.withLock { value in
      accounts.sorted { a, b in
        func deadline(_ id: String) -> TimeInterval {
          guard let schedule = value.schedules[id] else { return Double(clock.unixSeconds) }
          return schedule.retryAt.map(Double.init)
            ?? min(Double(schedule.nextPoll), schedule.due ?? Double(schedule.nextPoll))
        }
        let left = deadline(a.id)
        let right = deadline(b.id)
        return left == right ? a.id < b.id : left < right
      }
    }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      var iterator = ordered.makeIterator()
      for _ in 0..<4 {
        if let account = iterator.next() {
          tasks.addTask { try await self.cycleAccount(account.id) }
        }
      }
      while try await tasks.next() != nil {
        try Task.checkCancellation()
        if let account = iterator.next() {
          tasks.addTask { try await self.cycleAccount(account.id) }
        }
      }
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
    let saved = try await store.resetCreditState(id: id)
    guard account.mode == .enabled, account.authorization == .ready,
      saved.settings.autoUseBeforeExpiry, saved.intent?.automatic != false
    else {
      state.withLock { _ = $0.schedules.removeValue(forKey: id) }
      return
    }
    let now = clock.unixSeconds
    var schedule = state.withLock { $0.schedules[id] }
    if schedule?.revision != account.revision {
      schedule = Schedule(
        revision: account.revision, nextPoll: now,
        retryAt: saved.intent != nil
          ? saved.lastAttemptAt.map {
            max(now, $0 + Int64(ResetCreditSettings.retryIntervalMinutes * 60))
          } : nil)
    }
    guard var next = schedule else { return }
    let retrying = next.retryAt != nil
    guard
      next.retryAt.map({ now >= $0 })
        ?? (next.due.map { Double(now) >= $0 } == true || now >= next.nextPoll)
    else { return }
    let job: Job
    do { job = try acquire(id) } catch ExecutionError.conflict { return } catch ExecutionError
      .capacity
    { return }
    defer { release(id, job) }
    // Reserve this account's next cycle before yielding. A concurrent hint cannot create work.
    next.nextPoll = now + intervalSeconds
    next.due = nil
    next.retryAt = nil
    defer { state.withLock { $0.schedules[id] = next } }
    if let target = next.target, Double(now) >= target.expiresAt {
      next.target = nil
      if retrying { return }
    }
    // Exhausted unknown intents remain durable for manual reconciliation, including restart.
    if saved.intent != nil && saved.failures > saved.settings.retryCount { return }
    var attemptNumber = saved.failures + 1
    do {
      let work = try await credentials.prepareObservation(id: id)
      let list = try await bounded(job) { try await self.provider.resetCredits(work) }
      let future = list.credits.compactMap { credit -> (Target, TimeInterval)? in
        guard credit.status == "available", let raw = credit.expiresAt,
          let expiry = ResetCredit.timestamp(raw),
          expiry > nowTime
        else { return nil }
        let due = expiry - Double(saved.settings.leadMinutes * 60)
        return due > nowTime
          ? (Target(id: credit.id, expiresAt: expiry), due) : nil
      }.min { $0.1 < $1.1 }
      next.due = future?.1
      let target: Target?
      if let pending = saved.intent {
        // Reconcile the same request even if the provider already marks the card used.
        // An unlisted or expiry-less pending card never authorizes an automatic send.
        target = list.credits.first { $0.id == pending.creditID }.flatMap { credit in
          credit.expiresAt.flatMap(ResetCredit.timestamp).map {
            Target(id: credit.id, expiresAt: $0)
          }
        }
      } else if retrying, let previous = next.target {
        target = list.credits.first { $0.id == previous.id && $0.status == "available" }
          .flatMap { credit in
            credit.expiresAt.flatMap(ResetCredit.timestamp).map {
              Target(id: credit.id, expiresAt: $0)
            }
          }
      } else {
        target = list.expiringCredit(
          now: clock.unixSeconds, leadMinutes: saved.settings.leadMinutes
        )
        .map { Target(id: $0.id, expiresAt: ResetCredit.timestamp($0.expiresAt!)!) }
      }
      if let target, nowTime < target.expiresAt,
        saved.intent != nil
          || nowTime >= target.expiresAt
            - Double(saved.settings.leadMinutes * 60)
      {
        if !retrying {
          try await store.recordResetCreditPollSuccess(id: id)
          if saved.intent == nil { attemptNumber = 1 }
        }
        next.target = target
        let result = try await consume(
          id: id, creditID: target.id, automatic: true, job: job,
          expectedRevision: account.revision, expiresAt: target.expiresAt,
          attemptNumber: attemptNumber)
        if result.code == .unknown {
          scheduleRetry(&next, settings: saved.settings, attemptNumber: attemptNumber)
        } else {
          next.target = future?.0
        }
      } else {
        // A successful list must not erase a series of consume failures or a pending intent.
        if !retrying { try await store.recordResetCreditPollSuccess(id: id) }
        next.target = future?.0
      }
    } catch {
      if error as? ExecutionError == .storageUnavailable { throw error }
      if !isAccepting || Task.isCancelled { return }
      try await store.recordResetCreditPollFailure(id: id)
      scheduleRetry(&next, settings: saved.settings, attemptNumber: attemptNumber)
      logger.info(
        "reset_credit_result",
        metadata: [
          "account_id": .string(id), "result": "unavailable",
          "attempt": .string(String(attemptNumber)),
        ])
    }
  }
  private func scheduleRetry(
    _ schedule: inout Schedule, settings: ResetCreditSettings, attemptNumber: Int
  ) {
    let retryAt = Int64(ceil(nowTime)) + Int64(ResetCreditSettings.retryIntervalMinutes * 60)
    guard attemptNumber <= settings.retryCount,
      schedule.target.map({ Double(retryAt) < $0.expiresAt }) ?? true
    else { return }
    schedule.retryAt = retryAt
  }
  /// One structured timer, capped at a minute to discover edits even without an observation hint.
  private var wakeDelay: Int64 {
    let now = clock.unixSeconds
    return state.withLock { value in
      let earliest =
        value.schedules.values.map { schedule in
          schedule.retryAt
            ?? min(
              schedule.nextPoll, schedule.due.map { Int64(ceil($0)) } ?? schedule.nextPoll)
        }.min() ?? (now + 60)
      return max(1, min(60, earliest - now))
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
      job.stop()
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
              try await self.sleep(self.wakeDelay)
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
