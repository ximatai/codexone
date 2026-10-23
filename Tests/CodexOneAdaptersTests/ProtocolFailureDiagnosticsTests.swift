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
}
