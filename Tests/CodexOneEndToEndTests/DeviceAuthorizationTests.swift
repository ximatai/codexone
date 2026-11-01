import CodexOneCore
import CodexOneRuntime
import Crypto
import Foundation
import NIOCore
import Synchronization
import Testing

@testable import CodexOneAdapters

@Test(.timeLimit(.minutes(1))) func deviceSocketPendingSuccessOwnerIsolationAndExactlyOneExchange()
  async throws
{
  try await withOAuth { h in
    try prepareDevice(h, poll: .reply(Data(), status: 403))
    let gate = DevicePollGate()
    let service = try AccountAuthorizationSupervisor(
      application: h.app, provider: h.provider, pollWait: gate.wait)
    let owner = Task { try await service.run() }
    do {
      try await awaitDevice { await service.isAccepting }
      let flow = try await service.begin(owner: "session-a", target: .create, method: .device)
      #expect(
        flow.userCode == "SYNTH-CODE" && flow.intervalSeconds == 3 && flow.expiresInSeconds <= 900)
      #expect(!String(describing: flow).contains("SYNTH-CODE"))
      await #expect(throws: AccountRefreshError.conflict) {
        try await service.status(owner: "session-b", flowID: flow.flowID)
      }
      await service.discard(owner: "session-b", flowID: flow.flowID)
      for status in [403, 404] {
        h.server.state.mutex.withLock {
          $0.devicePlans[devicePoll] = .reply(Data(), status: status)
        }
        let previous = calls(h, devicePoll)
        gate.pulse()
        try await awaitDevice {
          calls(h, devicePoll) == previous + 1 && h.provider.activeRequests == 0
        }
        #expect(
          try await service.status(owner: "session-a", flowID: flow.flowID).status == .pending)
      }
      h.server.state.mutex.withLock { $0.devicePlans[devicePoll] = .reply(try! deviceGrant()) }
      gate.pulse()
      try await awaitDevice {
        try await service.status(owner: "session-a", flowID: flow.flowID).status == .completed
      }
      let result = try await service.status(owner: "session-a", flowID: flow.flowID)
      let account = try await h.store.accountCredential(id: #require(result.accountID)).account
      #expect(
        account.mode == .disabled && account.authorization == .ready && result.userCode == nil)
      await #expect(throws: AccountRefreshError.conflict) {
        try await service.complete(owner: "session-a", flowID: flow.flowID, callbackURL: "unused")
      }
      gate.pulse()
      #expect(calls(h, "/oauth/token") == 1 && h.server.counts.invalid == 0)
      try noDeviceMaterialInDatabase(h)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    try await owner.value
    #expect(h.provider.activeRequests == 0)
  }
}

