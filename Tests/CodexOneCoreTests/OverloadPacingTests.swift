import CodexOneCore
import Testing

@Test func overloadDelayedFinalizationDoesNotRestartElapsedStep() throws {
  var pacing = OverloadPacing()
  pacing.record(now: 1002.5, at: 1000, retryAfter: nil)
  #expect(pacing.persistedUntil == 1001)
  #expect(pacing.remaining(now: 1002.5, persistedUntil: 1001) == 0)
  pacing.record(now: 1003.25, at: 1003, retryAfter: nil)
  #expect(pacing.consecutiveFailures == 2)
  #expect(pacing.persistedUntil == 1006)
  #expect(pacing.remaining(now: 1003.25, persistedUntil: 1006) == 2)
  pacing.record(now: 1005.25, at: 1005, retryAfter: 60)
  #expect(pacing.consecutiveFailures == 2 && pacing.persistedUntil == 1065)
  #expect(pacing.remaining(now: 1005.25, persistedUntil: 1065) == 59.75)
}
