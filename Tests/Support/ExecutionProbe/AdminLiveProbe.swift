import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOPosix
import ServiceLifecycle

extension ExecutionProbe {
  /// Real SQLite projection at legal field/count boundaries, driven by synthetic first events.
  static func runAdminLiveProbe(root: String) async throws {
    let store = try await SQLiteExecutionStore.open(
      path: root + "/core.sqlite",
      limits: .init(
        requests: 1_000_000, active: 1_000_000, unresolved: 1_000_000, budgetMicros: 1_000_000))
    let model = String(repeating: "m", count: 128)
    let master = URL(fileURLWithPath: root + "/master")
    try Data(String(repeating: "5a", count: 32).utf8).write(
      to: master, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: master.path)
    let cipher = try await AccountCredentialCipher.load(
      path: root + "/master", adminCredentialPath: root + "/admin")
    let credentials = AccountCredentials(store: store, protection: cipher)
    for index in 0..<64 {
      let account = try await credentials.importVerified(
        id: "synthetic-account-\(index)", namespace: "synthetic/account/\(index)",
        credential: syntheticAccountCredential(version: 1))
      _ = try await store.setAccountDisplayName(
        id: account.id, revision: account.revision,
        displayName: String(repeating: "a", count: 60) + "\(index)")
    }
    let policy = try KeyPolicy(
      models: [model],
      limits: .init(
        requests: nil, active: 1, unresolved: nil, budgetMicros: nil, unresolvedMicros: nil))
    for index in 0..<256 {
      var key = try await store.createKey(
        id: "synthetic-key-\(index)", principal: "synthetic-principal-\(index)",
        digest: String(format: "%064x", index + 1), policy: policy)
      key = try await store.setKeyExpiration(
        id: key.id, revision: key.revision,
        expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 3600)
      key = try await store.setKeyDisplayName(
        id: key.id, revision: key.revision,
        displayName: String(repeating: "k", count: 60) + "\(index)")
      let attempt = String(repeating: "a", count: 250) + String(index)
      try await store.admit(
        .init(
          attempt: attempt,
          owner: .init(
            principal: key.principal, key: key.id, namespace: "synthetic",
            identity: String(repeating: "i", count: 250) + String(index / 16)),
          window: "synthetic", policyVersion: "1", pricingVersion: "1", reservedMicros: 0,
          keyRevision: key.revision, model: model,
          reasoningEffort: String(repeating: "r", count: 32)))
      if index >= 200 {
        try await store.finalize(
          attempt: attempt,
          evidence: .init(
            revision: 1, inputTokens: 1, outputTokens: 1, cachedTokens: 0,
            images: 0, estimatedMicros: 0, completeness: .complete),
          outcome: .init(failure: nil, atUnixSeconds: Int64(Date().timeIntervalSince1970)))
      }
    }
    let reader = try await store.makeUsageReader()
    let keys = try await KeyAdminAPI.load(
      path: root + "/admin", store: store, usage: UsageAdminAPI(querying: reader),
      attention: AttentionAdminAPI(reader: reader, storage: store), storageMonitoring: store)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let provider = try SubscriptionOAuthProvider(
      group: group, authority: .syntheticLoopback(port: 1))
    let authorization = try AccountAuthorizationSupervisor(
      application: credentials, provider: provider)
    let refreshing = try AccountRefreshSupervisor(application: credentials, provider: provider)
    let accounts = AccountAdminAPI(
      store: store, authorization: authorization, refreshing: refreshing)
    let overview = AdminService.makeOverview(
      keys: keys, accounts: accounts, activity: store.overviewActivity,
      reportProvider: { .unconfigured }
    )
    let publisher = SyntheticOverviewStorm(store: store)
    let admin = AdminService(
      group: group, port: 0, reportProvider: { .unconfigured }, keys: keys, overview: overview,
      onBound: { port in
        FileHandle.standardOutput.write(Data("ADMIN_PORT \(port)\n".utf8))
      })
    do {
      try await GatewayRuntime(services: [
        provider, authorization, refreshing, publisher, admin,
        OverviewLiveSupervisor(overview: overview),
      ]).run()
    } catch {
      await reader.close()
      await store.close()
      try await group.shutdownGracefully()
      throw error
    }
    await reader.close()
    await store.close()
    try await group.shutdownGracefully()
  }
}
private struct SyntheticOverviewStorm: Service {
  let store: SQLiteExecutionStore
  func run() async throws {
    do {
      try await cancelWhenGracefulShutdown {
        var index = 0
        while !Task.isCancelled {
          try await Task.sleep(for: .milliseconds(100))
          let attempt = "synthetic-storm-\(index)"
          index += 1
          try await store.admit(
            .init(
              attempt: attempt,
              owner: .init(
                principal: "synthetic", key: String(repeating: "k", count: 256),
                namespace: "synthetic", identity: "synthetic-storm"),
              window: "synthetic", policyVersion: "1", pricingVersion: "1", reservedMicros: 0,
              model: "synthetic"))
          try await store.finalize(
            attempt: attempt,
            evidence: .init(
              revision: 1, inputTokens: 1, outputTokens: 1, cachedTokens: 0, images: 0,
              estimatedMicros: 0, completeness: .complete))
        }
      }
    } catch is CancellationError {}
  }
}
