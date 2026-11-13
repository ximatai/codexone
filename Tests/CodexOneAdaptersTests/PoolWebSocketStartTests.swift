import CodexOneCore
import Foundation
import NIOHTTP1
import Synchronization
import Testing

@testable import CodexOneAdapters

private final class StartFinalizer: FinalizationSink, Sendable {
  let results = Mutex<[Finalization]>([])
  var isAccepting: Bool { true }
  func reserve() throws -> UUID { UUID() }
  func canExecute(_ ticket: UUID) -> Bool { true }
  func abandon(_ ticket: UUID) {}
  func handoff(_ ticket: UUID, finalization: Finalization) {
    results.withLock { $0.append(finalization) }
  }
}

@Test(.timeLimit(.minutes(1)), arguments: [400, 403, 401, 429, 503, 0, 407], [false, true])
func poolWebSocketStartPreservesFailureBeforeOwnerCancellation(status: Int, priorEvent: Bool)
  async throws
{
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: .init(requests: 100, active: 8, unresolved: 8, budgetMicros: 1000))
  do {
    let finalizer = StartFinalizer()
    let start = PoolWebSocketStart()
    let parked = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let admission = ExecutionAdmission(
      attempt: "synthetic-start",
      owner: .init(
        principal: "synthetic", key: "synthetic", namespace: "synthetic", identity: "synthetic"),
      window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 10)
    let partial = UsageEvidence(
      revision: 1, inputTokens: 2, outputTokens: 0, cachedTokens: 0, images: 0,
      estimatedMicros: 3, completeness: .partial)
    let owner = Task {
      try await ExecutionCoordinator(store: store, finalizer: finalizer).execute(admission) {
        context in
        try await observeExecution(context) {
          if priorEvent {
            _ = context.observeProviderEvent()
            try context.observeUsage(partial)
          }
          try await withExecutionDeadline(seconds: 60) {
            // Hold the execution owner until its sibling has observed a handshake failure
            // and cancelled it. Neither deadline-group child can deliver the original error.
            await withCheckedContinuation { continuation in
              parked.withLock { $0 = continuation }
              start.publish(.init(context: context, authorization: nil))
            }
            try Task.checkCancellation()
            try await start.waitForTurn()
          }
          return nil
        }
      }
    }
    _ = try await start.receive()
    let failure: GatewayProtocolError
    switch status {
    case 0: failure = .init(502, "upstream_upgrade_rejected")
    case 407:
      failure = .init(502, "upstream_proxy_authentication_required", upstreamStatus: 407)
    default:
      failure = upstreamRejection(status: .init(statusCode: status), headers: ["retry-after": "60"])
    }
    start.close(failure)
    owner.cancel()
    parked.withLock { value in
      let continuation = value
      value = nil
      return continuation
    }?.resume()
    do {
      try await owner.value
      Issue.record("Cancelled execution owner continued")
    } catch is CancellationError {}

    let results = finalizer.results.withLock { $0 }
    #expect(results.count == 1)
    let result = try #require(results.first)
    #expect(result.outcome?.failure == executionFailure(failure))
    #expect(result.outcome?.cooldownSeconds == failure.cooldownSeconds)
    try await store.finalize(
      attempt: admission.attempt, evidence: result.evidence, outcome: result.outcome)
    let snapshot = try await store.snapshot(attempt: admission.attempt)
    let rejected = [400, 403, 401, 429].contains(status) && !priorEvent
    #expect(snapshot.state == (rejected ? .settled : .unknown))
    if rejected {
      let usage = try #require(snapshot.usage)
      #expect(usage.providerRejectedBeforeOutput == true && usage.completeness == .complete)
      #expect(usage.inputTokens == 0 && usage.outputTokens == 0 && usage.cachedTokens == 0)
      #expect(usage.images == 0 && usage.estimatedMicros == 0)
    } else {
      #expect(snapshot.usage == (priorEvent ? partial : nil))
    }
  } catch {
    await store.close()
    throw error
  }
  await store.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [401, 429])
func poolWebSocketForceStopWaitsForTransportAndPreservesRefusal(status: Int) async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let account = try await store.createVerifiedAccount(
    id: "synthetic", namespace: "synthetic",
    envelope: "v1." + String(repeating: "a", count: 32) + "." + String(repeating: "A", count: 64))
  let enabled = try await store.setAccountMode(
    id: account.id, revision: account.revision, mode: .enabled)
  let start = PoolWebSocketStart()
  let finalizer = StartFinalizer()
  let admission = ExecutionAdmission(
    attempt: "synthetic-stop",
    owner: .init(
      principal: "synthetic", key: "synthetic", namespace: "synthetic", identity: "synthetic"),
    window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 10,
    model: "synthetic-text",
    accountSnapshot: try .init(
      revision: enabled.revision, credentialVersion: enabled.credentialVersion,
      accessExpiresAtUnixSeconds: 2_000_000_000, continuation: false))
  let (cancelled, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  start.attachSocketCancellation { signal.yield(()) }
  let request = Task {
    try await ExecutionCoordinator(store: store, finalizer: finalizer).execute(admission) {
      context in
      start.publish(.init(context: context, authorization: nil))
      try await start.waitForTurn()
      return nil
    }
  }
  defer {
    start.close(CancellationError())
    request.cancel()
  }
  _ = try await start.receive()
  let disabled = try await store.setAccountMode(
    id: account.id, revision: enabled.revision, mode: .disabled)
  #expect(try await store.forceStopAccount(id: account.id, revision: disabled.revision) == 1)
  var events = cancelled.makeAsyncIterator()
  _ = await events.next()
  #expect(finalizer.results.withLock { $0.isEmpty })
  #expect(store.accountExecutions?.count(account: account.id) == 1)
  let rejection = upstreamRejection(
    status: .init(statusCode: status), headers: ["retry-after": "60"])
  start.close(rejection)
  await #expect(throws: AccountExecutionStopped.self) { try await request.value }
  #expect(store.accountExecutions?.count(account: account.id) == 0)
  let result = try #require(finalizer.results.withLock { $0.first })
  #expect(result.outcome?.failure == executionFailure(rejection))
  #expect(result.outcome?.cooldownSeconds == rejection.cooldownSeconds)
  #expect(result.evidence?.providerRejectedBeforeOutput == true)
  try await store.configureHealthModels(["synthetic-text"])
  try await store.finalize(
    attempt: admission.attempt, evidence: result.evidence, outcome: result.outcome)
  let health = try await store.accountHealth(id: account.id)
  #expect(health.authenticationRejected == (status == 401))
  #expect(health.cooldowns.first?.failure == (status == 429 ? .rateLimited : nil))
  await store.close()
}
