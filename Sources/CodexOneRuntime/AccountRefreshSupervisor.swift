import CodexOneCore
import Foundation
import ServiceLifecycle
import Synchronization

/// Owns bounded, shared refresh work. Request cancellation never owns the provider task.
public final class AccountRefreshSupervisor: Service, AccountRefreshing, Sendable {
  private struct Job: Sendable {
    let id: String
    let revision: Int64
    let stop: AsyncStream<Void>
    let stopContinuation: AsyncStream<Void>.Continuation
    init(id: String, revision: Int64) {
      self.id = id
      self.revision = revision
      let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      stop = pair.stream
      stopContinuation = pair.continuation
    }
  }
  private struct Entry {
    let job: Job
    var waiters: [UUID: RefreshWaiter]
  }
  private struct State {
    var started = false
    var accepting = false
    var stopping = false
    var jobs: [String: Entry] = [:]
    var waiters = 0
  }
  private let state = Mutex(State())
  private let stream: AsyncStream<Job>
  private let continuation: AsyncStream<Job>.Continuation
  private let application: AccountCredentials
  private let provider: any AccountRefreshProvider
  private let identities: Int
  private let maximumWaiters: Int
  private let perIdentity: Int
  private let parallelism: Int
  private let timeoutMilliseconds: Int

  public init(
    application: AccountCredentials, provider: any AccountRefreshProvider,
    identities: Int = 16, maximumWaiters: Int = 64, perIdentity: Int = 16,
    parallelism: Int = 4, timeoutMilliseconds: Int = 10_000
  ) throws {
    guard (1...16).contains(identities), (1...64).contains(maximumWaiters),
      (1...16).contains(perIdentity), (1...min(4, identities)).contains(parallelism),
      (1...30_000).contains(timeoutMilliseconds)
    else { throw AccountRefreshError.invalidCommand }
    self.application = application
    self.provider = provider
    self.identities = identities
    self.maximumWaiters = maximumWaiters
    self.perIdentity = perIdentity
    self.parallelism = parallelism
    self.timeoutMilliseconds = timeoutMilliseconds
    let pair = AsyncStream<Job>.makeStream(bufferingPolicy: .bufferingOldest(identities))
    stream = pair.stream
    continuation = pair.continuation
  }
  public var isAccepting: Bool { state.withLock { $0.accepting } }
  public var outstandingIdentities: Int { state.withLock { $0.jobs.count } }
  public var waitingRequests: Int { state.withLock { $0.waiters } }

