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
  private let turn = Mutex(
    (
      result: Result<Void, any Error>?.none,
      waiter: CheckedContinuation<Void, any Error>?.none,
      cancelSocket: (@Sendable () -> Void)?.none, cancelled: false
    ))
  private let preparedFrame = Mutex<Data?>(nil)
  private let reported = Mutex(
    (finished: false, reported: false, context: ExecutionContext?.none))
  init() {
    (selections, selected) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(1))
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
  /// Cancellation stops the socket owner, but only transport completion releases this waiter.
  func waitForTurn() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiter in
        let result = turn.withLock { state -> Result<Void, any Error>? in
          if let result = state.result { return result }
          state.waiter = waiter
          return nil
        }
        if let result { waiter.resume(with: result) }
      }
    } onCancel: {
      let cancel = self.turn.withLock { state in
        state.cancelled = true
        return state.cancelSocket
      }
      cancel?()
    }
  }
  var socketCancellationRequested: Bool { turn.withLock { $0.cancelled } }

  func attachSocketCancellation(_ cancel: @escaping @Sendable () -> Void) {
    let cancelled = turn.withLock { state in
      state.cancelSocket = cancel
      return state.cancelled
    }
    if cancelled { cancel() }
  }
  func detachSocketCancellation() {
    turn.withLock { $0.cancelSocket = nil }
  }
  private func complete(_ result: Result<Void, any Error>) {
    let waiter = turn.withLock { state in
      guard state.result == nil else { return nil as CheckedContinuation<Void, any Error>? }
      state.result = result
      let waiter = state.waiter
      state.waiter = nil
      return waiter
    }
    waiter?.resume(with: result)
  }
  func finishTurn() {
    reported.withLock {
      $0.finished = true
      $0.context = nil
    }
    complete(.success(()))
  }
  func close(_ error: any Error) {
    // The socket sibling can throw and cancel the execution owner's deadline group
    // before waitForTurn delivers this error. Preserve evidence before waking either.
    if let context = reported.withLock({ $0.finished ? nil : $0.context }) {
      observeExecutionFailure(error, context: context)
    }
    selected.finish(throwing: error)
    complete(.failure(error))
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
    let lifetime = AccountExecutionConnection()
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
                mode: first.mode, turnState: turnState, connectionLifetime: lifetime,
                requirements: first.requirements,
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
          let socket = Task {
            let selection = try await start.receive()
            let owner = selection.context.admission.owner
            let pinned =
              selection.authorization == nil
              ? executor
              : executor.pinned(
                to: try .init(id: owner.identity, namespace: owner.namespace), lifetime: lifetime)
            try await executor.webSocket.authorized(
              selection.authorization, headers: executor.clientHeaders
            ).run(
              diagnosticContext: selection.context,
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
          }
          start.attachSocketCancellation { socket.cancel() }
          defer { start.detachSocketCancellation() }
          do {
            try await withTaskCancellationHandler {
              try await socket.value
            } onCancel: {
              socket.cancel()
            }
            // The connection can close without throwing before a first turn finishes.
            start.close(CancellationError())
          } catch {
            start.close(error)
            // A cancelled first-turn waiter is still joining this socket. Let its
            // deadline or force-stop error win over errors from socket teardown.
            if start.socketCancellationRequested || lifetime.isRetired { return }
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
