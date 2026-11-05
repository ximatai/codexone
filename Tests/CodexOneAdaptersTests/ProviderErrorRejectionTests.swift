import Testing

@testable import CodexOneAdapters

@Suite struct ProviderErrorRejectionTests {
  @Test func budgetReachedWithoutStatusIsExplicitRejection() {
    let error = JSONValue.object(["code": .string("budget_reached")])
    #expect(ProviderError.isExplicitRejection(status: nil, error: error))
  }

  @Test func unknownCodeWithoutStatusStaysUnproven() {
    let error = JSONValue.object(["code": .string("synthetic_unknown")])
    #expect(!ProviderError.isExplicitRejection(status: nil, error: error))
  }
}
