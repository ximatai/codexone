import Foundation
import Testing

@testable import CodexOneAdapters

struct ExecutionBudgetTests {
  @Test func timeoutAfterProgressScopeEndsKeepsEventWithoutRemainingTime() async throws {
    let budget = try ExecutionBudget(total: 5, first: 4, idle: 2)
    let trace = ExecutionTimeoutTrace(requestID: UUID().uuidString)
    try await ExecutionDeadlineScope.$trace.withValue(trace) {
      try await withProgressDeadline(budget: budget) { progress in
        progress.note(event: .object(["type": .string("response.created")]))
      }
    }

    trace.capture(.total)
    let observation = try #require(trace.takeObservation())
    #expect(observation.progress?.lastEvent == "response.created")
    #expect(observation.progress?.lastEventAt != nil)
    #expect(observation.progress?.remaining == nil)
    #expect(trace.takeObservation() == nil)
  }

  @Test func earlierNestedTotalDeadlineIsCapturedByTheSharedTrace() async throws {
    let trace = ExecutionTimeoutTrace(requestID: UUID().uuidString)
    do {
      try await withExecutionDeadline(seconds: 4, timeoutTrace: trace) {
        try await withExecutionDeadline(seconds: 1, timeoutTrace: trace) {
          try await Task.sleep(for: .seconds(10))
        }
      }
      Issue.record("Expected nested total deadline")
    } catch let error as GatewayProtocolError {
      #expect(error.code == "execution_deadline_exceeded")
    }
    #expect(trace.takeObservation()?.reason == .total)
  }

  @Test func imageFirstResponseBudgetIsIndependentAndBoundedByTotal() throws {
    let conversation = try ExecutionBudget(total: 1800, first: 120, idle: 300)
    let images = try ExecutionBudget(imagesWith: conversation, first: nil)
    #expect(images.first == 600)
    #expect(images.total == conversation.total && images.idle == conversation.idle)
    #expect(conversation.first == 120)
    #expect(try ExecutionBudget(imagesWith: conversation, first: 1800).first == 1800)
    #expect(try ExecutionBudget(imagesWith: ExecutionBudget(total: 5), first: nil).first == 5)
    for invalid in [0, 1801] {
      #expect(throws: (any Error).self) {
        try ExecutionBudget(imagesWith: conversation, first: invalid)
      }
    }
    #expect(throws: (any Error).self) { try ExecutionBudget(total: 1800, first: 600) }
  }

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
