import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

private actor AuthorizationProbe: AccountAuthorizationProvider {
  var calls = 0
  var active = 0
  var released = true
  var namespace = "synthetic/authorization"
  nonisolated func authorizationURL(state: String, nonce: String, verifier: String) throws -> String
  {
    "https://auth.example.invalid/authorize?state=\(state)&nonce=\(nonce)&challenge=synthetic"
  }
  func hold() { released = false }
  func release() { released = true }
  func changeNamespace() { namespace = "synthetic/different" }
  func authorize(code: String, verifier: String, expectedNonce: String) async throws
    -> VerifiedAccountAuthorization
  {
    calls += 1
    active += 1
    defer { active -= 1 }
    while !released { try await Task.sleep(for: .milliseconds(5)) }
    return try VerifiedAccountAuthorization(
      namespace: namespace,
      credential: AccountCredential(
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
        expiresAtUnixSeconds: 2_000_000_000))
  }
}
private struct AuthorizationFixture {
  let root: URL
  let store: SQLiteExecutionStore
  let application: AccountCredentials
  static func make() async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let key = root.appendingPathComponent("master")
    try Data(String(repeating: "6b", count: 32).utf8).write(to: key)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    let cipher = try await AccountCredentialCipher.load(path: key.path)
    let store = try await SQLiteExecutionStore.open(
      path: root.appendingPathComponent("core.sqlite").path,
      limits: .init(requests: 100, active: 4, unresolved: 4, budgetMicros: 100))
    return Self(
      root: root, store: store, application: AccountCredentials(store: store, protection: cipher))
  }
  func close() async {
    await store.close()
    try? FileManager.default.removeItem(at: root)
  }
}
private func authorizationWait(_ condition: @Sendable () async -> Bool) async throws {
  for _ in 0..<500 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw AccountRefreshError.unavailable
}
private func callback(_ flow: AccountAuthorizationStart, stateOverride: String? = nil) throws
  -> String
{
  let url = try #require(URLComponents(string: flow.authorizationURL))
  let state = try #require(url.queryItems?.first(where: { $0.name == "state" })?.value)
  return "http://localhost:1455/auth/callback?code=synthetic-code&state=\(stateOverride ?? state)"
}

