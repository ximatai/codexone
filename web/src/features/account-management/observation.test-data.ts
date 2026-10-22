export function observationFixture() { return {
  observing: true,
  quota: { state: "fresh", observedAtUnixSeconds: 1000, attemptedAtUnixSeconds: 1000, ageSeconds: 10, freshForSeconds: 290, failure: null, additionalCount: 0,
    limits: [{ id: "codex", allowed: true, limitReached: false, primary: { usedPercent: 0, durationSeconds: 18000, resetsAtUnixSeconds: 2000 }, secondary: null }] },
  health: { authenticationRejected: false, lastFailure: null, lastFailureAtUnixSeconds: null, cooldownCount: 0, nextCooldownEndsAtUnixSeconds: null, cooldowns: [] },
}; }
