import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

@testable import CodexOneAdapters

@Test(.timeLimit(.minutes(1)))
func modelDiscoveryUsesIndependentVersionAndPreservesNativeProfile() async throws {
  try await withOAuth { h in
    let login = try await h.login()
    let account = try await h.app.importVerified(
      id: "synthetic-discovery", namespace: login.namespace, credential: login.credential)
    _ = try await h.store.setAccountMode(
      id: account.id, revision: account.revision, mode: .enabled)
    h.server.state.mutex.withLock {
      $0.quotaAuthorization = (login.credential.accessToken, "synthetic-workspace")
    }
    let entry: JSONValue = .object([
      "slug": .string("synthetic-next"), "visibility": .string("list"),
      "base_instructions": .string("Synthetic model instructions"),
      "context_window": .number(500_000), "max_context_window": .number(1_000_000),
      "input_modalities": .array([.string("text"), .string("image")]),
      "supported_reasoning_levels": .array([
        .object(["effort": .string("medium")]), .object(["effort": .string("high")]),
      ]),
      "default_reasoning_level": .string("medium"),
      "future_capability": .object(["enabled": .bool(true)]),
    ])
    h.server.set(.reply(try JSONValue.object(["models": .array([entry])]).data()))
    let configuration = try JSONDecoder().decode(
      AccountPoolConfiguration.self,
      from: Data(
        """
        {"models":[{"id":"synthetic-old","inputMicrosPerMillion":0,"outputMicrosPerMillion":0}],
         "reservedMicros":0}
        """.utf8))
    let directory = try await ModelDirectory(
      configuration: configuration, store: h.store, clock: h.store.clock)
    let provider = try SubscriptionQuotaProvider(
      group: h.group, verifier: h.provider, target: .syntheticLoopback(port: h.server.port))
    let owner = Task { try await GatewayRuntime(services: [provider]).run(handleSignals: false) }
    do {
      try await awaitOAuth { provider.isAccepting }
      let found = try await directory.refresh(
        account: account.id, credentials: h.app, provider: provider)
      let candidate = try #require(found["candidates"]?.array?.first)
      #expect(candidate["state"] == .string("candidate"))
      #expect(candidate["visionInput"] == .bool(true))
      _ = try await directory.change(
        .object([
          "model": .string("synthetic-next"), "revision": found["revision"]!,
          "enabled": .bool(true), "candidateRevision": found["candidateRevision"]!,
          "inputMicrosPerMillion": .number(2_000_000),
          "outputMicrosPerMillion": .number(10_000_000),
        ]))
      let saved = try #require(try await h.store.modelDirectorySnapshot()?.active.last)
      #expect(saved.upstream == entry)
      #expect(saved.supportedReasoningEfforts == ["medium", "high"])
      let catalog = try modelCatalog(
        [saved], requireCodexProfile: true, upstreamTransport: "websocket",
        now: h.store.clock.unixSeconds)
      #expect(catalog["models"]?.array?.first?["max_context_window"] == .number(1_000_000))
      #expect(catalog["models"]?.array?.first?["future_capability"] == entry["future_capability"])
      _ = try await directory.changeReasoning(
        .object([
          "model": .string("synthetic-next"), "revision": .number(1),
          "allowedReasoningEfforts": .array([.string("high")]),
          "defaultReasoningEffort": .string("high"),
        ]))
      var updatedEntry = entry.object!
      updatedEntry["context_window"] = .number(750_000)
      h.server.set(.reply(try JSONValue.object(["models": .array([.object(updatedEntry)])]).data()))
      let refreshed = try await directory.refresh(
        account: account.id, credentials: h.app, provider: provider)
      let preview = refreshed["active"]?.array?.last?["profileUpdate"]
      #expect(preview?["contextWindow"] == .number(750_000))
      #expect(preview?["resetReasoningRequired"] == .bool(false))
      await #expect(throws: ExecutionError.conflict) {
        try await directory.changeProfile(
          .object([
            "model": .string("synthetic-next"), "revision": refreshed["revision"]!,
            "candidateRevision": found["candidateRevision"]!,
          ]))
      }
      let command: JSONObject = [
        "model": .string("synthetic-next"), "revision": refreshed["revision"]!,
        "candidateRevision": refreshed["candidateRevision"]!,
      ]
      let applied = try await directory.changeProfile(.object(command))
      #expect(applied["active"]?.array?.last?["profileUpdate"] == nil)
      let preserved = try #require(try await h.store.modelDirectorySnapshot()?.active.last)
      #expect(preserved.inputMicrosPerMillion == saved.inputMicrosPerMillion)
      #expect(preserved.outputMicrosPerMillion == saved.outputMicrosPerMillion)
      #expect(preserved.effectiveReasoningEfforts == ["high"])
      #expect(preserved.effectiveDefaultReasoningEffort == "high")
      await #expect(throws: ExecutionError.conflict) {
        try await directory.changeProfile(.object(command))
      }
      updatedEntry["supported_reasoning_levels"] = .array([
        .object(["effort": .string("medium")])
      ])
      h.server.set(.reply(try JSONValue.object(["models": .array([.object(updatedEntry)])]).data()))
      let incompatible = try await directory.refresh(
        account: account.id, credentials: h.app, provider: provider)
      #expect(
        incompatible["active"]?.array?.last?["profileUpdate"]?["resetReasoningRequired"]
          == .bool(true))
      var resetCommand: JSONObject = [
        "model": .string("synthetic-next"), "revision": incompatible["revision"]!,
        "candidateRevision": incompatible["candidateRevision"]!,
      ]
      await #expect(throws: ExecutionError.conflict) {
        try await directory.changeProfile(.object(resetCommand))
      }
      resetCommand["resetReasoningSettings"] = .bool(true)
      _ = try await directory.changeProfile(.object(resetCommand))
      let reloaded = try await ModelDirectory(
        configuration: configuration, store: h.store, clock: h.store.clock)
      #expect(reloaded.snapshot().active.last?.effectiveReasoningEfforts == ["medium"])
      updatedEntry["context_window"] = .number(800_000)
      h.server.set(.reply(try JSONValue.object(["models": .array([.object(updatedEntry)])]).data()))
      let staleAccount = try await directory.refresh(
        account: account.id, credentials: h.app, provider: provider)
      let beforeDisable = try await h.store.accountCredential(id: account.id).account
      _ = try await h.store.setAccountMode(
        id: account.id, revision: beforeDisable.revision, mode: .disabled)
      await #expect(throws: ExecutionError.conflict) {
        try await directory.changeProfile(
          .object([
            "model": .string("synthetic-next"), "revision": staleAccount["revision"]!,
            "candidateRevision": staleAccount["candidateRevision"]!,
          ]))
      }
      #expect(
        try await h.store.modelDirectorySnapshot()?.active.last?.upstream?["context_window"]
          == .number(750_000))
      let disabled = try await h.store.accountCredential(id: account.id).account
      _ = try await h.store.setAccountMode(
        id: account.id, revision: disabled.revision, mode: .enabled)
      updatedEntry["slug"] = .string("synthetic-old")
      h.server.set(.reply(try JSONValue.object(["models": .array([.object(updatedEntry)])]).data()))
      let configured = try await directory.refresh(
        account: account.id, credentials: h.app, provider: provider)
      _ = try await directory.changeProfile(
        .object([
          "model": .string("synthetic-old"), "revision": configured["revision"]!,
          "candidateRevision": configured["candidateRevision"]!,
        ]))
      let routing = try #require(try await h.store.modelDirectorySnapshot())
      #expect(routing.accountForModel["synthetic-old"] == nil)
      #expect(routing.accountForModel["synthetic-next"] == account.id)
      #expect(h.server.counts.invalid == 0)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    _ = await owner.result
  }
}
