import Foundation

public struct UsageCursor: Sendable, Equatable {
  public let atUnixSeconds: Int64
  public let id: String
  public init(atUnixSeconds: Int64, id: String) throws {
    guard (0...1_000_000_000_000).contains(atUnixSeconds), (3...260).contains(id.utf8.count),
      id.hasPrefix("a:") || id.hasPrefix("r:"), !id.utf8.contains(0)
    else { throw ExecutionError.invalidCommand }
    self.atUnixSeconds = atUnixSeconds
    self.id = id
  }
}
public struct UsageQuery: Sendable {
  public let startUnixSeconds: Int64
  public let endUnixSeconds: Int64
  public let keyID: String?
  public let model: String?
  public let mode: ExecutionMode?
  public let failure: ExecutionFailure?
  public let failedOnly: Bool
  public let state: ExecutionSnapshot.State?
  public let cursor: UsageCursor?
  public let limit: Int
  public init(
    startUnixSeconds: Int64, endUnixSeconds: Int64, keyID: String? = nil, model: String? = nil,
    mode: ExecutionMode? = nil, failure: ExecutionFailure? = nil, failedOnly: Bool = false,
    state: ExecutionSnapshot.State? = nil, cursor: UsageCursor? = nil, limit: Int = 50
  ) throws {
    guard (0...1_000_000_000_000).contains(startUnixSeconds), endUnixSeconds > startUnixSeconds,
      endUnixSeconds <= 1_000_000_000_000, endUnixSeconds - startUnixSeconds <= 31 * 86400,
      startUnixSeconds % 3600 == 0, endUnixSeconds % 3600 == 0,
      keyID.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) ?? true,
      model.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true,
      (1...100).contains(limit),
      cursor.map({ $0.atUnixSeconds >= startUnixSeconds && $0.atUnixSeconds < endUnixSeconds })
        ?? true
    else { throw ExecutionError.invalidCommand }
    self.startUnixSeconds = startUnixSeconds
    self.endUnixSeconds = endUnixSeconds
    self.keyID = keyID
    self.model = model
    self.mode = mode
    self.failure = failure
    self.failedOnly = failedOnly
    self.state = state
    self.cursor = cursor
    self.limit = limit
  }
}
public struct UsageMetrics: Sendable {
  public let inputTokens: Int64?
  public let outputTokens: Int64?
  public let cachedTokens: Int64?
  public let imageInputTokens: Int64?
  public let imageOutputTokens: Int64?
  public let imageInputTextTokens: Int64?
  public let imageInputImageTokens: Int64?
  public let images: Int64?
  public let estimatedMicros: Int64?
  public init(
    inputTokens: Int64?, outputTokens: Int64?, cachedTokens: Int64?, images: Int64?,
    estimatedMicros: Int64?, imageInputTokens: Int64? = nil, imageOutputTokens: Int64? = nil,
    imageInputTextTokens: Int64? = nil, imageInputImageTokens: Int64? = nil
  ) {
    self.imageInputTokens = imageInputTokens
    self.imageOutputTokens = imageOutputTokens
    self.imageInputTextTokens = imageInputTextTokens
    self.imageInputImageTokens = imageInputImageTokens
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
    self.images = images
    self.estimatedMicros = estimatedMicros
  }
}
public struct UsageTotals: Sendable {
  public let admitted: Int64
  public let rejected: Int64
  public let inFlight: Int64
  public let unknown: Int64
  public let complete: Int64
  public let partial: Int64
  public let unavailable: Int64
  public let failed: Int64
  public let cancelled: Int64
  public let historicalWithoutTime: Int64
  public let unresolvedExposureMicros: Int64
  public let lifetimeInFlight: Int64
  public let lifetimeUnknown: Int64
  public let lifetimeExposureMicros: Int64
  public let metrics: UsageMetrics
  public init(
    admitted: Int64, rejected: Int64, inFlight: Int64, unknown: Int64,
    complete: Int64, partial: Int64, unavailable: Int64, failed: Int64, cancelled: Int64,
    historicalWithoutTime: Int64, unresolvedExposureMicros: Int64,
    lifetimeInFlight: Int64, lifetimeUnknown: Int64, lifetimeExposureMicros: Int64,
    metrics: UsageMetrics
  ) {
    self.admitted = admitted
    self.rejected = rejected
    self.inFlight = inFlight
    self.unknown = unknown
    self.complete = complete
    self.partial = partial
    self.unavailable = unavailable
    self.failed = failed
    self.cancelled = cancelled
    self.historicalWithoutTime = historicalWithoutTime
    self.unresolvedExposureMicros = unresolvedExposureMicros
    self.lifetimeInFlight = lifetimeInFlight
    self.lifetimeUnknown = lifetimeUnknown
    self.lifetimeExposureMicros = lifetimeExposureMicros
    self.metrics = metrics
  }
}
public struct UsageBucket: Sendable {
  public let atUnixSeconds: Int64
  public let admitted: Int64
  public let rejected: Int64
  public let unresolved: Int64
  public init(atUnixSeconds: Int64, admitted: Int64, rejected: Int64, unresolved: Int64) {
    self.atUnixSeconds = atUnixSeconds
    self.admitted = admitted
    self.rejected = rejected
    self.unresolved = unresolved
  }
}
public struct UsageRow: Sendable {
  public enum Kind: String, Sendable { case admitted, rejected }
  public let kind: Kind
  public let id: String
  public let atUnixSeconds: Int64
  public let keyID: String
  public let model: String?
  public let mode: ExecutionMode
  public let accountID: String?
  public let requestID: String?
  public let state: ExecutionSnapshot.State?
  public let outcome: ExecutionOutcome.Kind?
  public let failure: ExecutionFailure?
  public let completeness: UsageEvidence.Completeness?
  public let metrics: UsageMetrics
  public let principal: String?
  public let firstEventMilliseconds: Int64?
  public let totalMilliseconds: Int64?
  public let cursor: UsageCursor
  public init(
    kind: Kind, id: String, atUnixSeconds: Int64, keyID: String, model: String?,
    mode: ExecutionMode,
    accountID: String?, requestID: String?, state: ExecutionSnapshot.State?,
    outcome: ExecutionOutcome.Kind?,
    failure: ExecutionFailure?, completeness: UsageEvidence.Completeness?, metrics: UsageMetrics,
    cursor: UsageCursor, principal: String? = nil, firstEventMilliseconds: Int64? = nil,
    totalMilliseconds: Int64? = nil
  ) {
    self.kind = kind
    self.id = id
    self.atUnixSeconds = atUnixSeconds
    self.keyID = keyID
    self.model = model
    self.mode = mode
    self.accountID = accountID
    self.requestID = requestID
    self.state = state
    self.outcome = outcome
    self.failure = failure
    self.completeness = completeness
    self.metrics = metrics
    self.principal = principal
    self.firstEventMilliseconds = firstEventMilliseconds
    self.totalMilliseconds = totalMilliseconds
    self.cursor = cursor
  }
}
public struct UsageReport: Sendable {
  public let totals: UsageTotals
  public let buckets: [UsageBucket]
  public let rows: [UsageRow]
  public let nextCursor: UsageCursor?
  public init(
    totals: UsageTotals, buckets: [UsageBucket], rows: [UsageRow], nextCursor: UsageCursor?
  ) {
    self.totals = totals
    self.buckets = buckets
    self.rows = rows
    self.nextCursor = nextCursor
  }
}
public struct UsageKeyOption: Sendable {
  public let id: String
  public let principal: String?
  public init(id: String, principal: String?) {
    self.id = id
    self.principal = principal
  }
}
public struct KeyUsageSummary: Sendable {
  public let key: UsageKeyOption
  public let admitted: Int64
  public let failed: Int64
  public let pending: Int64
  public let estimatedMicros: Int64?
  public let lastUsedAtUnixSeconds: Int64?
  public init(
    key: UsageKeyOption, admitted: Int64, failed: Int64, pending: Int64,
    estimatedMicros: Int64?, lastUsedAtUnixSeconds: Int64?
  ) {
    self.key = key
    self.admitted = admitted
    self.failed = failed
    self.pending = pending
    self.estimatedMicros = estimatedMicros
    self.lastUsedAtUnixSeconds = lastUsedAtUnixSeconds
  }
}
public protocol UsageQuerying: Sendable {
  func queryUsage(_ query: UsageQuery) async throws -> UsageReport
  func keyUsage() async throws -> (startUnixSeconds: Int64, keys: [KeyUsageSummary])
  func usageOptions() async throws -> (
    keys: [String], models: [String], keyOptions: [UsageKeyOption]
  )
}
public protocol ExecutionDiagnosticsStore: Sendable {
  func recordRejection(
    requestID: String, keyID: String, model: String?, mode: ExecutionMode, failure: ExecutionFailure
  ) async throws
}
