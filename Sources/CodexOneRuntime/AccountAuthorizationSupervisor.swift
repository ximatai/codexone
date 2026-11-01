import CodexOneCore
import Foundation
import ServiceLifecycle

/// Owns both flow kinds. Device workers are children of run; callback exchanges belong to complete.
public actor AccountAuthorizationSupervisor: Service, AccountAuthorizing {
  private struct Flow: Sendable {
    let owner: String
    let target: AccountAuthorizationTarget
    let method: AccountAuthorizationMethod
    let state: String
    let nonce: String
    let verifier: String
    var deadline: ContinuousClock.Instant
    var result: AccountAuthorizationStatus.State = .pending
    var userCode: String?
    var accountID: String?
    var failureCode: String?
  }
  private enum Event: Sendable {
    case device(String, CheckedContinuation<AccountAuthorizationStart, any Error>)
    case finished
    case stop
  }
  private let application: AccountCredentials
  private let provider: any AccountAuthorizationProvider
  private let lifetime: Duration
  private let deviceLifetime: Duration
  private let exchangeTimeout: Duration
  private let now: @Sendable () -> ContinuousClock.Instant
  private let pollWait: @Sendable (Duration) async throws -> Void
  private var started = false
  private var accepting = false
  private var flows: [String: Flow] = [:]
  private var active: [String: AsyncStream<Void>.Continuation] = [:]
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var completions = 0
  private let events = AsyncStream<Event>.makeStream()
  public var isAccepting: Bool { accepting }

  public init(
    application: AccountCredentials, provider: any AccountAuthorizationProvider,
    lifetime: Duration = .seconds(600), exchangeTimeout: Duration = .seconds(30),
    deviceLifetime: Duration = .seconds(900),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    pollWait: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) throws {
    guard lifetime > .zero, lifetime <= .seconds(600), deviceLifetime > .zero,
      deviceLifetime <= .seconds(900), exchangeTimeout > .zero, exchangeTimeout <= .seconds(30)
    else { throw AccountRefreshError.invalidCommand }
    self.application = application
    self.provider = provider
    self.lifetime = lifetime
    self.deviceLifetime = deviceLifetime
    self.exchangeTimeout = exchangeTimeout
    self.now = now
    self.pollWait = pollWait
  }
  public func run() async throws {
    guard !started else { throw AccountRefreshError.conflict }
    started = true
    accepting = true
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do { try await gracefulShutdown() } catch {}
        await self.requestStop()
      }
      for await event in events.stream {
        switch event {
        case .device(let id, let response):
          group.addTask {
            await self.deviceWorker(id, response: response)
            await self.workerFinished()
          }
        case .finished: await group.next()
        case .stop:
          group.cancelAll()
          return
        }
      }
    }
    // Callback exchanges live in request scopes; stop signals cancel and await those scopes too.
    for id in Array(active.keys) { await waitForExit(id) }
    flows.removeAll()
    events.continuation.finish()
  }
  private func requestStop() {
    accepting = false
    for signal in active.values {
      signal.yield(())
      signal.finish()
    }
    events.continuation.yield(.stop)
  }
  private func workerFinished() { events.continuation.yield(.finished) }
  public func begin(owner: String, target: AccountAuthorizationTarget) async throws
    -> AccountAuthorizationStart
  {
    try await begin(owner: owner, target: target, method: .callback)
  }
  public func begin(
    owner: String, target: AccountAuthorizationTarget, method: AccountAuthorizationMethod
  ) async throws -> AccountAuthorizationStart {
    guard accepting else { throw AccountRefreshError.closed }
    guard ManagedAccount.validID(owner) else { throw AccountRefreshError.invalidCommand }
    if case .reauthorize(let id, let revision) = target {
      guard ManagedAccount.validID(id), (1...1_000_000).contains(revision) else {
        throw AccountRefreshError.invalidCommand
      }
    }
    // Terminal results remain readable until their deadline; expired inactive records can be reclaimed.
    flows = flows.filter { $0.value.deadline > now() || active[$0.key] != nil }
    let occupied = Set(flows.keys).union(active.keys).count
    guard occupied < 8 else { throw AccountRefreshError.capacity }
    let id = UUID().uuidString
    let state = Self.secret()
    let nonce = Self.secret()
    let verifier = Self.secret()
    flows[id] = Flow(
      owner: owner, target: target, method: method, state: state, nonce: nonce, verifier: verifier,
      deadline: now().advanced(by: method == .device ? deviceLifetime : lifetime))
    if method == .device {
      return try await withCheckedThrowingContinuation { continuation in
        events.continuation.yield(.device(id, continuation))
      }
    }
    do {
      return AccountAuthorizationStart(
        flowID: id,
        authorizationURL: try provider.authorizationURL(
          state: state, nonce: nonce, verifier: verifier),
        expiresInSeconds: Int(lifetime.components.seconds))
    } catch {
      flows.removeValue(forKey: id)
      throw AccountRefreshError.unavailable
    }
  }
  public func status(owner: String, flowID: String) async throws -> AccountAuthorizationStatus {
    guard let flow = flows[flowID], flow.owner == owner else { throw AccountRefreshError.conflict }
    let expired = flow.result == .pending && flow.deadline <= now()
    if expired { active[flowID]?.yield(()) }
    return AccountAuthorizationStatus(
      status: expired ? .expired : flow.result,
      expiresInSeconds: remaining(flowID),
      userCode: expired || flow.result != .pending ? nil : flow.userCode,
      accountID: flow.accountID, failureCode: flow.failureCode)
  }
  public func discard(owner: String, flowID: String) async {
    guard flows[flowID]?.owner == owner else { return }
    flows.removeValue(forKey: flowID)
    active[flowID]?.yield(())
    active[flowID]?.finish()
    await waitForExit(flowID)
  }
  private func waitForExit(_ id: String) async {
    guard active[id] != nil else { return }
    await withCheckedContinuation { waiters[id, default: []].append($0) }
  }
  private func finished(_ id: String) {
    active.removeValue(forKey: id)?.finish()
    for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
  }
  private func deviceWorker(
    _ id: String, response: CheckedContinuation<AccountAuthorizationStart, any Error>
  ) async {
    let (stop, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    active[id] = signal
    defer { finished(id) }
    // Creation also belongs to the service. Its caller receives a safe failed flow on provider errors.
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask {
          for await _ in stop { throw AccountRefreshError.closed }
          throw AccountRefreshError.closed
        }
        group.addTask { try await self.deviceOperation(id, response: response) }
        _ = try await group.next()
      }
    } catch {
      // deviceOperation always resolves creation before it enters polling, including on cancellation.
      fail(id, error: error)
    }
  }
  private func deviceOperation(
    _ id: String, response: CheckedContinuation<AccountAuthorizationStart, any Error>
  ) async throws {
    let device: AccountDeviceCode
    do {
      try checkPending(id)
      let creationBudget = now().duration(to: flows[id]!.deadline)
      device = try await withThrowingTaskGroup(of: AccountDeviceCode.self) { group in
        defer { group.cancelAll() }
        group.addTask { [provider] in try await provider.requestDeviceCode() }
        group.addTask {
          try await Task.sleep(for: creationBudget)
          throw AccountRefreshError.conflict
        }
        return try await group.next()!
      }
      try checkPending(id)
      let deadline = min(flows[id]!.deadline, now().advanced(by: .seconds(device.expiresInSeconds)))
      flows[id]?.deadline = deadline
      flows[id]?.userCode = device.userCode
      var start = AccountAuthorizationStart(
        flowID: id, authorizationURL: "", expiresInSeconds: remaining(id))
      start.method = .device
      start.userCode = device.userCode
      start.verificationURL = device.verificationURL
      start.intervalSeconds = device.intervalSeconds
      response.resume(returning: start)
    } catch {
      fail(id, error: error)
      var start = AccountAuthorizationStart(
        flowID: id, authorizationURL: "", expiresInSeconds: remaining(id))
      start.method = .device
      start.failureCode = flows[id]?.failureCode ?? "authorization_failed"
      response.resume(returning: start)
      throw error
    }
    while true {
      try checkPending(id)
      // Race sleep/network against the actual remaining lifetime, also when no frontend reads status.
      let grant = try await withThrowingTaskGroup(of: AccountDeviceGrant?.self) { group in
        defer { group.cancelAll() }
        group.addTask { [provider, pollWait] in
          try await pollWait(.seconds(device.intervalSeconds))
          try Task.checkCancellation()
          return try await provider.pollDeviceCode(device)
        }
        let duration = now().duration(to: flows[id]!.deadline)
        group.addTask {
          try await Task.sleep(for: duration)
          throw AccountRefreshError.conflict
        }
        return try await group.next()!
      }
      try checkPending(id)
      guard let grant else { continue }
      // Consumed once. A capacity error ends this flow; a grant is never polled/exchanged again.
      guard completions < 4 else { throw AccountRefreshError.capacity }
      completions += 1
      defer { completions -= 1 }
      let verified = try await exchange(
        timeout: min(exchangeTimeout, now().duration(to: flows[id]!.deadline))
      ) {
        [provider] in try await provider.authorizeDevice(grant)
      }
      try checkPending(id)
      let account = try await persist(verified, target: flows[id]!.target)
      flows[id]?.result = .completed
      flows[id]?.accountID = account.id
      flows[id]?.userCode = nil
      return
    }
  }
  private func remaining(_ id: String) -> Int {
    guard let deadline = flows[id]?.deadline else { return 0 }
    let duration = now().duration(to: deadline).components
    return max(0, Int(ceil(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)))
  }
  private func checkPending(_ id: String) throws {
    try Task.checkCancellation()
    guard accepting, let flow = flows[id], flow.result == .pending else {
      throw AccountRefreshError.closed
    }
    guard flow.deadline > now() else { throw AccountRefreshError.conflict }
  }
  private func fail(_ id: String, error: any Error) {
    guard let flow = flows[id], flow.result == .pending else { return }
    flows[id]?.result = flow.deadline <= now() ? .expired : .failed
    flows[id]?.userCode = nil
    flows[id]?.failureCode =
      error is AccountDeviceAuthorizationError
      ? "device_code_unavailable"
      : error as? AccountRefreshError == .conflict || error as? ExecutionError == .conflict
        ? "revision_conflict" : "authorization_failed"
  }
  public func complete(owner: String, flowID: String, callbackURL: String) async throws
    -> ManagedAccount
  {
    guard accepting else { throw AccountRefreshError.closed }
    guard let flow = flows[flowID], flow.owner == owner, flow.method == .callback else {
      throw AccountRefreshError.conflict
    }
    guard completions < 4 else { throw AccountRefreshError.capacity }
    // Consume before parsing; retain the owner record so DELETE can stop an active callback exchange.
    guard flow.result == .pending else { throw AccountRefreshError.conflict }
    flows[flowID]?.result = .failed
    guard flow.deadline > now() else { throw AccountRefreshError.conflict }
    let code: String
    do { code = try Self.code(callbackURL, expectedState: flow.state) } catch {
      flows.removeValue(forKey: flowID)
      throw error
    }
    let (stop, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    active[flowID] = signal
    completions += 1
    defer {
      completions -= 1
      flows.removeValue(forKey: flowID)
      finished(flowID)
    }
    do {
      let verified = try await withThrowingTaskGroup(of: VerifiedAccountAuthorization.self) {
        group in
        defer { group.cancelAll() }
        group.addTask {
          try await self.exchange { [provider = self.provider] in
            try await provider.authorize(
              code: code, verifier: flow.verifier, expectedNonce: flow.nonce)
          }
        }
        group.addTask {
          for await _ in stop { throw AccountRefreshError.closed }
          throw AccountRefreshError.closed
        }
        return try await group.next()!
      }
      try Task.checkCancellation()
      guard accepting, flows[flowID] != nil else { throw AccountRefreshError.closed }
      return try await persist(verified, target: flow.target)
    } catch {
      if error is CancellationError || !accepting { throw AccountRefreshError.closed }
      throw Self.safe(error)
    }
  }
  private func exchange(
    timeout: Duration? = nil,
    _ operation: @escaping @Sendable () async throws -> VerifiedAccountAuthorization
  ) async throws -> VerifiedAccountAuthorization {
    try await withThrowingTaskGroup(of: VerifiedAccountAuthorization.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        try Task.checkCancellation()
        return try await operation()
      }
      group.addTask { [exchangeTimeout] in
        try await Task.sleep(for: timeout ?? exchangeTimeout)
        throw AccountRefreshError.unavailable
      }
      return try await group.next()!
    }
  }
  private func persist(_ verified: VerifiedAccountAuthorization, target: AccountAuthorizationTarget)
    async throws -> ManagedAccount
  {
    switch target {
    case .create:
      return try await application.importVerified(
        id: UUID().uuidString, namespace: verified.namespace, credential: verified.credential)
    case .reauthorize(let id, let revision):
      return try await application.reauthorizeVerified(
        id: id, revision: revision, namespace: verified.namespace, credential: verified.credential)
    }
  }
  private static func safe(_ error: any Error) -> AccountRefreshError {
    if let safe = error as? AccountRefreshError { return safe }
    switch error as? ExecutionError {
    case .conflict: return .conflict
    case .capacity: return .capacity
    case .invalidCommand: return .invalidCommand
    default: return .storageUnavailable
    }
  }
  private static func secret() -> String {
    (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
  }
  private static func code(_ raw: String, expectedState: String) throws -> String {
    guard raw.utf8.count <= 8192, raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
      let url = URLComponents(string: raw),
      url.scheme == "http", url.host == "localhost", url.port == 1455,
      url.path == "/auth/callback", url.user == nil, url.password == nil, url.fragment == nil,
      let items = url.queryItems, (2...3).contains(items.count),
      Set(items.map(\.name)).count == items.count,
      Set(items.map(\.name)).subtracting(["state", "code", "scope"]).isEmpty,
      items.first(where: { $0.name == "scope" })?.value?.utf8.count ?? 0 <= 1024,
      items.first(where: { $0.name == "state" })?.value == expectedState,
      let code = items.first(where: { $0.name == "code" })?.value,
      !code.isEmpty, code.utf8.count <= 4096,
      code.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
    else { throw AccountRefreshError.invalidCommand }
    return code
  }
}
