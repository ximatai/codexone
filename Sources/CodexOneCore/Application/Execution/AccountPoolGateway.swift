import Foundation

/// Per-execution structured application work; no detached tasks or unbounded credential cache.
public struct AccountPoolGateway: Sendable {
  private let policy: AccountPoolPolicy
  private let store: any AccountRoutingStore
  private let credentials: AccountCredentials
  private let refresher: (any AccountDispatchRefreshing)?
  private let coordinator: ExecutionCoordinator
  public init(
    policy: AccountPoolPolicy, store: any AccountRoutingStore, credentials: AccountCredentials,
    finalizer: any FinalizationSink, refresher: (any AccountDispatchRefreshing)? = nil
  ) {
    self.policy = policy
    self.store = store
    self.credentials = credentials
    self.refresher = refresher
    coordinator = ExecutionCoordinator(store: store, finalizer: finalizer)
  }
  public func execute(
    model: String, references: [ObjectBinding], connection: AccountRouteIdentity? = nil,
    requestID: String? = nil, mode: ExecutionMode = .generation,
    requirements: ExecutionRequirements = .init(),
    operation: @Sendable (ExecutionContext, AccountDispatchWork) async throws -> UsageEvidence?
  ) async throws {
    guard policy.models.contains(model),
      policy.key.policy.allows(model: model, requirements: requirements), references.count <= 32
    else { throw ExecutionError.denied }
    try await coordinator.executeAccountPool(
      preparing: {
        let affinity = try await store.resolveAccountAffinity(
          principal: policy.key.principal, references: references, connection: connection)
        var works: [AccountRouteIdentity: AccountDispatchWork] = [:]
        var refreshable: [ManagedAccount] = []
        for account in try await store.listAccounts(after: nil) {
          try Task.checkCancellation()
          let identity = try AccountRouteIdentity(id: account.id, namespace: account.namespace)
          guard affinity == nil || affinity == identity,
            account.authorization == .ready || account.authorization == .refreshing,
            account.mode == .enabled || (account.mode == .draining && affinity == identity)
          else { continue }
          if account.authorization == .refreshing {
            refreshable.append(account)
            continue
          }
          do {
            let work = try await credentials.prepareDispatch(
              id: account.id, continuation: affinity == identity)
            works[identity] = work
          } catch AccountDispatchError.refreshRequired {
            refreshable.append(account)
          } catch AccountDispatchError
            .unavailable
          { continue } catch ExecutionError.invalidCommand {
            // Isolate a credential that fails local decryption; DB failures still abort the pool.
            continue
          }
        }
        if works.isEmpty, let account = refreshable.sorted(by: { $0.id < $1.id }).first,
          let refresher
        {
          _ = try await refresher.refreshForDispatch(account: account)
          try Task.checkCancellation()
          let work = try await credentials.prepareDispatch(
            id: account.id, continuation: affinity?.id == account.id)
          let identity = try AccountRouteIdentity(
            id: work.account.id, namespace: work.account.namespace)
          works[identity] = work
        }
        guard !works.isEmpty else {
          throw refreshable.isEmpty
            ? AccountDispatchError.unavailable : AccountDispatchError.refreshRequired
        }
        let candidates = try works.values.map { try AccountRouteCandidate(work: $0) }
        let day = Int64(Date().timeIntervalSince1970 / 86_400)
        let command = try AccountPoolAdmission(
          attempt: UUID().uuidString, policy: policy, model: model, window: "utc-day-\(day)",
          requestID: requestID, mode: mode, references: references, connection: connection,
          candidates: candidates, requirements: requirements)
        return try PreparedAccountPoolAdmission(command: command, credentials: works)
      }, operation: operation)
  }
}
