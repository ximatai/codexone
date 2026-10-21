public struct ExecutionContext: Sendable {
  public let admission: ExecutionAdmission
  private let store: any ExecutionStore
  init(admission: ExecutionAdmission, store: any ExecutionStore) {
    self.admission = admission
    self.store = store
  }
  /// The caller may expose rawID only after this returns successfully.
  public func bind(_ object: ObjectBinding) async throws {
    try await store.bind(attempt: admission.attempt, object: object)
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
    var evidence: UsageEvidence?
    defer {
      finalizer.handoff(ticket, finalization: .init(attempt: command.attempt, evidence: evidence))
    }
    try Task.checkCancellation()
    guard finalizer.canExecute(ticket) else { throw ExecutionError.capacity }
    evidence = try await operation(.init(admission: command, store: store))
  }
}
