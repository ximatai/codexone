import CodexOneCore
import CodexOneRuntime
import Foundation
import Logging
import Synchronization
import Testing

@testable import CodexOneAdapters

/// Capture the emitted event, not a separately computed diagnostic string.
private final class AuthorizationLogs: Sendable {
  struct Entry: Sendable {
    let level: Logger.Level
    let message: String
    let metadata: Logger.Metadata
    let hasError: Bool
  }
  let entries = Mutex<[Entry]>([])
  var logger: Logger { Logger(label: "synthetic.authorization") { _ in Handler(owner: self) } }
  private struct Handler: LogHandler {
    let owner: AuthorizationLogs
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
      let fields = self.metadata.merging(event.metadata ?? [:]) { _, new in new }
      owner.entries.withLock {
        $0.append(
          Entry(
            level: event.level, message: event.message.description,
            metadata: fields, hasError: event.error != nil))
      }
    }
  }
  func expectFailure(_ code: String, method: String, status: Int?) {
    let captured = entries.withLock { $0 }
    #expect(captured.count == 1)
    guard let entry = captured.first else { return }
    #expect(entry.level == .warning && !entry.hasError)
    #expect(entry.message == "Account authorization failed")
    var expected: Logger.Metadata = ["method": .string(method), "failure_code": .string(code)]
    if let status { expected["provider_status"] = .string(String(status)) }
    // An exact allowlist excludes tokens, user/device codes, identities, bodies and raw errors.
    var metadata = entry.metadata
    let stage = metadata.removeValue(forKey: "stage")
    let cause = metadata.removeValue(forKey: "cause")
    #expect(metadata == expected)
    #expect(["request", "poll", "exchange", "persist"].contains(stage.map { "\($0)" } ?? ""))
    // A type or payload-free enum case name only.
    #expect(
      cause.map { "\($0)" }?.allSatisfy { $0.isLetter || $0.isNumber || "._<>, ".contains($0) }
        == true)
    let line = entry.message + String(describing: entry.metadata)
    for secret in [
      "SYNTH-CODE", "synthetic-device-id-private", "synthetic-code", oauthVerifier,
      "synthetic-refresh", "synthetic-workspace", "synthetic-user", "synthetic-private-body",
    ] {
      #expect(!line.contains(secret))
    }
  }
}

@Test(.timeLimit(.minutes(1))) func authorizationFailuresKeepTypedReasonsAndOneSafeRuntimeWarning()
  async throws
{
  for scenario in [
    "poll400", "poll429", "poll500", "unavailable", "pkce", "poll-malformed", "poll-drop",
    "exchange400", "exchange429", "exchange500", "exchange-malformed", "exchange-missing",
    "exchange-timeout", "claims", "identity", "duplicate", "revision", "storage",
  ] {
    try await withOAuth(timeout: scenario == "exchange-timeout" ? 100 : 10_000) { h in
      try prepareDevice(h)
      let logs = AuthorizationLogs()
      let gate = DevicePollGate()
      let service = try AccountAuthorizationSupervisor(
        application: h.app, provider: h.provider, logger: logs.logger, pollWait: gate.wait)
      let owner = Task { try await service.run() }
      do {
        try await awaitDevice { await service.isAccepting }
        var target: AccountAuthorizationTarget = .create
        var original: ManagedAccount?
        if ["identity", "duplicate", "revision"].contains(scenario) {
          let verified = try await h.provider.authorizeDevice(
            AccountDeviceGrant(code: "synthetic-code+/=", verifier: oauthVerifier))
          let account = try await h.app.importVerified(
            id: "synthetic-internal-account", namespace: verified.namespace,
            credential: verified.credential)
          original = account
          if scenario != "duplicate" {
            target = .reauthorize(id: account.id, revision: account.revision)
          }
          if scenario == "identity" {
            h.server.set(.reply(try oauthTokens(account: "synthetic-other-account")))
          }
          if scenario == "revision" {
            original = try await h.store.setAccountMode(
              id: account.id, revision: account.revision, mode: .draining)
          }
        }
        var expected = "authorization_failed"
        var status: Int?
        if scenario.hasPrefix("poll"), let number = Int(scenario.dropFirst(4)) {
          expected = "provider_rejected"
          status = number
          h.server.state.mutex.withLock {
            $0.devicePlans[devicePoll] = .reply(
              Data("synthetic-private-body SYNTH-CODE".utf8), type: "text/plain", status: number)
          }
        } else if scenario.hasPrefix("exchange"), let number = Int(scenario.dropFirst(8)) {
          expected = "exchange_failed"
          status = number
          h.server.set(
            .reply(Data("synthetic-private-body".utf8), type: "text/plain", status: number))
        } else {
          switch scenario {
          case "unavailable":
            expected = "device_code_unavailable"
            status = 404
            h.server.state.mutex.withLock {
              $0.devicePlans[deviceCreate] = .reply(Data(), status: 404)
            }
          case "pkce":
            expected = "verification_failed"
            status = 200
            var grant = try #require(
              JSONSerialization.jsonObject(with: deviceGrant()) as? [String: Any])
            grant["code_challenge"] = "synthetic-wrong-challenge"
            let bytes = try JSONSerialization.data(withJSONObject: grant)
            h.server.state.mutex.withLock { $0.devicePlans[devicePoll] = .reply(bytes) }
          case "poll-malformed":
            status = 200
            h.server.state.mutex.withLock { $0.devicePlans[devicePoll] = .reply(Data("{".utf8)) }
          case "poll-drop":
            h.server.state.mutex.withLock { $0.devicePlans[devicePoll] = .abort }
          case "exchange-malformed", "exchange-missing":
            expected = "exchange_failed"
            status = 200
            h.server.set(.reply(Data((scenario == "exchange-missing" ? "{}" : "{").utf8)))
          case "exchange-timeout":
            expected = "exchange_failed"
            h.server.set(.headersStall)
          case "claims":
            expected = "verification_failed"
            status = 200
            h.server.set(.reply(try oauthTokens(idAudience: "synthetic-wrong-client")))
          case "identity", "duplicate": expected = "identity_mismatch"
          case "revision": expected = "revision_conflict"
          case "storage":
            try await h.store.perform { db in
              try db.exec(
                "CREATE TRIGGER fail_authorization BEFORE INSERT ON accounts BEGIN SELECT RAISE(ABORT,'synthetic-private-body'); END"
              )
            }
          default: Issue.record("Unhandled synthetic scenario")
          }
        }
        let flow = try await service.begin(
          owner: "synthetic-session", target: target, method: .device)
        if scenario != "unavailable" { gate.pulse() }
        try await awaitDevice {
          try await service.status(owner: "synthetic-session", flowID: flow.flowID).status
            == .failed
        }
        let result = try await service.status(owner: "synthetic-session", flowID: flow.flowID)
        #expect(result.failureCode == expected && result.userCode == nil)
        logs.expectFailure(expected, method: "device", status: status)
        if let original {
          #expect(try await h.store.accountCredential(id: original.id).account == original)
        } else {
          #expect(try await h.store.listAccounts().isEmpty)
        }
        let before = calls(h, "/oauth/token")
        gate.pulse()
        _ = try await service.status(owner: "synthetic-session", flowID: flow.flowID)
        await service.discard(owner: "synthetic-session", flowID: flow.flowID)
        #expect(calls(h, "/oauth/token") == before && h.provider.activeRequests == 0)
        logs.expectFailure(expected, method: "device", status: status)
      } catch {
        owner.cancel()
        _ = await owner.result
        throw error
      }
      owner.cancel()
      try await owner.value
    }
  }
}

