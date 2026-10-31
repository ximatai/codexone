import CodexOneCore
import Foundation

struct ResponsesConfiguration: Sendable {
  let models: [SingleIdentityConfiguration.Model]
  let upstreamBaseURL: String
  let executionTimeoutSeconds: Int?
  let upstreamTransport: String?
  var firstResponseTimeoutSeconds: Int? = nil
  var progressTimeoutSeconds: Int? = nil
  var budget: ExecutionBudget {
    // All entry configurations validate before assembly.
    try! ExecutionBudget(
      total: executionTimeoutSeconds, first: firstResponseTimeoutSeconds,
      idle: progressTimeoutSeconds)
  }
  var budgetSummary: JSONValue {
    func value(_ effective: Int, _ configured: Int?) -> JSONValue {
      .object([
        "seconds": .number(Decimal(effective)),
        "source": .string(configured == nil ? "default" : "configuration"),
      ])
    }
    return .object([
      "total": value(budget.total, executionTimeoutSeconds),
      "first_response": value(budget.first, firstResponseTimeoutSeconds),
      "progress_idle": value(budget.idle, progressTimeoutSeconds),
    ])
  }
  var requestContract: ResponseRequestContract = .responses
  var imageGeneration: ImageConfiguration? = nil
  var clientFingerprint = ClientFingerprint().resolved(models: [])
  var dataConnections = 128
}
extension SingleIdentityConfiguration {
  var responses: ResponsesConfiguration {
    .init(
      models: models, upstreamBaseURL: upstreamBaseURL,
      executionTimeoutSeconds: executionTimeoutSeconds, upstreamTransport: upstreamTransport,
      firstResponseTimeoutSeconds: firstResponseTimeoutSeconds,
      progressTimeoutSeconds: progressTimeoutSeconds,
      requestContract: upstreamContract.flatMap(ResponseRequestContract.init(rawValue:))
        ?? (upstreamBaseURL.hasPrefix("https://") ? .codexSubscription : .responses),
      imageGeneration: imageGeneration,
      clientFingerprint: (clientFingerprint ?? .init()).resolved(models: models),
      dataConnections: dataConnections ?? 128)
  }
}
func validateResponseModels(_ models: [SingleIdentityConfiguration.Model]) throws {
  guard !models.isEmpty, models.count <= 32, Set(models.map(\.id)).count == models.count,
    models.allSatisfy({
      !$0.id.isEmpty && $0.id.utf8.count <= 128
        && (0...500_000_000).contains($0.inputMicrosPerMillion)
        && (0...500_000_000).contains($0.outputMicrosPerMillion)
    }),
    models.allSatisfy({ model in
      if let upstream = model.upstream {
        guard model.catalog == nil, upstream.object != nil,
          let instructions = upstream["base_instructions"]?.string,
          !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          upstream["slug"] == nil || upstream["slug"]?.string == model.id,
          let data = try? upstream.data(), data.count <= 262_144
        else { return false }
        return true
      }
      guard let catalog = model.catalog else { return true }
      let efforts = catalog.reasoningEfforts ?? []
      return (catalog.displayName?.utf8.count ?? 1) > 0
        && (catalog.displayName?.utf8.count ?? 0) <= 128
        && (catalog.description?.utf8.count ?? 0) <= 1024
        && (catalog.baseInstructions == nil
          || (!(catalog.baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true)
            && (catalog.baseInstructions?.utf8.count ?? 0) <= 32_768))
        && (4096...2_000_000).contains(catalog.contextWindow ?? 32_768)
        && ((catalog.contextWindow ?? 32_768)...2_000_000).contains(
          catalog.maxContextWindow ?? catalog.contextWindow ?? 32_768)
        && efforts.count <= 8 && Set(efforts).count == efforts.count
        && efforts.allSatisfy({
          ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains($0)
        })
        && (catalog.defaultReasoningEffort == nil
          || efforts.contains(catalog.defaultReasoningEffort!))
    })
  else { throw ExecutionError.invalidCommand }
}