@Test(.timeLimit(.minutes(1))) func deviceSocketUnavailableMalformedStatusDropAndExchangeFailures()
  async throws
{
  let variants: [OAuthPlan] = [
    .reply(Data(), status: 500), .reply(Data("{".utf8)), .abort,
    .reply(Data(#"{"authorization_code":"missing-verifier"}"#.utf8)),
    .reply(
      Data(
        #"{"authorization_code":"synthetic-code","code_verifier":"bad","code_challenge":"bad"}"#
          .utf8)),
  ]
  for variant in variants {
    try await withOAuth { h in
      try prepareDevice(h, poll: variant)
      let gate = DevicePollGate()
      let service = try AccountAuthorizationSupervisor(
        application: h.app, provider: h.provider, pollWait: gate.wait)
      let owner = Task { try await service.run() }
      do {
        try await awaitDevice { await service.isAccepting }
        let flow = try await service.begin(owner: "session", target: .create, method: .device)
        gate.pulse()
        try await awaitDevice {
          try await service.status(owner: "session", flowID: flow.flowID).status == .failed
        }
        #expect(calls(h, "/oauth/token") == 0 && h.provider.activeRequests == 0)
        #expect(try await h.store.listAccounts(after: nil).isEmpty)
      } catch {
        owner.cancel()
        _ = await owner.result
        throw error
      }
      owner.cancel()
      try await owner.value
    }
  }
  try await withOAuth { h in
    try prepareDevice(h, create: .reply(Data(), status: 404))
    let service = try AccountAuthorizationSupervisor(application: h.app, provider: h.provider)
    let owner = Task { try await service.run() }
    do {
      try await awaitDevice { await service.isAccepting }
      let flow = try await service.begin(owner: "session", target: .create, method: .device)
      #expect(flow.failureCode == "device_code_unavailable" && flow.userCode == nil)
      #expect(
        try await service.status(owner: "session", flowID: flow.flowID).failureCode
          == "device_code_unavailable")
      #expect(calls(h, devicePoll) == 0 && calls(h, "/oauth/token") == 0)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    try await owner.value
  }
  try await withOAuth { h in
    try prepareDevice(h)
    h.server.set(.reply(Data(#"{"error":"invalid_grant"}"#.utf8), status: 400))
    let gate = DevicePollGate()
    let service = try AccountAuthorizationSupervisor(
      application: h.app, provider: h.provider, pollWait: gate.wait)
    let owner = Task { try await service.run() }
    do {
      try await awaitDevice { await service.isAccepting }
      let flow = try await service.begin(owner: "session", target: .create, method: .device)
      gate.pulse()
      try await awaitDevice {
        try await service.status(owner: "session", flowID: flow.flowID).status == .failed
      }
      #expect(calls(h, "/oauth/token") == 1 && h.provider.activeRequests == 0)
      #expect(try await h.store.listAccounts(after: nil).isEmpty)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    try await owner.value
  }
}

@Test(.timeLimit(.minutes(1))) func deviceSocketCancellationAndServiceStopAwaitPollingAndExchange()
  async throws
{
  for phase in ["create", "poll", "exchange", "waiting"] {
    for stopService in [false, true] {
      try await withOAuth(timeout: 30_000) { h in
        try prepareDevice(
          h, create: phase == "create" ? .headersStall : nil,
          poll: phase == "poll" ? .headersStall : nil)
        if phase == "exchange" { h.server.set(.headersStall) }
        let gate = DevicePollGate()
        let service = try AccountAuthorizationSupervisor(
          application: h.app, provider: h.provider, pollWait: gate.wait)
        let owner = Task { try await service.run() }
        do {
          try await awaitDevice { await service.isAccepting }
          let beginning = Task {
            try await service.begin(owner: "session", target: .create, method: .device)
          }
          if phase == "create" {
            try await awaitDevice { calls(h, deviceCreate) == 1 }
            owner.cancel()
            try await owner.value
            _ = try await beginning.value
          } else {
            let flow = try await beginning.value
            if phase != "waiting" {
              gate.pulse()
              let path = phase == "poll" ? devicePoll : "/oauth/token"
              try await awaitDevice { calls(h, path) == 1 }
            }
            if stopService {
              owner.cancel()
              try await owner.value
            } else {
              await service.discard(owner: "session", flowID: flow.flowID)
            }
          }
          #expect(h.provider.activeRequests == 0)
          try await awaitDevice { h.server.counts.active == 0 }
          #expect(try await h.store.listAccounts(after: nil).isEmpty)
          try noDeviceMaterialInDatabase(h)
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
}

@Test(.timeLimit(.minutes(1)))
func deviceSocketExpirySharedCapacityAndReauthorizationIdentityConflict() async throws {
  try await withOAuth { h in
    try prepareDevice(h)
    let instant = Mutex(ContinuousClock.now)
    let gate = DevicePollGate()
    let service = try AccountAuthorizationSupervisor(
      application: h.app, provider: h.provider, now: { instant.withLock { $0 } },
      pollWait: gate.wait)
    let owner = Task { try await service.run() }
    do {
      try await awaitDevice { await service.isAccepting }
      let flow = try await service.begin(owner: "session", target: .create, method: .device)
      var callbacks: [AccountAuthorizationStart] = []
      for _ in 0..<7 {
        callbacks.append(try await service.begin(owner: "session", target: .create))
      }
      for method: AccountAuthorizationMethod in [.device, .callback] {
        await #expect(throws: AccountRefreshError.capacity) {
          try await service.begin(owner: "session", target: .create, method: method)
        }
      }
      instant.withLock { $0 = $0.advanced(by: .seconds(901)) }
      #expect(try await service.status(owner: "session", flowID: flow.flowID).status == .expired)
      await service.discard(owner: "session", flowID: flow.flowID)
      #expect(calls(h, devicePoll) == 0 && calls(h, "/oauth/token") == 0)
      let first = try await service.begin(owner: "session", target: .create, method: .device)
      gate.pulse()
      try await awaitDevice {
        try await service.status(owner: "session", flowID: first.flowID).status == .completed
      }
      let id = try #require(
        try await service.status(owner: "session", flowID: first.flowID).accountID)
      let original = try await h.store.accountCredential(id: id).account
      h.server.set(.reply(try oauthTokens(account: "synthetic-other-account")))
      let other = try await service.begin(
        owner: "session", target: .reauthorize(id: id, revision: original.revision), method: .device
      )
      gate.pulse()
      try await awaitDevice {
        try await service.status(owner: "session", flowID: other.flowID).status == .failed
      }
      #expect(
        try await service.status(owner: "session", flowID: other.flowID).failureCode
          == "identity_mismatch")
      #expect(try await h.store.accountCredential(id: id).account == original)
      #expect(calls(h, "/oauth/token") == 2 && h.server.counts.invalid == 0)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    try await owner.value
  }
}

@Test(.timeLimit(.minutes(1))) func deviceSocketCompletionsShareCallbackConcurrencyLimit()
  async throws
{
  try await withOAuth(timeout: 30_000) { h in
    try prepareDevice(h)
    h.server.set(.headersStall)
    let gate = DevicePollGate()
    let service = try AccountAuthorizationSupervisor(
      application: h.app, provider: h.provider, pollWait: gate.wait)
    let owner = Task { try await service.run() }
    do {
      try await awaitDevice { await service.isAccepting }
      var devices: [AccountAuthorizationStart] = []
      for _ in 0..<4 {
        devices.append(try await service.begin(owner: "session", target: .create, method: .device))
      }
      let callback = try await service.begin(owner: "session", target: .create)
      for number in 1...4 {
        gate.pulse()
        try await awaitDevice {
          calls(h, "/oauth/token") == number && h.provider.activeRequests == number
        }
      }
      let query = try #require(URLComponents(string: callback.authorizationURL)?.queryItems)
      let state = try #require(query.first(where: { $0.name == "state" })?.value)
      let url = SubscriptionOAuthProvider.callbackURI + "?state=" + state + "&code=synthetic-code"
      await #expect(throws: AccountRefreshError.capacity) {
        try await service.complete(owner: "session", flowID: callback.flowID, callbackURL: url)
      }
      #expect(
        try await service.status(owner: "session", flowID: callback.flowID).status == .pending)
      for device in devices { await service.discard(owner: "session", flowID: device.flowID) }
      #expect(h.provider.activeRequests == 0 && calls(h, "/oauth/token") == 4)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    try await owner.value
  }
}

@Test(.timeLimit(.minutes(1))) func deviceSocketDeadlineCancelsNetworkWithoutAStatusReader()
  async throws
{
  for phase in ["create", "poll", "exchange"] {
    try await withOAuth(timeout: 30_000) { h in
      try prepareDevice(
        h, create: phase == "create" ? .headersStall : nil,
        poll: phase == "poll" ? .headersStall : nil)
      if phase == "exchange" { h.server.set(.headersStall) }
      let gate = DevicePollGate()
      let service = try AccountAuthorizationSupervisor(
        application: h.app, provider: h.provider, deviceLifetime: .seconds(2), pollWait: gate.wait)
      let owner = Task { try await service.run() }
      do {
        try await awaitDevice { await service.isAccepting }
        let beginning = Task {
          try await service.begin(owner: "session", target: .create, method: .device)
        }
        let flow: AccountAuthorizationStart
        if phase == "create" {
          try await awaitDevice { calls(h, deviceCreate) == 1 }
          flow = try await beginning.value
        } else {
          flow = try await beginning.value
          gate.pulse()
          let path = phase == "poll" ? devicePoll : "/oauth/token"
          try await awaitDevice { calls(h, path) == 1 }
        }
        // Bound the observation by elapsed time; do not sleep and assume a timer has fired.
        try await awaitDevice { h.provider.activeRequests == 0 }
        #expect(try await service.status(owner: "session", flowID: flow.flowID).status == .expired)
        #expect(try await h.store.listAccounts(after: nil).isEmpty)
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
