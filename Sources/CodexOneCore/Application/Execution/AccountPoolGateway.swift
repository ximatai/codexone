import Foundation

/// Per-execution structured application work; no detached tasks or unbounded credential cache.
public struct AccountPoolGateway: Sendable {
  private let policy: AccountPoolPolicy
  private let store: any AccountRoutingStore
  private let credentials: AccountCredentials
  private let coordinator: ExecutionCoordinator
  public init(
    policy: AccountPoolPolicy, store: any AccountRoutingStore, credentials: AccountCredentials,
    finalizer: any FinalizationSink
  ) {
    self.policy = policy
    self.store = store
    self.credentials = credentials
    coordinator = ExecutionCoordinator(store: store, finalizer: finalizer)
  }
  public func execute(
    model: String, references: [ObjectBinding], connection: AccountRouteIdentity? = nil,
    requestID: String? = nil, mode: ExecutionMode = .generation,
    operation: @Sendable (ExecutionContext, AccountDispatchWork) async throws -> UsageEvidence?
  ) async throws {
    guard policy.models.contains(model), references.count <= 32 else { throw ExecutionError.denied }
    try await coordinator.executeAccountPool(
      preparing: {
        let affinity = try await store.resolveAccountAffinity(
          principal: policy.key.principal, references: references, connection: connection)
        var works: [AccountRouteIdentity: AccountDispatchWork] = [:]
        var expired = false
        for account in try await store.listAccounts(after: nil) {
          try Task.checkCancellation()
          let identity = try AccountRouteIdentity(id: account.id, namespace: account.namespace)
          guard affinity == nil || affinity == identity,
            account.authorization == .ready,
            account.mode == .enabled || (account.mode == .draining && affinity == identity)
          else { continue }
          do {
            let work = try await credentials.prepareDispatch(
              id: account.id, continuation: affinity == identity)
            works[identity] = work
          } catch AccountDispatchError.refreshRequired { expired = true } catch AccountDispatchError
            .unavailable
          { continue }
        }
        guard !works.isEmpty else {
          throw expired ? AccountDispatchError.refreshRequired : AccountDispatchError.unavailable
        }
        let candidates = try works.values.map { try AccountRouteCandidate(work: $0) }
        let day = Int64(Date().timeIntervalSince1970 / 86_400)
        let command = try AccountPoolAdmission(
          attempt: UUID().uuidString, policy: policy, model: model, window: "utc-day-\(day)",
          requestID: requestID, mode: mode, references: references, connection: connection,
          candidates: candidates)
        return try PreparedAccountPoolAdmission(command: command, credentials: works)
      }, operation: operation)
  }
}
