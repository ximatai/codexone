import Logging
import ServiceLifecycle

public struct GatewayRuntime: Sendable {
  private let services: [any Service]
  public init(services: [any Service]) { self.services = services }

  public func run(handleSignals: Bool = true) async throws {
    var configuration = ServiceGroupConfiguration(
      services: services.map { .init(service: $0) },
      gracefulShutdownSignals: handleSignals ? [.sigterm, .sigint] : [],
      logger: Logger(label: "codexone.runtime"))
    configuration.maximumGracefulShutdownDuration = .seconds(5)
    configuration.maximumCancellationDuration = .seconds(5)
    try await ServiceGroup(configuration: configuration).run()
  }
}
