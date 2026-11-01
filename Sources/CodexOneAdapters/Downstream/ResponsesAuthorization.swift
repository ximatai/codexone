import CodexOneCore

/// Two concrete supported assemblies, with no caller-controlled routing headers or target.
enum ResponsesSource: Sendable {
  case single(SingleIdentityConfiguration)
  case pool(
    AccountPoolConfiguration, AccountCredentials, any AccountDispatchRefreshing,
    SubscriptionOAuthProvider, SubscriptionDataTarget)
  var configuration: ResponsesConfiguration {
    switch self {
    case .single(let config): config.responses
    case .pool(let config, _, _, _, _): config.responses
    }
  }
  var tokenFile: String? {
    switch self {
    case .single(let config): config.upstreamTokenFile
    case .pool: nil
    }
  }

}
enum ResponsesPolicy: Sendable {
  case single(SingleIdentityPolicy)
  case pool(AccountPoolPolicy)
  var capabilities: KeyPolicy? {
    switch self {
    case .single(let policy): policy.capabilities
    case .pool(let policy): policy.key.policy
    }
  }
  var keyID: String {
    switch self {
    case .single(let policy): policy.owner.key
    case .pool(let policy): policy.key.id
    }
  }
  var models: Set<String> {
    switch self {
    case .single(let policy): policy.models
    case .pool(let policy): policy.models
    }
  }
}
enum ResponsesGateway: Sendable {
  case priming(
    ExecutionCoordinator, ExecutionAdmission, AccountDispatchWork, SubscriptionOAuthProvider,
    SubscriptionDataTarget)
  case single(SingleIdentityGateway)
  case pool(AccountPoolGateway, SubscriptionOAuthProvider, SubscriptionDataTarget)
  func execute(
    model: String, references: [ObjectBinding], affinityHints: [ObjectBinding] = [],
    requestID: String, mode: ExecutionMode, connection: AccountRouteIdentity? = nil,
    requirements: ExecutionRequirements = .init(),
    reasoningEffort: String? = nil, serviceTier: String? = nil,
    operation: @Sendable (ExecutionContext, SubscriptionDataAccess?) async throws -> UsageEvidence?
  ) async throws {
    switch self {
    case .priming(let coordinator, let command, let work, let provider, let target):
      guard mode == .priming, model == command.model, references.isEmpty else {
        throw ExecutionError.denied
      }
      try await coordinator.execute(command) { context in
        try await observeExecution(context) {
          try await operation(context, provider.dataAccess(work: work, target: target))
        }
      }
    case .single(let gateway):
      try await gateway.execute(
        model: model, references: references, requestID: requestID, mode: mode,
        requirements: requirements, reasoningEffort: reasoningEffort, serviceTier: serviceTier
      ) { context in
        try await observeExecution(context) { try await operation(context, nil) }
      }
    case .pool(let gateway, let provider, let target):
      try await gateway.execute(
        model: model, references: references, affinityHints: affinityHints,
        connection: connection, requestID: requestID,
        mode: mode, requirements: requirements, reasoningEffort: reasoningEffort,
        serviceTier: serviceTier
      ) { context, work in
        try await observeExecution(context) {
          try await operation(context, provider.dataAccess(work: work, target: target))
        }
      }
    }
  }
}
