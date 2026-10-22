import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOPosix

extension ExecutionProbe {
  /// Separate test executable mode; never exposed by codexone or runtime environment configuration.
  static func runAccountAdminUI(
    root: String, web: String, oauthPort: Int, usageFixture: Bool = false
  ) async throws {
    guard root.hasPrefix("/"), web.hasPrefix("/"), (1...65535).contains(oauthPort) else {
      throw ExecutionError.invalidCommand
    }
    let directory = root + "/state"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = try await SQLiteExecutionStore.open(
      path: directory + "/core.sqlite",
      limits: .init(requests: 100, active: 4, unresolved: 4, budgetMicros: 100))
    if usageFixture { try await seedUsageUI(store) }
    let usageReader = try await store.makeUsageReader()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    do {
      let cipher = try await AccountCredentialCipher.load(
        path: root + "/master", adminCredentialPath: root + "/admin")
      let app = AccountCredentials(store: store, protection: cipher)
      let keys = try await KeyAdminAPI.load(
        path: root + "/admin", store: store, availableModels: ["synthetic-text"],
        usage: UsageAdminAPI(querying: usageReader))
      let bundle = try await AdminWebBundle.load(path: web)
      let provider = try SubscriptionOAuthProvider(
        group: group, authority: .syntheticLoopback(port: oauthPort))
      let authorization = try AccountAuthorizationSupervisor(application: app, provider: provider)
      let refreshing = try AccountRefreshSupervisor(application: app, provider: provider)
      let quota = try SubscriptionQuotaProvider.syntheticLoopback(
        group: group, verifier: provider, port: oauthPort)
      let observing = try AccountObservationSupervisor(
        store: store, application: app, refresher: refreshing, provider: quota)
      let accounts = AccountAdminAPI(
        store: store, authorization: authorization, refreshing: refreshing, observing: observing)
      let admin = AdminService(
        group: group, port: 0, reportProvider: { .init(checks: []) }, keys: keys,
        webBundle: bundle, accounts: accounts,
        onBound: { port in
          FileHandle.standardOutput.write(Data("ADMIN_PORT \(port)\n".utf8))
        })
      try await GatewayRuntime(services: [
        provider, quota, authorization, refreshing, observing, admin,
      ]).run()
    } catch {
      await usageReader.close()
      await store.close()
      try await group.shutdownGracefully()
      throw error
    }
    await usageReader.close()
    await store.close()
    try await group.shutdownGracefully()
  }
}
