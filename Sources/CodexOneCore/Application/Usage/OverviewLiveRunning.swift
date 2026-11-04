/// Read-only observation lifetime. Runtime owns this port; transport and DTOs stay in Adapters.
public protocol OverviewLiveRunning: Sendable {
  func run() async throws
  func shutdown() async
}
