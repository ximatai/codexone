import CodexOneCore
import Foundation

struct ResponsesConfiguration: Sendable {
  let models: [SingleIdentityConfiguration.Model]
  let upstreamBaseURL: String
  let executionTimeoutSeconds: Int?
  let upstreamTransport: String?
}
extension SingleIdentityConfiguration {
  var responses: ResponsesConfiguration {
    .init(
      models: models, upstreamBaseURL: upstreamBaseURL,
      executionTimeoutSeconds: executionTimeoutSeconds, upstreamTransport: upstreamTransport)
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
      guard let catalog = model.catalog else { return true }
      let efforts = catalog.reasoningEfforts ?? []
      return (catalog.displayName?.utf8.count ?? 1) > 0
        && (catalog.displayName?.utf8.count ?? 0) <= 128
        && (catalog.description?.utf8.count ?? 0) <= 1024
        && (catalog.baseInstructions == nil
          || (!(catalog.baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true)
            && (catalog.baseInstructions?.utf8.count ?? 0) <= 32_768))
        && (4096...131_072).contains(catalog.contextWindow ?? 32_768)
        && efforts.count <= 8 && Set(efforts).count == efforts.count
        && efforts.allSatisfy({
          ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains($0)
        })
        && (catalog.defaultReasoningEffort == nil
          || efforts.contains(catalog.defaultReasoningEffort!))
    })
  else { throw ExecutionError.invalidCommand }
}
