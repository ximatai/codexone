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
  var models: Set<String> {
    switch self {
    case .single(let policy): policy.models
    case .pool(let policy): policy.models
    }
  }
}
enum ResponsesGateway: Sendable {
  case single(SingleIdentityGateway)
  case pool(AccountPoolGateway, SubscriptionOAuthProvider, SubscriptionDataTarget)
  func execute(
    model: String, references: [ObjectBinding], requestID: String, mode: ExecutionMode,
    operation: @Sendable (ExecutionContext, SubscriptionDataAccess?) async throws -> UsageEvidence?
  ) async throws {
    switch self {
    case .single(let gateway):
      try await gateway.execute(
        model: model, references: references, requestID: requestID, mode: mode
      ) { context in try await operation(context, nil) }
    case .pool(let gateway, let provider, let target):
      try await gateway.execute(
        model: model, references: references, requestID: requestID, mode: mode
      ) { context, work in
        try await operation(context, provider.dataAccess(work: work, target: target))
      }
    }
  }
}
