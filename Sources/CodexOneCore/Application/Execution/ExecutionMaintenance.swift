/// One bounded transaction per poll; owner must await completion before store shutdown.
public protocol ExecutionMaintaining: Sendable {
  func maintainExecutions(now: Int64) async throws
}
