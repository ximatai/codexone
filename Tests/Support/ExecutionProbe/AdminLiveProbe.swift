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
    for index in 0..<200 {
      try await store.admit(
        .init(
          attempt: String(repeating: "a", count: 250) + String(index),
          owner: .init(
            principal: "synthetic", key: String(repeating: "k", count: 256), namespace: "synthetic",
            identity: String(repeating: "i", count: 250) + String(index / 16)),
          window: "synthetic", policyVersion: "1", pricingVersion: "1", reservedMicros: 0,
          model: String(repeating: "m", count: 128),
          reasoningEffort: String(repeating: "r", count: 32)))
    }
    let reader = try await store.makeUsageReader()
    let keys = try await KeyAdminAPI.load(
      path: root + "/admin", store: store, usage: UsageAdminAPI(querying: reader),
      attention: AttentionAdminAPI(reader: reader, storage: store), storageMonitoring: store)
    let overview = AdminService.makeOverview(
      keys: keys, accounts: nil, activity: store.overviewActivity, reportProvider: { .unconfigured }
    )
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let publisher = SyntheticOverviewStorm(store: store)
    let admin = AdminService(
      group: group, port: 0, reportProvider: { .unconfigured }, keys: keys, overview: overview,
      onBound: { port in
        FileHandle.standardOutput.write(Data("ADMIN_PORT \(port)\n".utf8))
      })
    do {
      try await GatewayRuntime(services: [
        publisher, admin, OverviewLiveSupervisor(overview: overview),
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
        while !Task.isCancelled {
          try await Task.sleep(for: .milliseconds(100))
          store.executionReceivedFirstEvent(attempt: String(repeating: "a", count: 250) + "0")
        }
      }
    } catch is CancellationError {}
  }
}
