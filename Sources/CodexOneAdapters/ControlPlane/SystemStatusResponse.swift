import CodexOneCore
import Foundation

public struct SystemStatusResponse: Codable, Sendable, Equatable {
  public struct Check: Codable, Sendable, Equatable {
    public let name: String
    public let ready: Bool
  }

  public enum TransportMode: String, Codable, Sendable {
    case loopback
    case lanHTTP = "lan_http"
  }
  public let transportMode: TransportMode
  public let service: String
  public let ready: Bool
  public let checks: [Check]

  public init(report: ReadinessReport, transportMode: TransportMode = .loopback) {
    self.transportMode = transportMode
    service = "codexone"
    ready = report.isReady
    checks = report.checks.map { Check(name: $0.name, ready: $0.ready) }
  }
}
