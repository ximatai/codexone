import CodexOneCore
import Foundation
import Synchronization

/// Capacity-one handoff. The first execution owns its context until its turn finishes;
/// the sibling connection task owns the socket and all subsequent turns.
final class PoolWebSocketStart: Sendable {
  struct Selection: Sendable {
    let context: ExecutionContext
    let authorization: SubscriptionDataAccess?
  }
  private let selections: AsyncThrowingStream<Selection, any Error>
  private let selected: AsyncThrowingStream<Selection, any Error>.Continuation
  private let results: AsyncThrowingStream<Void, any Error>
  private let result: AsyncThrowingStream<Void, any Error>.Continuation
  private let preparedFrame = Mutex<Data?>(nil)
  private let reported = Mutex(
    (finished: false, reported: false, context: ExecutionContext?.none))
  init() {
    (selections, selected) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    (results, result) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }
  func prepareFrame(_ data: Data) throws {
    try UpstreamWebSocketBodyLimit.requireNativeFrame(data)
    preparedFrame.withLock { $0 = data }
  }
  func takeFrame() throws -> Data {
    try preparedFrame.withLock { value in
      guard let data = value else { throw ExecutionError.invalidCommand }
      value = nil
      return data
    }
  }
  func publish(_ selection: Selection) {
    reported.withLock { $0.context = selection.context }
    selected.yield(selection)
    selected.finish()
  }
  func receive() async throws -> Selection {
    var iterator = selections.makeAsyncIterator()
    guard let value = try await iterator.next() else { throw CancellationError() }
    return value
  }
  func waitForTurn() async throws {
    var iterator = results.makeAsyncIterator()
    guard try await iterator.next() != nil else { throw CancellationError() }
  }
  func finishTurn() {
    reported.withLock {
      $0.finished = true
      $0.context = nil
    }
    result.yield(())
    result.finish()
  }
  func close(_ error: any Error) {
    // The socket sibling can throw and cancel the execution owner's deadline group
    // before waitForTurn delivers this error. Preserve evidence before waking either.
    if let context = reported.withLock({ $0.finished ? nil : $0.context }) {
      observeExecutionFailure(error, context: context)
    }
    selected.finish(throwing: error)
    result.finish(throwing: error)
  }
  func claimError() -> Bool {
    reported.withLock { value in
      if value.finished || value.reported { return false }
      value.reported = true
      return true
    }
  }
}

struct PoolWebSocketInitialTurn: Sendable {
  let context: ExecutionContext
  let start: PoolWebSocketStart
  let requestID: String
}

