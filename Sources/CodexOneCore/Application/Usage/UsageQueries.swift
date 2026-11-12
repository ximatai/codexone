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
  public let reasoningEffort: String?
  public let model: String?
  public let mode: ExecutionMode?
  public let failure: ExecutionFailure?
  public let outcome: ExecutionOutcome.Kind?
  public let failedOnly: Bool
  public let rejectedOnly: Bool
  public let rejectionGroup: RejectionGroup?
  public let state: ExecutionSnapshot.State?
  public let cursor: UsageCursor?
  public let limit: Int
  public init(
    startUnixSeconds: Int64, endUnixSeconds: Int64, keyID: String? = nil, model: String? = nil,
    mode: ExecutionMode? = nil, failure: ExecutionFailure? = nil, failedOnly: Bool = false,
    state: ExecutionSnapshot.State? = nil, reasoningEffort: String? = nil,
    outcome: ExecutionOutcome.Kind? = nil,
    cursor: UsageCursor? = nil, limit: Int = 50, rejectedOnly: Bool = false,
    rejectionGroup: RejectionGroup? = nil
  ) throws {
    guard (0...1_000_000_000_000).contains(startUnixSeconds), endUnixSeconds > startUnixSeconds,
      endUnixSeconds <= 1_000_000_000_000, endUnixSeconds - startUnixSeconds <= 31 * 86400,
      startUnixSeconds % 3600 == 0, endUnixSeconds % 3600 == 0,
      keyID.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) ?? true,
      model.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true,
      reasoningEffort.map({ $0 == RequestMetadataValue.sanitize($0) }) ?? true,
      outcome == nil || outcome == .failed,
      rejectionGroup == nil || rejectedOnly,
      (1...100).contains(limit),
      cursor.map({ $0.atUnixSeconds >= startUnixSeconds && $0.atUnixSeconds < endUnixSeconds })
        ?? true
    else { throw ExecutionError.invalidCommand }
    self.startUnixSeconds = startUnixSeconds
    self.endUnixSeconds = endUnixSeconds
    self.keyID = keyID
    self.reasoningEffort = reasoningEffort
    self.model = model
    self.mode = mode
    self.failure = failure
    self.outcome = outcome
    self.failedOnly = failedOnly
    self.rejectedOnly = rejectedOnly
    self.rejectionGroup = rejectionGroup
    self.state = state
    self.cursor = cursor
    self.limit = limit
  }
}
public struct UsageMetrics: Sendable, Encodable {
  public let svgInputTokens: Int64?
  public let svgOutputTokens: Int64?
  public let svgReasoningTokens: Int64?
  public let priceCompleteness: UsageEvidence.PriceCompleteness?
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
    imageInputTextTokens: Int64? = nil, imageInputImageTokens: Int64? = nil,
    svgInputTokens: Int64? = nil, svgOutputTokens: Int64? = nil, svgReasoningTokens: Int64? = nil,
    priceCompleteness: UsageEvidence.PriceCompleteness? = nil
  ) {
    self.svgInputTokens = svgInputTokens
    self.svgOutputTokens = svgOutputTokens
    self.svgReasoningTokens = svgReasoningTokens
    self.priceCompleteness = priceCompleteness
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
  public let usageUnknown: Int64
  public let unknownReasons: [String: Int64]
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
  public let averageFirstEventMilliseconds: Double?
  public let p95FirstEventMilliseconds: Int64?
  public let averageTotalMilliseconds: Double?
  public let metrics: UsageMetrics
  public init(
    admitted: Int64, rejected: Int64, inFlight: Int64, unknown: Int64,
    complete: Int64, partial: Int64, unavailable: Int64, failed: Int64, cancelled: Int64,
    historicalWithoutTime: Int64, unresolvedExposureMicros: Int64,
    lifetimeInFlight: Int64, lifetimeUnknown: Int64, lifetimeExposureMicros: Int64,
    metrics: UsageMetrics, averageFirstEventMilliseconds: Double? = nil,
    p95FirstEventMilliseconds: Int64? = nil, averageTotalMilliseconds: Double? = nil,
    usageUnknown: Int64 = 0, unknownReasons: [String: Int64] = [:]
  ) {
    self.usageUnknown = usageUnknown
    self.unknownReasons = unknownReasons
    self.averageFirstEventMilliseconds = averageFirstEventMilliseconds
    self.p95FirstEventMilliseconds = p95FirstEventMilliseconds
    self.averageTotalMilliseconds = averageTotalMilliseconds
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
public enum RejectionReason: String, Sendable, CaseIterable {
  case backendMaxOutputTokens = "backend_parameter_max_output_tokens"
  case backendTemperature = "backend_parameter_temperature"
  case backendTopP = "backend_parameter_top_p"
  case backendTruncation = "backend_parameter_truncation"
  case backendPromptCacheRetention = "backend_parameter_prompt_cache_retention"
  case backendMetadata = "backend_parameter_metadata"
  case backendStore = "backend_parameter_store"
  case backendPreviousResponseID = "backend_parameter_previous_response_id"
  case invalidRequest = "invalid_request"
  case conversationTooLarge = "conversation_too_large"
  case invalidTurnState = "invalid_turn_state"
  case conflictingTurnState = "conflicting_turn_state"
  case invalidClientMetadata = "invalid_client_metadata"
  case accountCooldown = "account_cooldown"
  case accountDispatchUnavailable = "account_dispatch_unavailable"
  case accountRefreshRequired = "account_refresh_required"
  case accountAuthorizationRequired = "account_authorization_required"
  case accountRefreshCapacity = "account_refresh_capacity"
  case accountStateChanged = "account_state_changed"
  case accountRefreshUnavailable = "account_refresh_unavailable"
  case continuationOwnerUnavailable = "continuation_owner_unavailable"

  public enum Stage: String, Sendable {
    case validation, routing
  }

  public var stage: Stage {
    switch self {
    case .accountCooldown, .accountDispatchUnavailable, .accountRefreshRequired,
      .accountAuthorizationRequired, .accountRefreshCapacity, .accountStateChanged,
      .accountRefreshUnavailable, .continuationOwnerUnavailable:
      .routing
    default:
      .validation
    }
  }
}

public struct UsageRow: Sendable {
  public enum Kind: String, Sendable { case admitted, rejected }
  public let svgAuthorModel: String?
  public let usageMissingReasons: [String]
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
  public let rejectionReason: RejectionReason?
  public let upstreamIncompleteReason: UpstreamIncompleteReason?
  public let completeness: UsageEvidence.Completeness?
  public let metrics: UsageMetrics
  public let displayName: String?
  public let principal: String?
  public let firstEventMilliseconds: Int64?
  public let totalMilliseconds: Int64?
  public let reasoningEffort: String?
  public let serviceTier: String?
  public let actualServiceTier: String?
  public let requestMetadataRecorded: Bool
  public let cursor: UsageCursor
  public init(
    kind: Kind, id: String, atUnixSeconds: Int64, keyID: String, model: String?,
    mode: ExecutionMode,
    accountID: String?, requestID: String?, state: ExecutionSnapshot.State?,
    outcome: ExecutionOutcome.Kind?,
    failure: ExecutionFailure?, completeness: UsageEvidence.Completeness?, metrics: UsageMetrics,
    cursor: UsageCursor, principal: String? = nil, displayName: String? = nil,
    firstEventMilliseconds: Int64? = nil,
    totalMilliseconds: Int64? = nil, reasoningEffort: String? = nil,
    serviceTier: String? = nil, actualServiceTier: String? = nil,
    requestMetadataRecorded: Bool = false, svgAuthorModel: String? = nil,
    usageMissingReasons: [String] = [], upstreamIncompleteReason: UpstreamIncompleteReason? = nil,
    rejectionReason: RejectionReason? = nil
  ) {
    self.svgAuthorModel = svgAuthorModel
    self.usageMissingReasons = usageMissingReasons
    self.reasoningEffort = reasoningEffort
    self.serviceTier = serviceTier
    self.actualServiceTier = actualServiceTier
    self.requestMetadataRecorded = requestMetadataRecorded
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
    self.rejectionReason = rejectionReason
    self.upstreamIncompleteReason = upstreamIncompleteReason
    self.completeness = completeness
    self.metrics = metrics
    self.displayName = displayName
    self.principal = principal
    self.firstEventMilliseconds = firstEventMilliseconds
    self.totalMilliseconds = totalMilliseconds
    self.cursor = cursor
  }
}
public struct RejectionGroup: Sendable {
  public let failure: ExecutionFailure
  public let reason: RejectionReason?

  public init?(filter: String) {
    let parts = filter.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let failure = ExecutionFailure(rawValue: String(parts[0]))
    else { return nil }
    let reason = RejectionReason(rawValue: String(parts[1]))
    guard reason != nil || parts[1] == "unrecorded" else { return nil }
    self.failure = failure
    self.reason = reason
  }
}

public struct RejectionCount: Sendable {
  public let failure: ExecutionFailure
  public let reason: RejectionReason?
  public let count: Int64
  public init(failure: ExecutionFailure, reason: RejectionReason?, count: Int64) {
    self.failure = failure
    self.reason = reason
    self.count = count
  }
}
public struct UsageReport: Sendable {
  public let rejectionCounts: [RejectionCount]
  public let totals: UsageTotals
  public let buckets: [UsageBucket]
  public let rows: [UsageRow]
  public let nextCursor: UsageCursor?
  public init(
    totals: UsageTotals, buckets: [UsageBucket], rows: [UsageRow], nextCursor: UsageCursor?,
    rejectionCounts: [RejectionCount] = []
  ) {
    self.totals = totals
    self.buckets = buckets
    self.rejectionCounts = rejectionCounts
    self.rows = rows
    self.nextCursor = nextCursor
  }
}
public struct UsageKeyOption: Sendable {
  public let archived: Bool
  public let id: String
  public let displayName: String?
  public let principal: String?
  public init(id: String, principal: String?, displayName: String? = nil, archived: Bool = false) {
    self.archived = archived
    self.id = id
    self.displayName = displayName
    self.principal = principal
  }
}
public struct KeyUsageSummary: Sendable {
  public let images: Int64?
  public let inputTokens: Int64?
  public let cachedTokens: Int64?
  public let cacheUsageIncomplete: Bool
  public let enabled: Bool
  public let tokens: Int64
  public let tokenUsageIncomplete: Bool
  public let key: UsageKeyOption
  public let admitted: Int64
  public let inFlight: Int64
  public let succeeded: Int64
  public let cancelled: Int64
  public let failed: Int64
  public let pending: Int64
  public let estimatedMicros: Int64?
  public let lastUsedAtUnixSeconds: Int64?
  public init(
    key: UsageKeyOption, admitted: Int64, failed: Int64, pending: Int64,
    estimatedMicros: Int64?, lastUsedAtUnixSeconds: Int64?,
    succeeded: Int64, cancelled: Int64, inFlight: Int64, enabled: Bool = true, tokens: Int64 = 0,
    tokenUsageIncomplete: Bool = true, inputTokens: Int64? = nil, cachedTokens: Int64? = nil,
    cacheUsageIncomplete: Bool = true, images: Int64? = nil
  ) {
    self.images = images
    self.inputTokens = inputTokens
    self.cachedTokens = cachedTokens
    self.cacheUsageIncomplete = cacheUsageIncomplete
    self.enabled = enabled
    self.tokens = tokens
    self.tokenUsageIncomplete = tokenUsageIncomplete
    self.key = key
    self.admitted = admitted
    self.inFlight = inFlight
    self.succeeded = succeeded
    self.cancelled = cancelled
    self.failed = failed
    self.pending = pending
    self.estimatedMicros = estimatedMicros
    self.lastUsedAtUnixSeconds = lastUsedAtUnixSeconds
  }
}
public protocol UsageQuerying: Sendable {
  func dailyUsage(days: Int, keyID: String?, model: String?, endUnixSeconds: Int64?) async throws
    -> [DailyUsageBucket]
  func dailyUsage(days: Int, keyID: String?, model: String?) async throws -> [DailyUsageBucket]
  func inFlightUsage(limit: Int) async throws -> [InFlightUsageRow]
  func queryUsage(_ query: UsageQuery) async throws -> UsageReport
  func keyUsage(includeArchived: Bool) async throws -> (
    startUnixSeconds: Int64, keys: [KeyUsageSummary]
  )
  func usageOptions() async throws -> (
    keys: [String], models: [String], keyOptions: [UsageKeyOption]
  )
}
public protocol ExecutionDiagnosticsStore: Sendable {
  func recordRejection(
    requestID: String, keyID: String, model: String?, mode: ExecutionMode,
    failure: ExecutionFailure,
    reason: RejectionReason?
  ) async throws
}

extension ExecutionDiagnosticsStore {
  public func recordRejection(
    requestID: String, keyID: String, model: String?, mode: ExecutionMode, failure: ExecutionFailure
  ) async throws {
    try await recordRejection(
      requestID: requestID, keyID: keyID, model: model, mode: mode, failure: failure, reason: nil)
  }
}

public struct DailyUsageBucket: Sendable {
  public let usageUnknown: Int64
  public let unknownReasons: [String: Int64]
  public let atUnixSeconds: Int64
  public let requests: Int64
  public let recordedRejections: Int64
  public let succeeded: Int64
  public let failed: Int64
  public let cancelled: Int64
  public let failures: [String: Int64]
  public let metrics: UsageMetrics
  public init(
    atUnixSeconds: Int64, requests: Int64, succeeded: Int64, failed: Int64,
    cancelled: Int64, failures: [String: Int64], metrics: UsageMetrics, usageUnknown: Int64 = 0,
    unknownReasons: [String: Int64] = [:], recordedRejections: Int64 = 0
  ) {
    self.usageUnknown = usageUnknown
    self.unknownReasons = unknownReasons
    self.atUnixSeconds = atUnixSeconds
    self.requests = requests
    self.recordedRejections = recordedRejections
    self.succeeded = succeeded
    self.failed = failed
    self.cancelled = cancelled
    self.failures = failures
    self.metrics = metrics
  }
}
public struct InFlightUsageRow: Sendable, Encodable {
  public let id: String
  public let keyID: String
  public let displayName: String?
  public let principal: String?
  public let model: String?
  public let reasoningEffort: String?
  public let requestMetadataRecorded: Bool?
  public let mode: ExecutionMode
  public let accountID: String
  public let accountDisplayName: String?
  public let startedAtUnixSeconds: Int64?
  public let elapsedSeconds: Int64?
  public let hasFirstEvent: Bool?
  public init(
    id: String, keyID: String, principal: String?, model: String?, mode: ExecutionMode,
    accountID: String, accountDisplayName: String?, startedAtUnixSeconds: Int64?,
    elapsedSeconds: Int64?, hasFirstEvent: Bool?, displayName: String? = nil,
    reasoningEffort: String? = nil, requestMetadataRecorded: Bool? = nil
  ) {
    self.id = id
    self.keyID = keyID
    self.displayName = displayName
    self.principal = principal
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.requestMetadataRecorded = requestMetadataRecorded
    self.mode = mode
    self.accountID = accountID
    self.accountDisplayName = accountDisplayName
    self.startedAtUnixSeconds = startedAtUnixSeconds
    self.elapsedSeconds = elapsedSeconds
    self.hasFirstEvent = hasFirstEvent
  }
}
/// Bounded by the existing finalizer ticket capacity; observations have no effect on settlement.
public protocol ExecutionLiveObserving: Sendable {
  func executionStarted(attempt: String)
  func executionReceivedFirstEvent(attempt: String)
  func executionObservationEnded(attempt: String)
}

extension UsageQuerying {
  public func keyUsage() async throws -> (startUnixSeconds: Int64, keys: [KeyUsageSummary]) {
    try await keyUsage(includeArchived: true)
  }

  public func dailyUsage(days: Int, keyID: String?, model: String?, endUnixSeconds: Int64?)
    async throws -> [DailyUsageBucket]
  {
    guard endUnixSeconds == nil else { throw ExecutionError.invalidCommand }
    return try await dailyUsage(days: days, keyID: keyID, model: model)
  }
}