  public func refreshAccount(id: String, revision: Int64) async throws -> ManagedAccount {
    guard ManagedAccount.validID(id), (1...1_000_000).contains(revision) else {
      throw AccountRefreshError.invalidCommand
    }
    let waiter = RefreshWaiter()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { result in
        waiter.install(result)
        enqueue(id: id, revision: revision, waiter: waiter)
      }
    } onCancel: {
      waiter.finish(.failure(.closed))
      self.removeWaiter(id: id, waiter: waiter.id)
    }
  }
  private func enqueue(id: String, revision: Int64, waiter: RefreshWaiter) {
    let failure: AccountRefreshError? = state.withLock { value in
      guard !waiter.isFinished else { return nil }
      guard value.accepting else { return .closed }
      guard value.waiters < maximumWaiters else { return .capacity }
      if var existing = value.jobs[id] {
        guard existing.job.revision == revision else { return .conflict }
        guard existing.waiters.count < perIdentity else { return .capacity }
        existing.waiters[waiter.id] = waiter
        value.jobs[id] = existing
      } else {
        guard value.jobs.count < identities else { return .capacity }
        let job = Job(id: id, revision: revision)
        value.jobs[id] = Entry(job: job, waiters: [waiter.id: waiter])
        switch continuation.yield(job) {
        case .enqueued: break
        default:
          value.jobs.removeValue(forKey: id)
          return .closed
        }
      }
      value.waiters += 1
      return nil
    }
    if let failure { waiter.finish(.failure(failure)) }
  }
  private func removeWaiter(id: String, waiter: UUID) {
    state.withLock { value in
      guard var entry = value.jobs[id], entry.waiters.removeValue(forKey: waiter) != nil else {
        return
      }
      value.waiters -= 1
      value.jobs[id] = entry
    }
  }
  public func stopAccepting() {
    let stopped = state.withLock { value in
      value.accepting = false
      value.stopping = true
      return Array(value.jobs.values.map(\.job))
    }
    for job in stopped {
      job.stopContinuation.yield(())
      job.stopContinuation.finish()
    }
    if stopped.isEmpty { continuation.finish() }
  }
  public func run() async throws {
    try state.withLock { value in
      guard !value.started else { throw AccountRefreshError.conflict }
      guard !value.stopping else { throw AccountRefreshError.closed }
      value.started = true
      value.accepting = true
    }
    defer {
      let pending = state.withLock { value in
        value.accepting = false
        let entries = Array(value.jobs.values)
        value.jobs.removeAll()
        value.waiters = 0
        return entries
      }
      for entry in pending {
        entry.job.stopContinuation.finish()
        for waiter in entry.waiters.values { waiter.finish(.failure(.closed)) }
      }
      continuation.finish()
    }
    await withGracefulShutdownHandler {
      await withTaskGroup(of: Void.self) { group in
        var running = 0
        for await job in stream {
          if running == parallelism {
            await group.next()
            running -= 1
          }
          group.addTask { await self.execute(job) }
          running += 1
        }
        group.cancelAll()
        while await group.next() != nil {}
      }
    } onGracefulShutdown: {
      self.stopAccepting()
    }
  }
  private func execute(_ job: Job) async {
    var work: AccountRefreshWork?
    let result: Result<ManagedAccount, AccountRefreshError>
    do {
      try Task.checkCancellation()
      guard isAccepting else { throw AccountRefreshError.closed }
      let owned = try await application.beginRefresh(id: job.id, revision: job.revision)
      work = owned
      try Task.checkCancellation()
      guard isAccepting else { throw AccountRefreshError.closed }
      let verified = try await boundedRefresh(owned, stop: job.stop)
      let finished = try await application.finishVerifiedRefresh(
        owned, namespace: verified.namespace, credential: verified.credential)
      result = .success(finished)
    } catch {
      if let work { _ = try? await application.failRefresh(work) }
      result = .failure(!isAccepting || Task.isCancelled ? .closed : Self.safeError(error))
    }
    finish(job, result: result)
  }
  private func boundedRefresh(_ work: AccountRefreshWork, stop: AsyncStream<Void>) async throws
    -> VerifiedAccountRefresh
  {
    try await withThrowingTaskGroup(of: VerifiedAccountRefresh.self) { group in
      defer { group.cancelAll() }
      group.addTask { [provider] in
        do {
          try Task.checkCancellation()
          return try await provider.refresh(
            credential: work.credential, namespace: work.account.namespace)
        } catch { throw AccountRefreshError.unavailable }
      }
      group.addTask { [timeoutMilliseconds] in
        try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
        throw AccountRefreshError.unavailable
      }
      group.addTask {
        for await _ in stop { throw AccountRefreshError.closed }
        throw AccountRefreshError.closed
      }
      guard let result = try await group.next() else { throw AccountRefreshError.closed }
      return result
    }
  }
  private func finish(_ job: Job, result: Result<ManagedAccount, AccountRefreshError>) {
    let finished = state.withLock { value -> (Entry?, Bool) in
      let entry = value.jobs.removeValue(forKey: job.id)
      value.waiters -= entry?.waiters.count ?? 0
      return (entry, !value.accepting && value.jobs.isEmpty)
    }
    job.stopContinuation.finish()
    if let entry = finished.0 {
      for waiter in entry.waiters.values { waiter.finish(result) }
    }
    if finished.1 { continuation.finish() }
  }
  private static func safeError(_ error: any Error) -> AccountRefreshError {
    if error is CancellationError { return .closed }
    if let error = error as? AccountRefreshError { return error }
    guard let error = error as? ExecutionError else { return .unavailable }
    switch error {
    case .invalidCommand: return .invalidCommand
    case .capacity: return .capacity
    case .closed: return .closed
    case .conflict: return .conflict
    default: return .storageUnavailable
    }
  }
}

private final class RefreshWaiter: Sendable {
  let id = UUID()
  private struct State {
    var finished = false
    var result: Result<ManagedAccount, AccountRefreshError>?
    var continuation: CheckedContinuation<ManagedAccount, any Error>?
  }
  private let state = Mutex(State())
  var isFinished: Bool { state.withLock { $0.finished } }
  func install(_ continuation: CheckedContinuation<ManagedAccount, any Error>) {
    let result = state.withLock { value -> Result<ManagedAccount, AccountRefreshError>? in
      if let result = value.result {
        value.result = nil
        return result
      }
      value.continuation = continuation
      return nil
    }
    if let result { Self.resume(continuation, result) }
  }
  func finish(_ result: Result<ManagedAccount, AccountRefreshError>) {
    let continuation = state.withLock { value -> CheckedContinuation<ManagedAccount, any Error>? in
      guard !value.finished else { return nil }
      value.finished = true
      if let continuation = value.continuation {
        value.continuation = nil
        return continuation
      }
      value.result = result
      return nil
    }
    if let continuation { Self.resume(continuation, result) }
  }
  private static func resume(
    _ continuation: CheckedContinuation<ManagedAccount, any Error>,
    _ result: Result<ManagedAccount, AccountRefreshError>
  ) {
    switch result {
    case .success(let account): continuation.resume(returning: account)
    case .failure(let error): continuation.resume(throwing: error)
    }
  }
}
