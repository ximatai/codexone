import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import NIOWebSocket
import Testing

@testable import CodexOneAdapters

struct ProtocolFailureDiagnosticsTests {
  private struct Unknown: Error, CustomStringConvertible {
    var description: String { "synthetic-private-marker" }
  }

  @Test func unmappedCausesUseFixedTokens() {
    let cases: [(any Error, String)] = [
      (Unknown(), "other"),
      (ChannelError.ioOnClosedChannel, "channel_closed"),
      (ChannelError.inputClosed, "channel_input_closed"),
      (ChannelError.alreadyClosed, "channel_already_closed"),
      (ChannelError.eof, "channel_eof"),
      (ChannelError.inappropriateOperationForState, "channel_invalid_state"),
      (NIOWebSocketError.invalidFrameLength, "websocket_invalid_frame_length"),
      (NIOWebSocketError.fragmentedControlFrame, "websocket_fragmented_control"),
      (NIOWebSocketError.multiByteControlFrameLength, "websocket_control_length"),
      (HTTPClientError.remoteConnectionClosed, "remoteConnectionClosed"),
      (ExecutionError.conflict, "execution_conflict"),
      (ExecutionError.closed, "execution_closed"),
      (CancellationError(), "cancelled"),
      (IOError(errnoCode: 54, reason: "synthetic-private-marker"), "io_errno_54"),
    ]
    for (error, expected) in cases {
      #expect(ProtocolFailureDiagnostics.causeToken(error) == expected)
    }
  }

  @Test func diagnosticsExcludeUntrustedCodesAndRequestIDs() {
    let metadata = ProtocolFailureDiagnostics.metadata(
      .init(400, "synthetic-secret-must-not-be-logged"),
      requestID: "synthetic-client-controlled-request-id")
    #expect(metadata["code"]?.description == "other")
    #expect(metadata["status"]?.description == "400")
    #expect(metadata["request_id"] == nil)
    #expect(metadata.count == 2)
    let id = UUID().uuidString
    let known = ProtocolFailureDiagnostics.metadata(.init(400, "unsupported_tools"), requestID: id)
    #expect(known["code"]?.description == "unsupported_tools")
    #expect(known["request_id"]?.description == id)
  }

  @Test func diagnosticReasonIsFixedAndNotPublic() throws {
    let error = GatewayProtocolError(400, "unsupported_tools", detail: .toolsImage)
    let metadata = ProtocolFailureDiagnostics.metadata(error, requestID: "untrusted")
    #expect(metadata["reason"]?.description == "tools_image")
    let envelope = protocolErrorEnvelope(error, requestID: UUID().uuidString)
    #expect(envelope["error"]?["code"]?.string == "unsupported_tools")
    #expect(envelope["error"]?["reason"] == nil)
  }

  @Test func diagnosticsDropOverflowUntilMonotonicWindowEnds() {
    var gate = ProtocolFailureLogGate()
    let now = ContinuousClock.now
    for _ in 0..<16 {
      let admitted = gate.admit(now: now)
      #expect(admitted)
    }
    for _ in 0..<100 {
      let admitted = gate.admit(now: now.advanced(by: .seconds(59)))
      #expect(!admitted)
    }
    let boundary = gate.admit(now: now.advanced(by: .seconds(60)))
    #expect(boundary)
    for _ in 0..<15 {
      let admitted = gate.admit(now: now.advanced(by: .seconds(60)))
      #expect(admitted)
    }
    let overflow = gate.admit(now: now.advanced(by: .seconds(60)))
    #expect(!overflow)
  }

