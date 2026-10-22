import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOPosix

extension ExecutionProbe {
  /// Separate test executable mode; never exposed by codexone or runtime environment configuration.
  static func runAccountAdminUI(root: String, web: String, oauthPort: Int) async throws {
    guard root.hasPrefix("/"), web.hasPrefix("/"), (1...65535).contains(oauthPort) else {
      throw ExecutionError.invalidCommand
    }
    let directory = root + "/state"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = try await SQLiteExecutionStore.open(
      path: directory + "/core.sqlite",
      limits: .init(requests: 100, active: 4, unresolved: 4, budgetMicros: 100))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    do {
      let cipher = try await AccountCredentialCipher.load(
        path: root + "/master", adminCredentialPath: root + "/admin")
      let app = AccountCredentials(store: store, protection: cipher)
      let keys = try await KeyAdminAPI.load(path: root + "/admin", store: store)
      let bundle = try await AdminWebBundle.load(path: web)
      let provider = try SubscriptionOAuthProvider(
        group: group, authority: .syntheticLoopback(port: oauthPort))
      let authorization = try AccountAuthorizationSupervisor(application: app, provider: provider)
      let refreshing = try AccountRefreshSupervisor(application: app, provider: provider)
      let accounts = AccountAdminAPI(
        store: store, authorization: authorization, refreshing: refreshing)
      let admin = AdminService(
        group: group, port: 0, reportProvider: { .init(checks: []) }, keys: keys,
        webBundle: bundle, accounts: accounts,
        onBound: { port in
          FileHandle.standardOutput.write(Data("ADMIN_PORT \(port)\n".utf8))
        })
      try await GatewayRuntime(services: [provider, authorization, refreshing, admin]).run()
    } catch {
      await store.close()
      try await group.shutdownGracefully()
      throw error
    }
    await store.close()
    try await group.shutdownGracefully()
  }
}
