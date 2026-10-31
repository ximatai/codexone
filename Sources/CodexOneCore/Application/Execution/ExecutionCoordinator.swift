import Foundation
import Synchronization

public struct ExecutionContext: Sendable {
  public func recordUnexpectedExecution() async throws {
    try await store.recordUnexpectedExecution(basedOn: admission.attempt)
  }
  public let admission: ExecutionAdmission
  private let store: any ExecutionStore
  private let observation = UsageObservation()
  private let bound = BoundObjects()
  public func observeProviderEvent() -> Bool { observation.recordProviderEvent() }
  public var hasProviderEvents: Bool { observation.hasProviderEvents }
  public var providerRejectedBeforeOutput: Bool { observation.isProviderRejection }
  init(admission: ExecutionAdmission, store: any ExecutionStore) {
    self.admission = admission
    self.store = store
    (store as? any ExecutionLiveObserving)?.executionStarted(attempt: admission.attempt)
  }
  /// The caller may expose rawID only after this returns successfully.
  /// Repeated objects are bound once; beyond the per-attempt bound later objects stay unbound.
  public func bind(_ object: ObjectBinding) async throws {
    guard bound.claim(object) else { return }
    try await store.bind(attempt: admission.attempt, object: object)
  }
  /// Record trusted usage before writing to downstream; subsequent transport errors cannot erase it.
  public func observeUsage(_ evidence: UsageEvidence) throws { try observation.record(evidence) }
  public func observeUpstreamEvent() {
    observation.recordFirstEvent()
    (store as? any ExecutionLiveObserving)?.executionReceivedFirstEvent(attempt: admission.attempt)
  }
  public func observeOutcome(_ outcome: ExecutionOutcome) throws {
    try outcome.validate()
    try observation.recordOutcome(outcome)
  }
  fileprivate func finishObservation() -> (UsageEvidence?, ExecutionOutcome?) {
    (store as? any ExecutionLiveObserving)?.executionObservationEnded(attempt: admission.attempt)
    return observation.finish()
  }
}

private final class BoundObjects: Sendable {
  static let maximum = 1024
  private let objects = Mutex(Set<ObjectBinding>())
  func claim(_ object: ObjectBinding) -> Bool {
    objects.withLock {
      guard $0.count < Self.maximum || $0.contains(object) else { return false }
      return $0.insert(object).inserted
    }
  }
}

private final class UsageObservation: Sendable {
  private let providerEvents = Mutex(0)
  func recordProviderEvent() -> Bool {
    providerEvents.withLock {
      $0 += 1
      return $0 == 1
    }
  }
  var hasProviderEvents: Bool { providerEvents.withLock { $0 > 0 } }
  private let started = ContinuousClock.now
  private let firstEvent = Mutex<Int64?>(nil)
  private func elapsed() -> Int64 {
    let parts = started.duration(to: .now).components
    return max(0, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
  }
  func recordFirstEvent() { firstEvent.withLock { if $0 == nil { $0 = elapsed() } } }
  private let latest = Mutex(
    (evidence: UsageEvidence?.none, outcome: ExecutionOutcome?.none, sealed: false))
  var isProviderRejection: Bool {
    latest.withLock { $0.evidence?.providerRejectedBeforeOutput == true }
  }
  func recordOutcome(_ outcome: ExecutionOutcome) throws {
    try latest.withLock { value in
      guard !value.sealed else { throw ExecutionError.closed }
      if value.outcome == nil { value.outcome = outcome }
    }
  }
  func finish() -> (UsageEvidence?, ExecutionOutcome?) {
    latest.withLock { value in
      value.sealed = true
      let outcome = value.outcome.flatMap {
        try? ExecutionOutcome(
          failure: $0.failure, atUnixSeconds: $0.atUnixSeconds,
          cooldownSeconds: $0.cooldownSeconds, firstEventMilliseconds: firstEvent.withLock { $0 },
          totalMilliseconds: elapsed())
      }
      return (value.evidence, outcome)
    }
  }
  func record(_ evidence: UsageEvidence) throws {
    guard
      [
        evidence.revision, evidence.inputTokens, evidence.outputTokens, evidence.cachedTokens,
        evidence.images, evidence.estimatedMicros, evidence.imageInputTokens ?? 0,
        evidence.imageOutputTokens ?? 0, evidence.imageInputTextTokens ?? 0,
        evidence.imageInputImageTokens ?? 0,
      ].allSatisfy({ (0...1_000_000_000_000).contains($0) }),
      evidence.cachedTokens <= evidence.inputTokens
    else { throw ExecutionError.invalidCommand }
    try latest.withLock { value in
      guard !value.sealed else { throw ExecutionError.closed }
      if let previous = value.evidence {
        if evidence.revision == previous.revision {
          guard evidence == previous else { throw ExecutionError.conflict }
          return
        }
        let earlier = evidence.revision < previous.revision ? evidence : previous
        let later = evidence.revision > previous.revision ? evidence : previous
        guard later.inputTokens >= earlier.inputTokens, later.outputTokens >= earlier.outputTokens,
          later.cachedTokens >= earlier.cachedTokens, later.images >= earlier.images,
          later.estimatedMicros >= earlier.estimatedMicros,
          (later.imageInputTokens ?? 0) >= (earlier.imageInputTokens ?? 0),
          (later.imageOutputTokens ?? 0) >= (earlier.imageOutputTokens ?? 0),
          (later.imageInputTextTokens ?? 0) >= (earlier.imageInputTextTokens ?? 0),
          (later.imageInputImageTokens ?? 0) >= (earlier.imageInputImageTokens ?? 0),
          earlier.completeness != .complete || later.completeness == .complete
        else { throw ExecutionError.conflict }
        if evidence.revision < previous.revision { return }
      }
      value.evidence = evidence
    }
  }
}

public struct ExecutionCoordinator: Sendable {
  private let store: any ExecutionStore
  private let finalizer: any FinalizationSink
  public init(store: any ExecutionStore, finalizer: any FinalizationSink) {
    self.store = store
    self.finalizer = finalizer
  }

