import CodexOneCore
import Testing

@Test func readinessRequiresAllPrerequisitesAndANonemptyCheckSet() {
  #expect(!ReadinessReport(checks: []).isReady)
  #expect(
    !ReadinessReport(checks: [
      .init(name: "store", ready: true), .init(name: "authorization", ready: false),
    ]).isReady)
  #expect(ReadinessReport(checks: [.init(name: "store", ready: true)]).isReady)
  #expect(!ReadinessReport.unconfigured.isReady)
}
