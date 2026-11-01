import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

@testable import CodexOneAdapters

private func syntheticResetList() throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "credits": [
      [
        "id": "synthetic-credit", "reset_type": "future_type", "status": "future_status",
        "granted_at": "2026-01-01T00:00:00Z", "expires_at": NSNull(), "title": "合成重置卡",
      ]
    ], "available_count": 1,
  ])
}

@Test(.timeLimit(.minutes(1)))
func resetCreditTrustedSocketParsingCodesAndLostResponseRetrySameID() async throws {
  try await withOAuth(timeout: 3000) { h in
    let login = try await h.login()
    let account = try await h.app.importVerified(
      id: "account", namespace: login.namespace, credential: login.credential)
    h.server.state.mutex.withLock {
      $0.quotaAuthorization = (login.credential.accessToken, "synthetic-workspace")
    }
    let provider = try SubscriptionQuotaProvider(
      group: h.group, verifier: h.provider, target: .syntheticLoopback(port: h.server.port),
      timeoutMilliseconds: 500)
    let credits = try ResetCreditSupervisor(
      store: h.store, credentials: h.app, provider: provider, clock: testClock)
    let owner = Task {
      try await GatewayRuntime(services: [provider, credits]).run(handleSignals: false)
    }
    do {
      try await awaitOAuth { provider.isAccepting && credits.isAccepting }
      h.server.set(.reply(try syntheticResetList()))
      let listed = try await credits.listResetCredits(id: account.id)
      #expect(listed.credits.first?.expiresAt == nil && listed.credits.first?.type == "future_type")
      #expect(listed.credits.first?.status == "future_status")
      for code in [
        "reset", "nothing_to_reset", "no_credit", "already_redeemed", "future_provider_code",
      ] {
        h.server.set(.reply(Data("{\"code\":\"\(code)\",\"windows_reset\":0}".utf8)))
        let result = try await credits.consumeResetCredit(
          id: account.id, creditID: "synthetic-credit")
        #expect(result.code.rawValue == (code == "future_provider_code" ? "unknown" : code))
      }
      // The unknown outcome above is reconciled before any different card is admitted.
      h.server.set(.reply(Data("{\"code\":\"already_redeemed\",\"windows_reset\":0}".utf8)))
      _ = try await credits.consumeResetCredit(id: account.id, creditID: nil)
      h.server.set(.redeemWithLostResponse)
      let lost = try await credits.consumeResetCredit(id: account.id, creditID: nil)
      #expect(lost.code == .unknown)
      let original = try await h.store.resetCreditState(id: account.id).intent
      #expect(original != nil)
      let retry = try await credits.consumeResetCredit(id: account.id, creditID: nil)
      #expect(retry.code == .alreadyRedeemed)
      let sent = h.server.state.mutex.withLock { $0.redemptionRequests.suffix(2).map { $0.0 } }
      #expect(sent.count == 2 && sent.allSatisfy { $0 == original?.requestID })
      #expect(try await h.store.resetCreditState(id: account.id).intent == nil)
      #expect(h.server.counts.invalid == 0)
      for plan: OAuthPlan in [
        .oversized, .reply(Data("{\"credits\":[],\"available_count\":129}".utf8)), .headersStall,
      ] {
        h.server.set(plan)
        await #expect(throws: (any Error).self) {
          try await credits.listResetCredits(id: account.id)
        }
        try await awaitOAuth { provider.activeRequests == 0 && h.server.counts.active == 0 }
      }
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    _ = await owner.result
    #expect(credits.activeOperations == 0 && provider.activeRequests == 0)
  }
}

@Test func resetCreditListRejectsOversizedMalformedAndDuplicateEntries() throws {
  let valid = try JSONValue.decode(syntheticResetList())
  #expect(try SubscriptionQuotaProvider.parseResetCredits(valid).availableCount == 1)
  let entry = valid["credits"]!.array![0]
  for list in [Array(repeating: entry, count: 129), [entry, entry]] {
    #expect(throws: QuotaObservationFailure.invalidResponse) {
      try SubscriptionQuotaProvider.parseResetCredits(
        .object(["credits": .array(list), "available_count": .number(1)]))
    }
  }
  for (field, replacement): (String, JSONValue) in [
    ("expires_at", .number(123)), ("granted_at", .string("bad")),
    ("title", .string(String(repeating: "a", count: 513))),
  ] {
    var malformed = entry.object!
    malformed[field] = replacement
    #expect(throws: QuotaObservationFailure.invalidResponse) {
      try SubscriptionQuotaProvider.parseResetCredits(
        .object(["credits": .array([.object(malformed)]), "available_count": .number(1)]))
    }
  }
}
