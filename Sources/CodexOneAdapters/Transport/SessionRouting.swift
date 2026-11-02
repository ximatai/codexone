import CodexOneCore
import Logging
import NIOHTTP1
import Synchronization

extension HTTPResponseExecution {
  /// The adapter translates metadata into a preference; Core still owns every admission decision.
  func executeRouted(
    model: String, references: [ObjectBinding], affinityHints: [ObjectBinding] = [],
    requestID: String, mode: ExecutionMode, turnState: String? = nil,
    connection: AccountRouteIdentity? = nil,
    requirements: ExecutionRequirements = .init(),
    reasoningEffort: String? = nil, serviceTier: String? = nil,
    operation: @Sendable (ExecutionContext, SubscriptionDataAccess?) async throws -> UsageEvidence?
  ) async throws {
    guard let gateway else { throw ExecutionError.unauthorized }
    let required: AccountRouteIdentity?
    if case .pool = gateway, let turnState, let key = currentKeyID {
      required = try turnStateOwners.owner(key: key, token: turnState)
    } else {
      required = nil
    }
    let preferred = currentKeyID.flatMap {
      sessionAffinity.preferred(key: $0, headers: clientHeaders)
    }
    try await gateway.execute(
      model: model, references: references, affinityHints: affinityHints,
      requestID: requestID, mode: mode, preferred: preferred, requiredAccount: required,
      connection: connection,
      requirements: requirements, reasoningEffort: reasoningEffort, serviceTier: serviceTier
    ) { context, authorization in
      if let identity = authorization?.identity, let key = currentKeyID {
        sessionAffinity.observe(key: key, headers: clientHeaders, account: identity)
        let selection: String
        if connection != nil {
          selection = "connection"
        } else if !references.isEmpty {
          selection = "object"
        } else if identity == preferred {
          selection = "session_account"
        } else if preferred != nil {
          selection = "session_not_selected"
        } else {
          selection = "pool"
        }
        RoutingDiagnostics.record(requestID: requestID, account: identity.id, reason: selection)
      }
      return try await operation(context, authorization)
    }
  }

  func observeResponseHeaders(_ headers: HTTPHeaders, account: AccountRouteIdentity?) async {
    let safe = forwardedResponseHeaders(headers)
    if let account, let key = currentKeyID, let token = safe.first(name: "x-codex-turn-state") {
      turnStateOwners.observe(key: key, token: token, account: account)
    }
    await receiveResponseHeaders(safe)
  }
}

private enum RoutingDiagnostics {
  static let logger = Logger(label: "codexone.routing")
  static let gate = Mutex(ProtocolFailureLogGate())
  static func record(requestID: String, account: String, reason: String) {
    guard gate.withLock({ $0.admit(now: .now) }) else { return }
    logger.info(
      "Account selected",
      metadata: [
        "request_id": .string(requestID), "account_id": .string(account),
        "selection": .string(reason),
      ])
  }
}
