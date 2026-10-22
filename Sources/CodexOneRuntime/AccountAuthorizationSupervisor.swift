import CodexOneCore
import Foundation
import ServiceLifecycle

/// Owns ephemeral authorization secrets; complete's structured task owns each exchange.
public actor AccountAuthorizationSupervisor: Service, AccountAuthorizing {
  private struct Flow: Sendable {
    let owner: String
    let state: String
    let nonce: String
    let verifier: String
    let target: AccountAuthorizationTarget
    let deadline: ContinuousClock.Instant
  }
  private let application: AccountCredentials
  private let provider: any AccountAuthorizationProvider
  private let lifetime: Duration
  private let exchangeTimeout: Duration
  private var started = false
  private var accepting = false
  private var flows: [String: Flow] = [:]
  private var active: [String: AsyncStream<Void>.Continuation] = [:]
  private var drained: CheckedContinuation<Void, Never>?
  public var isAccepting: Bool { accepting }

  public init(
    application: AccountCredentials, provider: any AccountAuthorizationProvider,
    lifetime: Duration = .seconds(600), exchangeTimeout: Duration = .seconds(30)
  ) throws {
    guard lifetime > .zero, lifetime <= .seconds(600),
      exchangeTimeout > .zero, exchangeTimeout <= .seconds(30)
    else {
      throw AccountRefreshError.invalidCommand
    }
    self.application = application
    self.provider = provider
    self.lifetime = lifetime
    self.exchangeTimeout = exchangeTimeout
  }
  public func run() async throws {
    guard !started else { throw AccountRefreshError.conflict }
    started = true
    accepting = true
    var failed = false
    do { try await gracefulShutdown() } catch is CancellationError {} catch { failed = true }
    accepting = false
    flows.removeAll()
    for stop in active.values {
      stop.yield(())
      stop.finish()
    }
    if !active.isEmpty {
      await withCheckedContinuation { drained = $0 }
    }
    if failed { throw AccountRefreshError.unavailable }
  }
  public func begin(owner: String, target: AccountAuthorizationTarget) async throws
    -> AccountAuthorizationStart
  {
    guard accepting else { throw AccountRefreshError.closed }
    guard ManagedAccount.validID(owner) else { throw AccountRefreshError.invalidCommand }
    if case .reauthorize(let id, let revision) = target {
      guard ManagedAccount.validID(id), (1...1_000_000).contains(revision) else {
        throw AccountRefreshError.invalidCommand
      }
    }
    flows = flows.filter { $0.value.deadline > .now }
    guard flows.count + active.count < 8 else { throw AccountRefreshError.capacity }
    let state = Self.secret()
    let nonce = Self.secret()
    let verifier = Self.secret()
    let url: String
    do { url = try provider.authorizationURL(state: state, nonce: nonce, verifier: verifier) } catch
    { throw AccountRefreshError.unavailable }
    let id = UUID().uuidString
    flows[id] = Flow(
      owner: owner, state: state, nonce: nonce, verifier: verifier, target: target,
      deadline: .now.advanced(by: lifetime))
    return AccountAuthorizationStart(
      flowID: id, authorizationURL: url,
      expiresInSeconds: Int(lifetime.components.seconds))
  }
  public func discard(owner: String, flowID: String) async {
    if flows[flowID]?.owner == owner { flows.removeValue(forKey: flowID) }
  }
  public func complete(owner: String, flowID: String, callbackURL: String) async throws
    -> ManagedAccount
  {
    guard accepting else { throw AccountRefreshError.closed }
    guard let flow = flows[flowID], flow.owner == owner else {
      throw AccountRefreshError.conflict
    }
    guard active.count < 4 else { throw AccountRefreshError.capacity }
    // Consume before parsing or issuing any POST. Cancellation/error never restores this flow.
    flows.removeValue(forKey: flowID)
    guard flow.deadline > .now else { throw AccountRefreshError.conflict }
    let code = try Self.code(callbackURL, expectedState: flow.state)
    let (stop, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    active[flowID] = signal
    defer {
      signal.finish()
      active.removeValue(forKey: flowID)
      if active.isEmpty {
        drained?.resume()
        drained = nil
      }
    }
    do {
      let verified = try await withThrowingTaskGroup(of: VerifiedAccountAuthorization.self) {
        group in
        defer { group.cancelAll() }
        group.addTask { [provider] in
          try Task.checkCancellation()
          return try await provider.authorize(
            code: code, verifier: flow.verifier, expectedNonce: flow.nonce)
        }
        group.addTask { [exchangeTimeout] in
          try await Task.sleep(for: exchangeTimeout)
          throw AccountRefreshError.unavailable
        }
        group.addTask {
          for await _ in stop { throw AccountRefreshError.closed }
          throw AccountRefreshError.closed
        }
        guard let result = try await group.next() else { throw AccountRefreshError.closed }
        return result
      }
      try Task.checkCancellation()
      guard accepting else { throw AccountRefreshError.closed }
      switch flow.target {
      case .create:
        return try await application.importVerified(
          id: UUID().uuidString, namespace: verified.namespace, credential: verified.credential)
      case .reauthorize(let id, let revision):
        return try await application.reauthorizeVerified(
          id: id, revision: revision, namespace: verified.namespace, credential: verified.credential
        )
      }
    } catch {
      if error is CancellationError || !accepting { throw AccountRefreshError.closed }
      if let safe = error as? AccountRefreshError { throw safe }
      if let error = error as? ExecutionError {
        switch error {
        case .conflict: throw AccountRefreshError.conflict
        case .capacity: throw AccountRefreshError.capacity
        case .invalidCommand: throw AccountRefreshError.invalidCommand
        default: throw AccountRefreshError.storageUnavailable
        }
      }
      throw AccountRefreshError.unavailable
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
