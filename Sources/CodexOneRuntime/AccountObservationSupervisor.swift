import CodexOneCore
import Foundation
import Logging
import ServiceLifecycle
import Synchronization

/// One owner for bounded passive observations. Cancelling a caller only removes its waiter.
public final class AccountObservationSupervisor: Service, AccountQuotaObserving, Sendable {
  private struct Job: Sendable {
    let id: String
    let stop: AsyncStream<Void>
    let signal: AsyncStream<Void>.Continuation
    init(id: String) {
      self.id = id
      (stop, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
  }
  private struct Entry {
    let job: Job
    var manual: Bool
    var waiters: [UUID: QuotaWaiter]
  }
  private struct State {
    var started = false
    var accepting = false
    var stopping = false
    var entries: [String: Entry] = [:]
    var waiters = 0
  }
  public static let proactiveRefreshWindowSeconds: Int64 = 15 * 60
  private let logger = Logger(label: "codexone.account-refresh")
  private let refreshWindowSeconds: Int64
  private let state = Mutex(State())
  private let stream: AsyncStream<Job>
  private let continuation: AsyncStream<Job>.Continuation
  private let clock: WallClock
  private let store: any AccountObservationStore
  private let application: AccountCredentials
  private let refresher: any AccountDispatchRefreshing
  private let priming: (any QuotaPrimingScheduling)?
  private let resetCredits: (any AccountResetCreditScheduling)?
  private let provider: any AccountQuotaProvider
  private let intervalMilliseconds: Int
  private let timeoutMilliseconds: Int
  public var isAccepting: Bool { state.withLock { $0.accepting } }
  public var outstandingAccounts: Int { state.withLock { $0.entries.count } }
  public var waitingRequests: Int { state.withLock { $0.waiters } }
  public init(
    store: any AccountObservationStore, application: AccountCredentials,
    refresher: any AccountDispatchRefreshing, provider: any AccountQuotaProvider,
    intervalMilliseconds: Int = 60_000, timeoutMilliseconds: Int = 20_000,
    refreshWindowSeconds: Int64 = AccountObservationSupervisor.proactiveRefreshWindowSeconds,
    clock: WallClock = .system, resetCredits: (any AccountResetCreditScheduling)? = nil,
    priming: (any QuotaPrimingScheduling)? = nil
  ) throws {
    guard (1...300_000).contains(intervalMilliseconds), (1...30_000).contains(timeoutMilliseconds),
      (0...86_400).contains(refreshWindowSeconds)
    else {
      throw QuotaObservationFailure.unavailable
    }
    self.refreshWindowSeconds = refreshWindowSeconds
    self.priming = priming
    self.resetCredits = resetCredits
    self.clock = clock
    self.store = store
    self.application = application
    self.refresher = refresher
    self.provider = provider
    self.intervalMilliseconds = intervalMilliseconds
    self.timeoutMilliseconds = timeoutMilliseconds
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(64))
  }
  public func observeAccount(id: String) async throws -> AccountQuotaObservation {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    let waiter = QuotaWaiter()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { result in
        waiter.install(result)
        enqueue(id: id, waiter: waiter)
      }
    } onCancel: {
      waiter.finish(.failure(QuotaObservationFailure.closed))
      self.state.withLock { value in
        if value.entries[id]?.waiters.removeValue(forKey: waiter.id) != nil { value.waiters -= 1 }
      }
    }
  }
  private func enqueue(id: String, waiter: QuotaWaiter?) {
    guard store.allowsOptionalStorageWork else {
      waiter?.finish(.failure(QuotaObservationFailure.capacity))
      return
    }
    let error: QuotaObservationFailure? = state.withLock { value in
      guard value.accepting else { return .closed }
      if let waiter {
        guard !waiter.isFinished else { return .closed }
        guard value.waiters < 64 else { return .capacity }
      }
      if var entry = value.entries[id] {
        if let waiter {
          entry.manual = true
          entry.waiters[waiter.id] = waiter
          value.waiters += 1
          value.entries[id] = entry
        }
        return nil
      }
      guard value.entries.count < 64 else { return .capacity }
      let job = Job(id: id)
      value.entries[id] = Entry(
        job: job, manual: waiter != nil, waiters: waiter.map { [$0.id: $0] } ?? [:])
      switch continuation.yield(job) {
      case .enqueued:
        if waiter != nil { value.waiters += 1 }
        return nil
      default:
        value.entries.removeValue(forKey: id)
        return .closed
      }
    }
    if let error { waiter?.finish(.failure(error)) }
  }
  public func stopAccepting() {
    let jobs = state.withLock { value in
      value.accepting = false
      value.stopping = true
      return value.entries.values.map(\.job)
    }
    for job in jobs {
      job.signal.yield(())
      job.signal.finish()
    }
    if jobs.isEmpty { continuation.finish() }
  }
  public func run() async throws {
    try state.withLock { value in
      guard !value.started, !value.stopping else { throw QuotaObservationFailure.closed }
      value.started = true
      value.accepting = true
    }
    defer {
      let pending = state.withLock { value in
        value.accepting = false
        let entries = Array(value.entries.values)
        value.entries.removeAll()
        value.waiters = 0
        return entries
      }
      for entry in pending {
        entry.job.signal.finish()
        for waiter in entry.waiters.values {
          waiter.finish(.failure(QuotaObservationFailure.closed))
        }
      }
      continuation.finish()
    }
    try await withGracefulShutdownHandler {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          while self.isAccepting && !Task.isCancelled {
            do {
              try await self.scheduleCycle()
            } catch ExecutionError.capacity {
              // Passive observation yields to ordinary DB pressure. Do not turn a
              // recoverable queue rejection into a failure of the entire Runtime.
            }
            try await Task.sleep(for: .milliseconds(self.intervalMilliseconds))
          }
        }
        group.addTask {
          try await withThrowingTaskGroup(of: Void.self) { workers in
            var running = 0
            for await job in self.stream {
              if running == 4 {
                try await workers.next()
                running -= 1
              }
              workers.addTask { try await self.execute(job) }
              running += 1
            }
            workers.cancelAll()
            while try await workers.next() != nil {}
          }
        }
        defer {
          self.stopAccepting()
          group.cancelAll()
        }
        _ = try await group.next()
      }
    } onGracefulShutdown: {
      self.stopAccepting()
    }
  }
  /// One bounded scan, also usable with an injected clock for deterministic verification.
  public func scheduleCycle() async throws {
    guard isAccepting else { throw QuotaObservationFailure.closed }
    guard store.allowsOptionalStorageWork else { throw ExecutionError.capacity }
    let accounts = try await store.listAccounts(after: nil)
    guard accounts.count <= 64 else { throw ExecutionError.capacity }
    for account in accounts
    where account.mode != .disabled
      && (account.authorization == .ready || account.authorization == .refreshing)
    {
      enqueue(id: account.id, waiter: nil)
    }
  }
  private func proactivelyRefresh(_ account: ManagedAccount) async throws {
    guard account.mode != .disabled, account.authorization == .ready,
      try await application.needsProactiveRefresh(
        id: account.id, windowSeconds: refreshWindowSeconds)
    else { return }
    let metadata: Logger.Metadata = [
      "account_id": .string(account.id),
      "credential_version": .string(String(account.credentialVersion)),
    ]
    logger.info("proactive_refresh_started", metadata: metadata)
    do {
      let updated = try await refresher.refreshForDispatch(account: account)
      logger.info(
        "proactive_refresh_result",
        metadata: metadata.merging([
          "result": "committed",
          "new_credential_version": .string(String(updated.credentialVersion)),
        ]) { _, new in new })
    } catch {
      let result: String
      switch error as? AccountRefreshError {
      case .notCompleted: result = "not_completed"
      case .authorizationRequired: result = "requires_auth"
      case .unavailable: result = "auth_uncertain"
      case .capacity: result = "capacity"
      case .conflict: result = "conflict"
      case .closed: result = "closed"
      default: result = "local_failure"
      }
      logger.info(
        "proactive_refresh_result",
        metadata: metadata.merging([
          "result": .string(result)
        ]) { _, new in new })
      // Only proven non-completion permits observing the still-valid credential.
      if error as? AccountRefreshError != .notCompleted { throw error }
    }
  }
  private func execute(_ job: Job) async throws {
    do {
      guard isAccepting, !Task.isCancelled else { throw QuotaObservationFailure.closed }
      guard store.allowsOptionalStorageWork else { throw ExecutionError.capacity }
      let account = try await store.accountCredential(id: job.id).account
      let manual = state.withLock { $0.entries[job.id]?.manual == true }
      if account.mode == .disabled && !manual {
        finish(job, result: .success(try await store.quotaObservation(id: job.id)))
        return
      }
      let observed: (Result<SubscriptionQuota, QuotaObservationFailure>, ManagedAccount)
      do {
        observed = try await bounded(job: job) {
          if account.authorization == .refreshing && account.mode != .disabled {
            _ = try await self.refresher.refreshForDispatch(account: account)
          }
          try await self.proactivelyRefresh(account)
          let work: AccountObservationWork
          do {
            work = try await self.application.prepareObservation(id: job.id)
          } catch QuotaObservationFailure.refreshRequired {
            guard account.mode != .disabled else { throw QuotaObservationFailure.refreshRequired }
            let current = try await self.store.accountCredential(id: job.id).account
            _ = try await self.refresher.refreshForDispatch(account: current)
            work = try await self.application.prepareObservation(id: job.id)
          }
          do { return (.success(try await self.provider.observe(work)), work.account) } catch {
            if Task.isCancelled { throw QuotaObservationFailure.closed }
            return (.failure(error as? QuotaObservationFailure ?? .unavailable), work.account)
          }
        }
      } catch {
        observed = (.failure(error as? QuotaObservationFailure ?? .unavailable), account)
      }
      guard isAccepting, !Task.isCancelled else { throw QuotaObservationFailure.closed }
      let stored = try await store.recordQuotaObservation(
        account: observed.1, atUnixSeconds: clock.unixSeconds, result: observed.0)
      if stored.failure == nil { priming?.observedQuota(id: job.id) }
      if (stored.quota?.availableResetCredits ?? 0) > 0 {
        resetCredits?.observedResetCredits(id: job.id)
      }
      finish(job, result: .success(stored))
    } catch {
      finish(job, result: .failure(error))
      if error as? ExecutionError == .storageUnavailable {
        stopAccepting()
        throw error
      }
    }
  }
  private func bounded(
    job: Job,
    operation:
      @escaping @Sendable () async throws -> (
        Result<SubscriptionQuota, QuotaObservationFailure>, ManagedAccount
      )
  ) async throws -> (Result<SubscriptionQuota, QuotaObservationFailure>, ManagedAccount) {
    try await withThrowingTaskGroup(
      of: (Result<SubscriptionQuota, QuotaObservationFailure>, ManagedAccount).self
    ) { group in
      defer { group.cancelAll() }
      group.addTask { try await operation() }
      group.addTask { [timeoutMilliseconds] in
        try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
        throw QuotaObservationFailure.unavailable
      }
      group.addTask {
        for await _ in job.stop { throw QuotaObservationFailure.closed }
        throw QuotaObservationFailure.closed
      }
      guard let result = try await group.next() else { throw QuotaObservationFailure.unavailable }
      return result
    }
  }
  private func finish(_ job: Job, result: Result<AccountQuotaObservation, any Error>) {
    let removed = state.withLock { value -> (Entry?, Bool) in
      let entry = value.entries.removeValue(forKey: job.id)
      value.waiters -= entry?.waiters.count ?? 0
      return (entry, value.stopping && value.entries.isEmpty)
    }
    job.signal.finish()
    for waiter in removed.0?.waiters.values ?? [:].values { waiter.finish(result) }
    if removed.1 { continuation.finish() }
  }
}

private final class QuotaWaiter: Sendable {
  let id = UUID()
  private struct State {
    var continuation: CheckedContinuation<AccountQuotaObservation, any Error>?
    var result: Result<AccountQuotaObservation, any Error>?
  }
  private let state = Mutex(State())
  var isFinished: Bool { state.withLock { $0.result != nil } }
  func install(_ continuation: CheckedContinuation<AccountQuotaObservation, any Error>) {
    state.withLock { value in
      if let result = value.result {
        continuation.resume(with: result)
      } else {
        value.continuation = continuation
      }
    }
  }
  func finish(_ result: Result<AccountQuotaObservation, any Error>) {
    state.withLock { value in
      guard value.result == nil else { return }
      value.result = result
      value.continuation?.resume(with: result)
      value.continuation = nil
    }
  }
}