  @Test func backendParameterReasonsExcludeValuesAndStayPrivate() throws {
    let cases: [(String, JSONValue, ProtocolRejectionDetail)] = [
      ("max_output_tokens", .number(128), .backendMaxOutputTokens),
      ("temperature", .number(1), .backendTemperature),
      ("top_p", .number(1), .backendTopP),
      ("truncation", .string("synthetic-private-marker"), .backendTruncation),
      ("prompt_cache_retention", .string("synthetic-private-marker"), .backendPromptCacheRetention),
      ("metadata", .object(["private": .string("synthetic-private-marker")]), .backendMetadata),
      ("store", .bool(true), .backendStore),
      ("previous_response_id", .string("synthetic-private-marker"), .backendPreviousResponseID),
    ]
    for (field, value, detail) in cases {
      let request = try ResponseRequest(
        data: JSONValue.object([
          "model": .string("synthetic-text"), "input": .string("synthetic"), field: value,
        ]).data())
      do {
        _ = try request.preparedDocument(contract: .codexSubscription, nativeWebSocket: false)
        Issue.record("Expected a local parameter refusal")
      } catch let error as GatewayProtocolError {
        #expect(error.status == 400 && error.code == "unsupported_backend_parameter")
        #expect(error.detail == detail)
        let metadata = ProtocolFailureDiagnostics.metadata(error, requestID: UUID().uuidString)
        #expect(metadata["reason"]?.description == detail.rawValue)
        #expect(!String(describing: metadata).contains("synthetic-private-marker"))
        let envelope = protocolErrorEnvelope(
          error, requestID: UUID().uuidString, diagnostics: false)
        #expect(envelope["error"]?.object?.count == 4)
        #expect(!String(decoding: try envelope.data(), as: UTF8.self).contains(detail.rawValue))
        // Only the pre-admission diagnostic changes classification.
        #expect(executionFailure(error) == .indeterminate)
      }
    }
    let combined = try ResponseRequest(
      data: JSONValue.object([
        "model": .string("synthetic-text"), "input": .string("synthetic"),
        "store": .bool(true), "previous_response_id": .string("synthetic-private-marker"),
      ]).data())
    #expect(throws: GatewayProtocolError.self) {
      do {
        _ = try combined.preparedDocument(contract: .codexSubscription, nativeWebSocket: false)
      } catch let error as GatewayProtocolError {
        #expect(error.detail == .backendStore)
        throw error
      }
    }
  }

  @Test func nullBackendParametersStillNormalizeWithoutRefusal() throws {
    let fields = [
      "max_output_tokens", "temperature", "top_p", "truncation", "prompt_cache_retention",
      "metadata", "previous_response_id", "service_tier",
    ]
    var body: [String: JSONValue] = [
      "model": .string("synthetic-text"), "input": .string("synthetic"), "store": .bool(false),
    ]
    for field in fields { body[field] = .null }
    let request = try ResponseRequest(data: JSONValue.object(body).data())
    for native in [false, true] {
      let wire = try request.preparedDocument(contract: .codexSubscription, nativeWebSocket: native)
      for field in fields { #expect(wire[field] == nil) }
      #expect(wire["store"]?.bool == false && wire["stream"]?.bool == true)
    }
  }

  @Test func toolReasonsAreFixedAndNeverAddedToPublicEnvelopes() {
    for detail: ProtocolRejectionDetail in [
      .toolsImage, .upstreamTurnLifecycle, .upstreamTurnCreated, .upstreamTurnResponseID,
      .downstreamJSONWrite,
    ] {
      let error = GatewayProtocolError(400, "unsupported_tools", detail: detail)
      let metadata = ProtocolFailureDiagnostics.metadata(error, requestID: UUID().uuidString)
      #expect(metadata["reason"]?.description == detail.rawValue)
      let id = UUID().uuidString
      let envelope = protocolErrorEnvelope(error, requestID: id)
      #expect(envelope["error"]?.object?.count == 4)
      #expect(envelope["error"]?["reason"] == nil)
      #expect(envelope["error"]?["message"]?.string == "Gateway request failed. Reference: \(id).")
    }
    let untrusted = protocolErrorEnvelope(
      GatewayProtocolError(400, "unsupported_tools", detail: .toolsImage), requestID: "untrusted")
    #expect(untrusted["error"]?["message"]?.string == "Gateway request failed.")
  }
  @Test func upstreamWebSocketCloseMetadataIsBoundedAndPrivate() {
    for code: UInt16 in [0, 999, 1000, 1011, 4999, 5000, 65535] {
      let error = GatewayProtocolError(
        502, "execution_indeterminate", detail: .upstreamWebSocketClose,
        upstreamWebSocketCloseCode: code)
      let metadata = ProtocolFailureDiagnostics.metadata(error, requestID: UUID().uuidString)
      #expect(metadata["reason"]?.description == "upstream_websocket_close")
      #expect(
        metadata["upstream_ws_close_code"]?.description
          == ((1000...4999).contains(code) ? String(code) : nil))
      let envelope = protocolErrorEnvelope(error, requestID: UUID().uuidString, diagnostics: false)
      #expect(envelope["error"]?.object?.count == 4)
      #expect(envelope["error"]?["upstream_ws_close_code"] == nil)
      #expect(protocolFailure(error).status == 502)
      #expect(executionFailure(error) == .indeterminate)
    }
  }

  @Test func upstreamStatusRemainsPrivateAndAllErrorsHaveSafeReferences() {
    for status in [400, 401, 403, 407, 429, 503] {
      let error = GatewayProtocolError(502, "upstream_rejected", upstreamStatus: status)
      let id = UUID().uuidString
      let metadata = ProtocolFailureDiagnostics.metadata(error, requestID: id)
      #expect(metadata["code"]?.description == "upstream_rejected")
      #expect(metadata["upstream_status"]?.description == String(status))
      let envelope = protocolErrorEnvelope(error, requestID: id)
      #expect(envelope["error"]?.object?.count == 4)
      #expect(envelope["error"]?["upstream_status"] == nil)
      #expect(envelope["error"]?["message"]?.string == "Gateway request failed. Reference: \(id).")
    }
    for status in [-1, 0, 600] {
      #expect(
        ProtocolFailureDiagnostics.metadata(
          .init(502, "upstream_rejected", upstreamStatus: status), requestID: "untrusted")[
            "upstream_status"] == nil)
    }
  }

}
