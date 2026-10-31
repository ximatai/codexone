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
  private let reported = Mutex((finished: false, reported: false))
  init() {
    (selections, selected) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    (results, result) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }
  func publish(_ selection: Selection) {
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
    reported.withLock { $0.finished = true }
    result.yield(())
    result.finish()
  }
  func close(_ error: any Error) {
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
  ) async throws {
    guard let gateway = executor.gateway else { throw ExecutionError.unauthorized }
    let start = PoolWebSocketStart()
    let requestID = UUID().uuidString
    let lane = try webSocketLane(JSONValue.decode(firstBody.data))
    do {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        defer {
          start.close(CancellationError())
          tasks.cancelAll()
        }
        tasks.addTask {
          do {
            try await gateway.execute(
              model: first.model, references: first.references, affinityHints: first.affinityHints,
              requestID: requestID,
              mode: first.mode, requirements: first.requirements
            ) { context, authorization in
              try await withExecutionDeadline(
                seconds: executor.configuration.budget.total
              ) {
                start.publish(.init(context: context, authorization: authorization))
                try await start.waitForTurn()
              }
              return nil
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
              detachedEvent: { data, lane in
                guard !downstream.isClosed else { return }
                var event = try JSONValue.decode(data).object!
                if !lane.isEmpty { event["stream_id"] = .string(lane) }
                if event["type"]?.string == "error" {
                  try await sendWebSocketError(
                    ProviderObservation.providerFailure(.object(event)),
                    requestID: UUID().uuidString,
                    lane: lane, to: downstream)
                } else {
                  try await downstream.send(ProviderObservation.textOutput(.object(event)))
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
                initial: .init(context: selection.context, start: start, requestID: requestID))
            }
          } catch {
            start.close(error)
            throw error
          }
        }
        while try await tasks.next() != nil {}
      }
    } catch is WebSocketUpstreamClosed {
      // Both sibling owners have ended and handed off their finalization responsibility.
      return
    } catch {
      await executor.recordRejection(first, requestID: requestID, error: error)
      if start.claimError() {
        try? await sendWebSocketError(error, requestID: requestID, lane: lane, to: downstream)
      }
      throw error
    }
  }
}

func sendWebSocketError(
  _ error: any Error, requestID: String, lane: String, to downstream: WebSocketPeer
) async throws {
  var envelope: [String: JSONValue] = [
    "type": .string("error"), "status": .number(Decimal(protocolFailure(error).status)),
    "error": protocolErrorEnvelope(error, requestID: requestID)["error"]!,
  ]
  if !lane.isEmpty { envelope["stream_id"] = .string(lane) }
  try await downstream.send(.object(envelope))
}