@Test(.timeLimit(.minutes(1))) func callbackFailuresExposeSafeReasonsAndSafePostErrors()
  async throws
{
  for scenario in ["nonce", "exchange", "exchange-rejected", "malformed-callback"] {
    try await withOAuth { h in
      let logs = AuthorizationLogs()
      let service = try AccountAuthorizationSupervisor(
        application: h.app, provider: h.provider, logger: logs.logger)
      let owner = Task { try await service.run() }
      do {
        try await awaitDevice { await service.isAccepting }
        let flow = try await service.begin(owner: "synthetic-session", target: .create)
        let query = try #require(URLComponents(string: flow.authorizationURL)?.queryItems)
        let state = try #require(query.first { $0.name == "state" }?.value)
        let challenge = try #require(query.first { $0.name == "code_challenge" }?.value)
        h.server.state.mutex.withLock {
          $0.expectedVerifier = nil
          $0.expectedChallenge = challenge
        }
        h.server.set(
          scenario.hasPrefix("exchange")
            ? .reply(
              Data(#"{"error":"invalid_grant"}"#.utf8), status: scenario == "exchange" ? 500 : 400)
            : .reply(try oauthTokens(nonce: "synthetic-wrong-nonce")))
        let url =
          scenario == "malformed-callback"
          ? "synthetic-private-body"
          : SubscriptionOAuthProvider.callbackURI + "?state=" + state + "&code=synthetic-code"
        await #expect(
          throws: scenario == "malformed-callback"
            ? AccountRefreshError.invalidCommand
            : scenario.hasPrefix("exchange") && scenario != "exchange"
              ? .authorizationRequired : .unavailable
        ) {
          try await service.complete(
            owner: "synthetic-session", flowID: flow.flowID, callbackURL: url)
        }
        let expected = scenario.hasPrefix("exchange") ? "exchange_failed" : "verification_failed"
        #expect(
          try await service.status(owner: "synthetic-session", flowID: flow.flowID).failureCode
            == expected)
        logs.expectFailure(
          expected, method: "callback",
          status: scenario == "malformed-callback"
            ? nil : (scenario.hasPrefix("exchange") ? (scenario == "exchange" ? 500 : 400) : 200))
        #expect(try await h.store.listAccounts().isEmpty)
      } catch {
        owner.cancel()
        _ = await owner.result
        throw error
      }
      owner.cancel()
      try await owner.value
    }
  }
}
