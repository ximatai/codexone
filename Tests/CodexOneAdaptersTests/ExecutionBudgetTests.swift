import Foundation
import Testing

@testable import CodexOneAdapters

struct ExecutionBudgetTests {
  @Test func uploadDoesNotSpendFirstResponseBudget() async throws {
    let budget = try ExecutionBudget(total: 5, first: 1, idle: 1)
    let start = ContinuousClock.now
    do {
      let _: Bool = try await withProgressDeadline(budget: budget) { progress in
        try await Task.sleep(for: .milliseconds(1300))
        progress.requestSent()
        // A repeated completion must not extend the first-response deadline.
        try await Task.sleep(for: .milliseconds(700))
        progress.requestSent()
        try await Task.sleep(for: .seconds(3))
        return true
      }
      Issue.record("Expected first-response timeout")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "execution_first_response_timeout")
      #expect(start.duration(to: .now) >= .milliseconds(2300))
      #expect(start.duration(to: .now) < .milliseconds(2900))
    }
  }

  @Test func earlyEventKeepsIdleDeadlineAfterUpload() async throws {
    let budget = try ExecutionBudget(total: 5, first: 4, idle: 1)
    do {
      let _: Bool = try await withProgressDeadline(budget: budget) { progress in
        progress.note()
        try await Task.sleep(for: .milliseconds(500))
        progress.requestSent()
        try await Task.sleep(for: .seconds(3))
        return true
      }
      Issue.record("Expected idle timeout")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "execution_progress_timeout")
    }
  }
}
