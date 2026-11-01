import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOPosix

extension ExecutionProbe {
  /// Browser-only synthetic assembly: Chrome maps the private origin to this loopback listener.
  /// Socket tests independently cover the second listener and peer filtering. No upstream exists.
  static func runLANAdminUI(root: String, web: String, port: Int) async throws {
    guard root.hasPrefix("/"), web.hasPrefix("/"), (1...65535).contains(port) else {
      throw ExecutionError.invalidCommand
    }
    let store = try await SQLiteExecutionStore.open(
      path: root + "/core.sqlite",
      limits: .init(requests: 100, active: 4, unresolved: 4, budgetMicros: 100))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
      let keys = try await KeyAdminAPI.load(
        path: root + "/admin", store: store,
        publicOrigin: "http://192.168.1.10:\(port)", listenAddress: "192.168.1.10",
        availableModels: ["synthetic-text"])
      let bundle = try await AdminWebBundle.load(path: web)
      let admin = AdminService(
        group: group, port: port, reportProvider: { .unconfigured }, keys: keys,
        webBundle: bundle,
        onBound: { _ in FileHandle.standardOutput.write(Data("LAN_ADMIN_READY\n".utf8)) })
      try await GatewayRuntime(services: [admin]).run()
    } catch {
      await store.close()
      try await group.shutdownGracefully()
      throw error
    }
    await store.close()
    try await group.shutdownGracefully()
  }
}
