import CodexOneCore
import Foundation
import Testing

private func primingObservation(
  _ durations: [Int64], used: Double = 0, remaining: Int64? = nil,
  after: Bool = true, now: Int64 = 1_800_000_000, failure: QuotaObservationFailure? = nil
) throws -> AccountQuotaObservation {
  let windows = try durations.map { duration in
    try SubscriptionQuotaWindow(
      usedPercent: used, durationSeconds: duration,
      resetsAtUnixSeconds: now + (remaining ?? duration),
      resetAfterSeconds: after ? remaining ?? duration : nil)
  }
  return try .init(
    attemptedAtUnixSeconds: now, observedAtUnixSeconds: now,
    quota: .init(limits: [
      .init(
        id: "codex", allowed: true, limitReached: false,
        primary: windows.first, secondary: windows.count > 1 ? windows[1] : nil)
    ]), failure: failure)
}
@Test func quotaPrimingIdleDetectionRequiresCompleteConsistentFreshEvidence() throws {
  let now: Int64 = 1_800_000_000
  for durations: [Int64] in [[18000], [604800], [18000, 604800]] {
    let observation = try primingObservation(durations)
    let detected = QuotaIdleDetection.windows(observation, now: now)
    #expect(detected.count == durations.count)
    #expect(
      detected.values.allSatisfy {
        if case .idle = $0 { return true }
        return false
      })
    #expect(QuotaIdleDetection.windows(observation, now: now + 300).isEmpty)
    #expect(QuotaIdleDetection.windows(observation, now: now - 1).isEmpty)
  }
  for observation in [
    try primingObservation([18000], after: false),
    try primingObservation([12345]), try primingObservation([18000, 18000]),
    try primingObservation([18000], failure: .unavailable),
  ] {
    #expect(QuotaIdleDetection.windows(observation, now: now).isEmpty)
  }
  #expect(
    QuotaIdleDetection.windows(try primingObservation([18000], used: 1), now: now)[.fiveHour]
      == .active(reset: now + 18000))
  #expect(
    QuotaIdleDetection.windows(try primingObservation([604800], remaining: 604000), now: now)[
      .weekly] == .active(reset: now + 604000))
  let inconsistent = try SubscriptionQuotaWindow(
    usedPercent: 0, durationSeconds: 18000,
    resetsAtUnixSeconds: now + 17000, resetAfterSeconds: 18000)
  let obs = try AccountQuotaObservation(
    attemptedAtUnixSeconds: now, observedAtUnixSeconds: now,
    quota: .init(limits: [
      .init(id: "codex", allowed: nil, limitReached: nil, primary: inconsistent, secondary: nil)
    ]), failure: nil)
  #expect(QuotaIdleDetection.windows(obs, now: now).isEmpty)
}
@Test func quotaPrimingSettingsBoundsAndPersistentWindowRearm() throws {
  #expect(try QuotaPrimingSettings().enabled == false)
  #expect(try QuotaPrimingSettings().message == "hello")
  for text in ["", String(repeating: "a", count: 201), "line\nbreak", "a\u{200b}b"] {
    #expect(throws: ExecutionError.invalidCommand) { try QuotaPrimingSettings(message: text) }
  }
  #expect(
    try QuotaPrimingSettings(message: String(repeating: "😀", count: 200)).message.unicodeScalars
      .count == 200)
  let now: Int64 = 1_800_000_000
  var state = try QuotaPrimingState()
  state.settings = try .init(enabled: true)
  var saved = QuotaPrimingWindow()
  saved.awaitingActive = true
  saved.lastAttemptAt = now
  saved.observedResetAt = now + 18000
  state.windows["five_hour"] = saved
  let decoded = try JSONDecoder().decode(QuotaPrimingState.self, from: JSONEncoder().encode(state))
  #expect(
    decoded.eligible(try primingObservation([18000], now: now + 3601), now: now + 3601).isEmpty)
  state.observe(try primingObservation([18000], used: 1), now: now)
  #expect(state.windows["five_hour"]?.awaitingActive == true)
  state.observe(
    try primingObservation([18000], used: 1, remaining: 17000, now: now + 1), now: now + 1)
  #expect(state.windows["five_hour"]?.awaitingActive == false)
  #expect(state.eligible(try primingObservation([18000], now: now + 3600), now: now + 3600).isEmpty)
  #expect(
    state.eligible(try primingObservation([18000], now: now + 18000), now: now + 18000) == [
      .fiveHour
    ])
}