  /// Exactly one operation call after durable intent; errors never transparently replay it.
  public func execute(
    _ command: ExecutionAdmission,
    operation: @Sendable (ExecutionContext) async throws -> UsageEvidence?
  ) async throws {
    try await executeOwned(
      admitting: {
        try await store.admit(command)
        return (command, ())
      }, operation: { context, _ in try await operation(context) })
  }

  public func executeAccountPool(
    preparing: @Sendable () async throws -> PreparedAccountPoolAdmission,
    operation: @Sendable (ExecutionContext, AccountDispatchWork) async throws -> UsageEvidence?
  ) async throws {
    guard let routing = store as? any AccountRoutingStore else {
      throw ExecutionError.invalidCommand
    }
    try await executeOwned(
      admitting: {
        let prepared = try await preparing()
        let admission = try await routing.admitSelectingAccount(prepared.command)
        // Never throw between committing intent and transferring it to the owned context.
        let selected = prepared.credentials.first {
          $0.key.id == admission.owner.identity && $0.key.namespace == admission.owner.namespace
        }?.value
        return (admission, selected)
      },
      operation: { context, work in
        guard let work else { throw ExecutionError.storageUnavailable }
        return try await operation(context, work)
      })
  }

  private func executeOwned<Payload: Sendable>(
    admitting: @Sendable () async throws -> (ExecutionAdmission, Payload),
    operation: @Sendable (ExecutionContext, Payload) async throws -> UsageEvidence?
  ) async throws {
    try Task.checkCancellation()
    let ticket = try finalizer.reserve()
    let admitted: (ExecutionAdmission, Payload)
    do { admitted = try await admitting() } catch {
      finalizer.abandon(ticket)
      throw error
    }
    let context = ExecutionContext(admission: admitted.0, store: store)
    defer {
      let (evidence, outcome) = context.finishObservation()
      finalizer.handoff(
        ticket,
        finalization: .init(attempt: admitted.0.attempt, evidence: evidence, outcome: outcome))
    }
    do {
      try Task.checkCancellation()
      guard finalizer.canExecute(ticket) else { throw ExecutionError.capacity }
      if let terminal = try await operation(context, admitted.1) {
        try context.observeUsage(terminal)
      }
      try context.observeOutcome(
        .init(failure: nil, atUnixSeconds: Int64(Date().timeIntervalSince1970)))
    } catch {
      let failure: ExecutionFailure =
        Task.isCancelled || error is CancellationError ? .clientCancelled : .indeterminate
      try? context.observeOutcome(
        .init(failure: failure, atUnixSeconds: Int64(Date().timeIntervalSince1970)))
      throw error
    }
  }
}
