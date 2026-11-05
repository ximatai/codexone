import Foundation
import Testing

@testable import CodexOneAdapters

struct ExecutionBudgetTests {
  @Test func imageUploadStallUsesProgressDeadline() async throws {
    let budget = try ExecutionBudget(total: 5, first: 4, idle: 1)
    do {
      let _: Bool = try await withProgressDeadline(budget: budget) { progress in
        progress.noteUpload()
        try await Task.sleep(for: .seconds(3))
        return true
      }
      Issue.record("Expected upload progress timeout")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "execution_progress_timeout")
    }
  }

  @Test func imageUploadEOFSwitchesFromProgressToFirstResponse() async throws {
    let budget = try ExecutionBudget(total: 5, first: 2, idle: 1)
    let start = ContinuousClock.now
    do {
      let _: Bool = try await withProgressDeadline(budget: budget) { progress in
        progress.noteUpload()
        try await Task.sleep(for: .milliseconds(600))
        progress.noteUpload()
        try await Task.sleep(for: .milliseconds(600))
        progress.requestSent()
        try await Task.sleep(for: .milliseconds(1400))
        progress.requestSent()
        try await Task.sleep(for: .seconds(2))
        return true
      }
      Issue.record("Expected first-response timeout")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "execution_first_response_timeout")
      #expect(start.duration(to: .now) >= .milliseconds(3200))
      #expect(start.duration(to: .now) < .milliseconds(3800))
    }
  }

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
        progress.noteUpload()
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
