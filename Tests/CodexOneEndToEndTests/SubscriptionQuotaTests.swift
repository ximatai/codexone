import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

@testable import CodexOneAdapters

private func quotaReply() throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "account_id": "synthetic-workspace", "user_id": "synthetic-private-account-marker",
    "rate_limit": [
      "allowed": true, "limit_reached": false,
      "primary_window": [
        "used_percent": 12.5, "limit_window_seconds": 18000, "reset_at": 2_000_000_000,
      ],
      "secondary_window": [
        "used_percent": 100, "limit_window_seconds": 604800, "reset_at": 2_000_000_100,
      ],
    ],
    "additional_rate_limits": [
      ["metered_feature": "codex_other", "rate_limit": ["primary_window": ["used_percent": 30]]]
    ],
    "credits": ["balance": "synthetic-private-credit-marker"],
  ])
}

@Test(.timeLimit(.minutes(1)))
func quotaUsesOnlyPassiveTrustedGETAndPreservesWindowRolesWithoutPrivateFields() async throws {
  try await withOAuth(timeout: 3000) { h in
    let login = try await h.login()
    let account = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    #expect(account.mode == .disabled)
    let work = try await h.app.prepareObservation(id: account.id)
    h.server.state.mutex.withLock {
      $0.quotaAuthorization = (login.credential.accessToken, "synthetic-workspace")
    }
    h.server.set(.reply(try quotaReply()))
    let provider = try SubscriptionQuotaProvider(
      group: h.group, verifier: h.provider, target: .syntheticLoopback(port: h.server.port))
    let owner = Task { try await GatewayRuntime(services: [provider]).run(handleSignals: false) }
    do {
      try await awaitOAuth { provider.isAccepting }
      let quota = try await provider.observe(work)
      #expect(quota.limits.count == 2)
      #expect(
        quota.limits[0].primary?.usedPercent == 12.5
          && quota.limits[0].secondary?.durationSeconds == 604800)
      #expect(quota.limits[1].primary?.durationSeconds == nil && quota.limits[1].secondary == nil)
      let encoded = String(decoding: try JSONEncoder().encode(quota), as: UTF8.self)
      #expect(
        !encoded.contains("synthetic-private") && !encoded.contains(login.credential.accessToken))
      #expect(h.server.counts.invalid == 0 && h.server.counts.calls == 2)
      await #expect(throws: AccountDispatchError.unavailable) {
        try await h.app.prepareDispatch(id: account.id, continuation: true)
      }
      let production = try SubscriptionQuotaProvider(group: h.group, verifier: h.provider)
      await #expect(throws: QuotaObservationFailure.unavailable) {
        try await production.observe(work)
      }
      #expect(h.server.counts.calls == 2)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    _ = await owner.result
  }
}

@Test(.timeLimit(.minutes(1)))
func quotaRedirectMalformedOversizedAndTotalDeadlineReleaseSocketsWithoutRetry() async throws {
  try await withOAuth(timeout: 3000) { h in
    let login = try await h.login()
    let account = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    let work = try await h.app.prepareObservation(id: account.id)
    h.server.state.mutex.withLock {
      $0.quotaAuthorization = (login.credential.accessToken, "synthetic-workspace")
    }
    let destination = try await OAuthServer.open(group: h.group, plan: .reply(try quotaReply()))
    let provider = try SubscriptionQuotaProvider(
      group: h.group, verifier: h.provider,
      target: .syntheticLoopback(port: h.server.port), timeoutMilliseconds: 500)
    let owner = Task { try await GatewayRuntime(services: [provider]).run(handleSignals: false) }
    do {
      try await awaitOAuth { provider.isAccepting }
      let plans: [OAuthPlan] = [
        .redirect("http://127.0.0.1:\(destination.port)/backend-api/wham/usage"), .oversized,
        .headersStall, .bodyDrip, .reply(Data("{}".utf8), status: 401),
        .reply(Data("{}".utf8), status: 429),
        .reply(Data("{\"account_id\":\"wrong-synthetic-account\"}".utf8)),
        .reply(Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\"wrong\"}}}".utf8)),
      ]
      for plan in plans {
        h.server.set(plan)
        let calls = h.server.counts.calls
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await provider.observe(work) }
        #expect(started.duration(to: .now) < .seconds(2))
        try await awaitOAuth { provider.activeRequests == 0 && h.server.counts.active == 0 }
        #expect(h.server.counts.calls == calls + 1 && destination.counts.calls == 0)
      }
      #expect(h.server.counts.invalid == 0)
    } catch {
      owner.cancel()
      _ = await owner.result
      await destination.close()
      throw error
    }
    owner.cancel()
    _ = await owner.result
    await destination.close()
  }
}