enum PoolWebSocketSession {
  static func run(
    downstream: WebSocketPeer, firstBody: WebSocketBody, first: ResponseRequest,
    executor: HTTPResponseExecution, digest: String?
  ) async throws -> Bool {
    // Bounded by the existing 16 active turns; this session owns all deferred errors.
    let refusals = Mutex<[(error: GatewayProtocolError, requestID: String, lane: String)]>([])
    guard executor.gateway != nil else { throw ExecutionError.unauthorized }
    let start = PoolWebSocketStart()
    let requestID = UUID().uuidString
    let lane = try webSocketLane(JSONValue.decode(firstBody.data))
    do {
      let turnState = try requestTurnState(
        headers: executor.clientHeaders, document: first.document)
      try start.prepareFrame(executor.webSocketFrame(first, lane: lane, turnState: turnState))
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        defer {
          start.close(CancellationError())
          tasks.cancelAll()
        }
        tasks.addTask {
          do {
            try await withExecutionDeadline(seconds: executor.configuration.budget.total) {
              try await executor.executeRouted(
                model: first.model, references: first.references,
                affinityHints: first.affinityHints,
                requestID: requestID,
                mode: first.mode, turnState: turnState, requirements: first.requirements,
                reasoningEffort: first.reasoningEffort, serviceTier: first.serviceTier
              ) { context, authorization in
                try await withExecutionDeadline(
                  seconds: executor.configuration.budget.total
                ) {
                  start.publish(.init(context: context, authorization: authorization))
                  try await start.waitForTurn()
                }
                return nil
              }
            }
          } catch {
            start.close(error)
            if downstream.isClosed { return }
            throw error
          }
        }
        tasks.addTask {
          do {
            let selection = try await start.receive()
            let owner = selection.context.admission.owner
            let pinned =
              selection.authorization == nil
              ? executor
              : executor.pinned(
                to: try .init(id: owner.identity, namespace: owner.namespace))
            try await executor.webSocket.authorized(
              selection.authorization, headers: executor.clientHeaders
            ).run(
              receiveHeaders: {
                await executor.observeResponseHeaders(
                  $0, account: selection.authorization?.identity)
              },
              detachedEvent: { data, lane in
                guard !downstream.isClosed else { return }
                var event = try JSONValue.decode(data).object!
                executor.recordResponseMetadata(
                  .object(event), account: selection.authorization?.identity)
                if !lane.isEmpty { event["stream_id"] = .string(lane) }
                if event["type"]?.string == "error" {
                  try await sendWebSocketError(
                    ProviderObservation.providerFailure(.object(event)),
                    requestID: UUID().uuidString,
                    lane: lane, to: downstream)
                } else {
                  try await downstream.send(ProviderObservation.clientOutput(.object(event)))
                }
              },
              unexpectedResponse: {
                do {
                  try await selection.context.recordUnexpectedExecution()
                  ClientProtocolDiagnostics.record(
                    name: "upstream.lifecycle", outcome: "recorded_unknown",
                    headers: executor.protocolClientHeaders)
                } catch {
                  ClientProtocolDiagnostics.record(
                    name: "upstream.lifecycle", outcome: "unknown_record_failed",
                    headers: executor.protocolClientHeaders)
                  throw error
                }
              }
            ) { upstream in
              try await ResponsesDataService.serveTurns(
                downstream: downstream, upstream: upstream, firstBody: firstBody,
                executor: pinned, digest: digest,
                initial: .init(context: selection.context, start: start, requestID: requestID),
                sizeRefused: { error, requestID, lane in
                  refusals.withLock { $0.append((error, requestID, lane)) }
                })
            }
          } catch {
            start.close(error)
            throw error
          }
        }
        while try await tasks.next() != nil {}
      }
    } catch {
      // Both sibling owners and their command readers have ended before a client can
      // observe the 413 and send a fresh turn. Never replay the refused create.
      let pending = refusals.withLock { $0 }
      if !pending.isEmpty {
        for refusal in pending {
          try await sendWebSocketError(
            refusal.error, requestID: refusal.requestID, lane: refusal.lane, to: downstream)
        }
        return true
      }
      if error is WebSocketUpstreamClosed { return false }
      await executor.recordRejection(first, requestID: requestID, error: error)
      if start.claimError() {
        try? await sendWebSocketError(error, requestID: requestID, lane: lane, to: downstream)
      }
      throw error
    }
    return false
  }
}

func sendWebSocketError(
  _ error: any Error, requestID: String, lane: String, to downstream: WebSocketPeer
) async throws {
  let mapped = protocolFailure(error)
  var envelope: JSONObject = [
    "type": .string("error"), "status": .number(Decimal(mapped.status)),
    "error": protocolErrorEnvelope(error, requestID: requestID)["error"]!,
  ]
  let retryAfter =
    mapped.clientRetryAfter
    ?? (error as? AccountCooldownUnavailable).map { String($0.retryAfter) }
  if let retryAfter, mapped.providerError?["headers"] == nil {
    envelope["headers"] = .object(["retry-after": .string(retryAfter)])
  }
  if !lane.isEmpty { envelope["stream_id"] = .string(lane) }
  try await downstream.send(.object(envelope))
}
