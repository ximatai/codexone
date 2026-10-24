import Foundation
import Testing

@testable import CodexOneAdapters

struct ProtocolFailureDiagnosticsTests {
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
    let error = GatewayProtocolError(400, "unsupported_reasoning", detail: .reasoningMembers)
    let metadata = ProtocolFailureDiagnostics.metadata(error, requestID: "untrusted")
    #expect(metadata["reason"]?.description == "reasoning_members")
    let envelope = protocolErrorEnvelope(error, requestID: UUID().uuidString)
    #expect(envelope["error"]?["code"]?.string == "unsupported_reasoning")
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

  @Test func toolReasonsAreFixedAndNeverAddedToPublicEnvelopes() {
    for detail: ProtocolRejectionDetail in [
      .toolsContainer, .toolsCount, .toolsName, .toolsDescription, .toolsBoolean,
      .toolsNamespace, .toolsMembers, .toolsDuplicate, .toolsGrammar, .toolsType,
      .toolsBuiltinSearch, .toolsDiscovery, .toolsRemoteMCP, .toolsChoice, .toolsPackage,
      .toolsImage, .toolsDescriptionNull, .toolsDescriptionSize,
      .upstreamResponsePolicy, .upstreamResponsePrevious, .upstreamResponseString,
      .upstreamResponseInstructions, .upstreamResponseBoolean, .upstreamResponseCreated,
      .upstreamResponseIncomplete, .upstreamItemType, .upstreamItemStatus, .upstreamItemName,
      .upstreamItemNamespace, .upstreamMessageRole, .upstreamMessageContent,
      .upstreamReasoningContent, .upstreamReasoningSummary, .upstreamOpaqueContext,
      .upstreamUsageContainer,
      .upstreamOutputIdentity, .upstreamOutputValue, .upstreamOutputCapacity,
      .upstreamTurnLifecycle, .upstreamTurnCreated, .upstreamTurnResponseID,
      .upstreamTurnItemID, .upstreamTurnMissingItemID, .upstreamTurnUnknownItemID,
      .upstreamTurnProviderStream, .upstreamTurnProviderError,
      .upstreamTurnProviderReasoningSummary,
      .upstreamTurnProviderAuthentication, .upstreamTurnProviderRateLimit,
      .upstreamUsageCapacity, .upstreamUsageDetails, .upstreamUsageDetailsCapacity,
      .upstreamUsageCount,
      .upstreamTerminalStatus, .upstreamUsageTotal,
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
      GatewayProtocolError(400, "unsupported_tools", detail: .toolsName), requestID: "untrusted")
    #expect(untrusted["error"]?["message"]?.string == "Gateway request failed.")
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