@Test(.timeLimit(.minutes(1))) func authorizationFlowBindsOwnerAndConsumesBeforeExchange()
  async throws
{
  let fixture = try await AuthorizationFixture.make()
  let provider = AuthorizationProbe()
  let service = try AccountAuthorizationSupervisor(
    application: fixture.application, provider: provider)
  let owner = Task { try await service.run() }
  try await authorizationWait { await service.isAccepting }
  let flow = try await service.begin(owner: "session-a", target: .create)
  let url = try callback(flow)
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.complete(owner: "session-b", flowID: flow.flowID, callbackURL: url)
  }
  await service.discard(owner: "session-b", flowID: flow.flowID)
  let created = try await service.complete(
    owner: "session-a", flowID: flow.flowID, callbackURL: url)
  #expect(created.mode == .disabled && created.authorization == .ready)
  let status = try await service.status(owner: "session-a", flowID: flow.flowID)
  #expect(status.status == .completed && status.accountID == created.id)
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.complete(owner: "session-a", flowID: flow.flowID, callbackURL: url)
  }
  #expect(await provider.calls == 1)
  #expect(try await fixture.store.listAccounts(after: nil).count == 1)
  owner.cancel()
  try await owner.value
  await #expect(throws: AccountRefreshError.closed) {
    try await service.begin(owner: "session-a", target: .create)
  }
  await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func authorizationRejectsMalformedOrExpiredCallbacksBeforeNetwork()
  async throws
{
  let fixture = try await AuthorizationFixture.make()
  let provider = AuthorizationProbe()
  let service = try AccountAuthorizationSupervisor(
    application: fixture.application, provider: provider)
  let owner = Task { try await service.run() }
  try await authorizationWait { await service.isAccepting }
  for variant in 0..<8 {
    let flow = try await service.begin(owner: "session", target: .create)
    let valid = try callback(flow)
    let bad: String
    switch variant {
    case 0: bad = try callback(flow, stateOverride: "wrong")
    case 1: bad = valid.replacingOccurrences(of: "localhost", with: "elsewhere.invalid")
    case 2: bad = valid + "&code=duplicate"
    case 3: bad = valid + "#fragment"
    case 4: bad = valid.replacingOccurrences(of: "http://", with: "http://user@")
    case 5: bad = valid + "&unexpected=value"
    case 6: bad = valid.replacingOccurrences(of: "synthetic-code", with: "%0A")
    default: bad = valid.replacingOccurrences(of: "1455", with: "1456")
    }
    await #expect(throws: AccountRefreshError.invalidCommand) {
      try await service.complete(owner: "session", flowID: flow.flowID, callbackURL: bad)
    }
    #expect(
      try await service.status(owner: "session", flowID: flow.flowID).failureCode
        == "verification_failed")
    await #expect(throws: AccountRefreshError.conflict) {
      try await service.complete(owner: "session", flowID: flow.flowID, callbackURL: valid)
    }
  }
  #expect(await provider.calls == 0)
  owner.cancel()
  try await owner.value
  let expiring = try AccountAuthorizationSupervisor(
    application: fixture.application, provider: provider, lifetime: .milliseconds(10))
  let shortOwner = Task { try await expiring.run() }
  try await authorizationWait { await expiring.isAccepting }
  let flow = try await expiring.begin(owner: "session", target: .create)
  try await Task.sleep(for: .milliseconds(20))
  await #expect(throws: AccountRefreshError.conflict) {
    try await expiring.complete(owner: "session", flowID: flow.flowID, callbackURL: callback(flow))
  }
  #expect(await provider.calls == 0)
  shortOwner.cancel()
  try await shortOwner.value
  await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func authorizationCapacityCancellationDeadlineAndShutdownAreOwned()
  async throws
{
  for mode in ["cancel", "deadline", "stop"] {
    let fixture = try await AuthorizationFixture.make()
    let provider = AuthorizationProbe()
    await provider.hold()
    let service = try AccountAuthorizationSupervisor(
      application: fixture.application, provider: provider,
      exchangeTimeout: mode == "deadline" ? .milliseconds(100) : .seconds(30))
    let owner = Task { try await service.run() }
    try await authorizationWait { await service.isAccepting }
    var flows: [AccountAuthorizationStart] = []
    for _ in 0..<8 { flows.append(try await service.begin(owner: "session", target: .create)) }
    await #expect(throws: AccountRefreshError.capacity) {
      try await service.begin(owner: "session", target: .create)
    }
    let requests = try flows.prefix(4).map { flow in
      let url = try callback(flow)
      return Task {
        try await service.complete(owner: "session", flowID: flow.flowID, callbackURL: url)
      }
    }
    try await authorizationWait { await provider.active == 4 }
    #expect(try await service.status(owner: "session", flowID: flows[0].flowID).status == .pending)
    await #expect(throws: AccountRefreshError.capacity) {
      try await service.complete(
        owner: "session", flowID: flows[4].flowID, callbackURL: callback(flows[4]))
    }
    if mode == "cancel" { for request in requests { request.cancel() } }
    if mode == "stop" { owner.cancel() }
    for request in requests {
      do {
        _ = try await request.value
        Issue.record("Stopped exchange unexpectedly persisted")
      } catch {
        #expect(error as? AccountRefreshError == (mode == "deadline" ? .unavailable : .closed))
      }
    }
    if mode == "deadline" {
      for flow in flows.prefix(4) {
        #expect(
          try await service.status(owner: "session", flowID: flow.flowID).failureCode
            == "exchange_failed")
      }
    }
    #expect(await provider.active == 0)
    #expect(try await fixture.store.listAccounts(after: nil).isEmpty)
    if mode == "cancel" {
      await provider.release()
      let account = try await service.complete(
        owner: "session", flowID: flows[4].flowID, callbackURL: callback(flows[4]) + "&scope=openid"
      )
      #expect(account.mode == .disabled)
    }
    owner.cancel()
    try await owner.value
    await fixture.close()
  }
}

@Test(.timeLimit(.minutes(1))) func reauthorizationPreservesIdentityModeAndRevisionCAS()
  async throws
{
  let fixture = try await AuthorizationFixture.make()
  let provider = AuthorizationProbe()
  let service = try AccountAuthorizationSupervisor(
    application: fixture.application, provider: provider)
  let owner = Task { try await service.run() }
  try await authorizationWait { await service.isAccepting }
  let first = try await service.begin(owner: "session", target: .create)
  let account = try await service.complete(
    owner: "session", flowID: first.flowID, callbackURL: callback(first))
  let flow = try await service.begin(
    owner: "session", target: .reauthorize(id: account.id, revision: account.revision))
  let changed = try await fixture.store.setAccountMode(
    id: account.id, revision: account.revision, mode: .draining)
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.complete(owner: "session", flowID: flow.flowID, callbackURL: callback(flow))
  }
  #expect(
    try await service.status(owner: "session", flowID: flow.flowID).failureCode
      == "revision_conflict")
  let retry = try await service.begin(
    owner: "session", target: .reauthorize(id: changed.id, revision: changed.revision))
  let refreshed = try await service.complete(
    owner: "session", flowID: retry.flowID, callbackURL: callback(retry))
  #expect(refreshed.id == account.id && refreshed.mode == .draining)
  #expect(refreshed.credentialVersion == 2)
  await provider.changeNamespace()
  let wrong = try await service.begin(
    owner: "session", target: .reauthorize(id: refreshed.id, revision: refreshed.revision))
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.complete(owner: "session", flowID: wrong.flowID, callbackURL: callback(wrong))
  }
  #expect(
    try await service.status(owner: "session", flowID: wrong.flowID).failureCode
      == "identity_mismatch")
  #expect(try await fixture.store.accountCredential(id: account.id).account == refreshed)
  owner.cancel()
  try await owner.value
  await fixture.close()
}
