public struct ReadinessReport: Sendable, Equatable {
  public struct Check: Sendable, Equatable {
    public let name: String
    public let ready: Bool

    public init(name: String, ready: Bool) {
      self.name = name
      self.ready = ready
    }
  }

  public let checks: [Check]
  public var isReady: Bool { !checks.isEmpty && checks.allSatisfy(\.ready) }

  public init(checks: [Check]) { self.checks = checks }

  // No gateway execution is admitted until its actual prerequisites exist.
  public static let unconfigured = ReadinessReport(checks: [
    .init(name: "execution_store", ready: false),
    .init(name: "upstream_accounts", ready: false),
    .init(name: "authorization", ready: false),
  ])
}
