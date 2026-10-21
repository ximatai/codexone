import Synchronization

public struct ExecutionContext: Sendable {
  public let admission: ExecutionAdmission
  private let store: any ExecutionStore
  private let observation = UsageObservation()
  init(admission: ExecutionAdmission, store: any ExecutionStore) {
    self.admission = admission
    self.store = store
  }
  /// The caller may expose rawID only after this returns successfully.
  public func bind(_ object: ObjectBinding) async throws {
    try await store.bind(attempt: admission.attempt, object: object)
  }
  /// Record trusted usage before writing to downstream; subsequent transport errors cannot erase it.
  public func observeUsage(_ evidence: UsageEvidence) throws { try observation.record(evidence) }
  fileprivate func finishUsage() -> UsageEvidence? { observation.finish() }
}

private final class UsageObservation: Sendable {
  private let latest = Mutex((evidence: UsageEvidence?.none, sealed: false))
  func finish() -> UsageEvidence? {
    latest.withLock { value in
      value.sealed = true
      return value.evidence
    }
  }
  func record(_ evidence: UsageEvidence) throws {
    guard
      [
        evidence.revision, evidence.inputTokens, evidence.outputTokens, evidence.cachedTokens,
        evidence.images, evidence.estimatedMicros,
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
    try Task.checkCancellation()
    let ticket = try finalizer.reserve()
    do { try await store.admit(command) } catch {
      finalizer.abandon(ticket)
      throw error
    }
    let context = ExecutionContext(admission: command, store: store)
    defer {
      finalizer.handoff(
        ticket, finalization: .init(attempt: command.attempt, evidence: context.finishUsage()))
    }
    try Task.checkCancellation()
    guard finalizer.canExecute(ticket) else { throw ExecutionError.capacity }
    if let terminal = try await operation(context) { try context.observeUsage(terminal) }
  }
}
