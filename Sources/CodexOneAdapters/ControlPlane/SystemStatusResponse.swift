import CodexOneCore
import Foundation

public struct SystemStatusResponse: Codable, Sendable, Equatable {
  public struct Check: Codable, Sendable, Equatable {
    public let name: String
    public let ready: Bool
  }

  public let service: String
  public let ready: Bool
  public let checks: [Check]

  public init(report: ReadinessReport) {
    service = "codexone"
    ready = report.isReady
    checks = report.checks.map { Check(name: $0.name, ready: $0.ready) }
  }
}
