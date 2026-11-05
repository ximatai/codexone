import CodexOneCore
import ServiceLifecycle

public struct OverviewLiveSupervisor: Service {
  private let overview: any OverviewLiveRunning
  public init(overview: any OverviewLiveRunning) { self.overview = overview }
  public func run() async throws {
    await withTaskCancellationHandler {
      do { try await cancelWhenGracefulShutdown { try await overview.run() } } catch {}
      await overview.shutdown()
    } onCancel: {
    }
  }
}
