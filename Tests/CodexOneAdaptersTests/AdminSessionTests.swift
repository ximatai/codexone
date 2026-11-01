import CodexOneCore
import Foundation
import NIOHTTP1
import Synchronization
import Testing

@testable import CodexOneAdapters

private let syntheticAdminSecret = "synthetic-admin-session-credential-for-tests"
private let syntheticOrigin = "http://127.0.0.1:19876"
private func loginHeaders() -> HTTPHeaders {
  ["host": "127.0.0.1:19876", "origin": syntheticOrigin, "sec-fetch-site": "same-origin"]
}
private func sessionHeaders(_ session: AdminSessions.Created, mutation: Bool = false) -> HTTPHeaders
{
  var headers: HTTPHeaders = [
    "host": "127.0.0.1:19876", "cookie": AdminSessions.cookieName + "=" + session.token,
  ]
  if mutation {
    headers.add(name: "origin", value: syntheticOrigin)
    headers.add(name: "x-codexone-csrf", value: session.csrf)
  }
  return headers
}

@Test func browserSessionsRequireExactHostOriginAndMutationProof() throws {
  let sessions = try AdminSessions(digest: keyDigest(syntheticAdminSecret), publicOrigin: nil)
  sessions.bind(port: 19876)
  let session = try sessions.login(
    username: "admin", secret: syntheticAdminSecret, headers: loginHeaders())
  #expect(try sessions.authorize(sessionHeaders(session), mutation: false) == session.csrf)
  #expect(
    try sessions.authorize(sessionHeaders(session, mutation: true), mutation: true) == session.csrf)
  var wrong = sessionHeaders(session, mutation: true)
  wrong.replaceOrAdd(name: "origin", value: "https://foreign.example")
  #expect(throws: GatewayProtocolError.self) { try sessions.authorize(wrong, mutation: true) }
  wrong = sessionHeaders(session, mutation: true)
  wrong.replaceOrAdd(name: "host", value: "foreign.example")
  #expect(throws: GatewayProtocolError.self) { try sessions.authorize(wrong, mutation: true) }
  wrong = sessionHeaders(session, mutation: true)
  wrong.replaceOrAdd(name: "x-codexone-csrf", value: "synthetic-wrong-proof")
  #expect(throws: GatewayProtocolError.self) { try sessions.authorize(wrong, mutation: true) }
  wrong = sessionHeaders(session, mutation: true)
  wrong.add(name: "authorization", value: "Bearer " + syntheticAdminSecret)
  #expect(throws: ExecutionError.unauthorized) { try sessions.authorize(wrong, mutation: true) }
  wrong = sessionHeaders(session)
  wrong.add(name: "cookie", value: AdminSessions.cookieName + "=" + session.token)
  #expect(throws: ExecutionError.unauthorized) { try sessions.authorize(wrong, mutation: false) }
}

@Test func sessionCapacityLogoutAndReplacementDoNotLeakOldAuthority() throws {
  let sessions = try AdminSessions(digest: keyDigest(syntheticAdminSecret), publicOrigin: nil)
  sessions.bind(port: 19876)
  var created: [AdminSessions.Created] = []
  for _ in 0..<16 {
    created.append(
      try sessions.login(username: "admin", secret: syntheticAdminSecret, headers: loginHeaders()))
  }
  #expect(throws: ExecutionError.capacity) {
    try sessions.login(username: "admin", secret: syntheticAdminSecret, headers: loginHeaders())
  }
  var replacing = loginHeaders()
  replacing.add(name: "cookie", value: AdminSessions.cookieName + "=" + created[0].token)
  let fresh = try sessions.login(
    username: "admin", secret: syntheticAdminSecret, headers: replacing)
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.authorize(sessionHeaders(created[0]), mutation: false)
  }
  try sessions.logout(sessionHeaders(fresh, mutation: true))
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.authorize(sessionHeaders(fresh), mutation: false)
  }
  _ = try sessions.login(username: "admin", secret: syntheticAdminSecret, headers: loginHeaders())
}

@Test func expiredAndRestartedSessionsCannotAuthorizeButCanLoginAgain() async throws {
  let clock = Mutex(ContinuousClock.now)
  let sessions = try AdminSessions(
    digest: keyDigest(syntheticAdminSecret), publicOrigin: nil, now: { clock.withLock { $0 } })
  sessions.bind(port: 19876)
  let session = try sessions.login(
    username: "admin", secret: syntheticAdminSecret, headers: loginHeaders())
  clock.withLock { $0 = $0.advanced(by: .seconds(AdminSessions.idleLifetime)) }
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.authorize(sessionHeaders(session), mutation: false)
  }
  let restarted = try AdminSessions(digest: keyDigest(syntheticAdminSecret), publicOrigin: nil)
  restarted.bind(port: 19876)
  #expect(throws: ExecutionError.unauthorized) {
    try restarted.authorize(sessionHeaders(session), mutation: false)
  }
  var stale = loginHeaders()
  stale.add(name: "cookie", value: AdminSessions.cookieName + "=" + session.token)
  let fresh = try restarted.login(username: "admin", secret: syntheticAdminSecret, headers: stale)
  #expect(try restarted.authorize(sessionHeaders(fresh), mutation: false) == fresh.csrf)
}

@Test func configuredManagementOriginDoesNotTrustForwardedHeaders() throws {
  #expect(
    try AdminSessions.canonicalOrigin("https://ADMIN.example:443/") == "https://admin.example")
  for value in [
    "http://public.example", "https://user:secret@admin.example", "https://admin.example/path",
    "https://admin.example?x=1", "null",
  ] {
    #expect(throws: ExecutionError.invalidCommand) { try AdminSessions.canonicalOrigin(value) }
  }
  let sessions = try AdminSessions(
    digest: keyDigest(syntheticAdminSecret), publicOrigin: "https://admin.example")
  sessions.bind(port: 19876)
  var headers = loginHeaders()
  headers.replaceOrAdd(name: "origin", value: "https://admin.example")
  headers.add(name: "x-forwarded-host", value: "foreign.example")
  let session = try sessions.login(
    username: "admin", secret: syntheticAdminSecret, headers: headers)
  var proof = sessionHeaders(session, mutation: true)
  proof.replaceOrAdd(name: "origin", value: "https://foreign.example")
  proof.add(name: "x-forwarded-host", value: "admin.example")
  #expect(throws: GatewayProtocolError.self) { try sessions.authorize(proof, mutation: true) }
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.login(
      username: "admin", secret: "synthetic-wrong-admin-credential", headers: headers)
  }
}

@Test func sessionActivitySlidesUntilAbsoluteBoundaryAndCapsCookieAge() throws {
  let start = ContinuousClock.now
  let clock = Mutex(start)
  let sessions = try AdminSessions(
    digest: keyDigest(syntheticAdminSecret), publicOrigin: nil, now: { clock.withLock { $0 } })
  sessions.bind(port: 19876)
  let session = try sessions.login(
    username: "admin", secret: syntheticAdminSecret, headers: loginHeaders())
  #expect(session.maximumAge == AdminSessions.absoluteLifetime)
  for hour in stride(from: 23, through: 167, by: 12) {
    clock.withLock { $0 = start.advanced(by: .seconds(hour * 3600)) }
    let renewed = try sessions.authenticate(sessionHeaders(session), mutation: false)
    #expect(renewed.csrf == session.csrf)
    #expect(renewed.maximumAge == AdminSessions.absoluteLifetime - hour * 3600)
  }
  clock.withLock { $0 = start.advanced(by: .seconds(AdminSessions.absoluteLifetime)) }
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.authenticate(sessionHeaders(session), mutation: false)
  }
}
@Test func usernamesFailWithTheSameCredentialError() throws {
  let sessions = try AdminSessions(digest: keyDigest(syntheticAdminSecret), publicOrigin: nil)
  sessions.bind(port: 19876)
  for username in [nil, "", "wrong", "Admin", "ADMIN"] as [String?] {
    #expect(throws: ExecutionError.unauthorized) {
      try sessions.login(username: username, secret: syntheticAdminSecret, headers: loginHeaders())
    }
  }
}

@Test func cookieAgeIsComputedAtResponseTimeAndNeverExceedsDeadline() throws {
  let start = ContinuousClock.now
  let clock = Mutex(start)
  let sessions = try AdminSessions(
    digest: keyDigest(syntheticAdminSecret), publicOrigin: nil, now: { clock.withLock { $0 } })
  sessions.bind(port: 19876)
  let session = try sessions.login(
    username: "admin", secret: syntheticAdminSecret, headers: loginHeaders())
  clock.withLock { $0 = start.advanced(by: .seconds(AdminSessions.absoluteLifetime - 1)) }
  #expect(sessions.cookieAge(session) == 1)
  clock.withLock { $0 = $0.advanced(by: .seconds(2)) }
  #expect(sessions.cookieAge(session) == 0)
}

@Test(arguments: ["http://192.168.1.10:18081", "http://[fd00::10]:18081"])
func lanHTTPSessionsKeepHostOriginCSRFAndLogoutRules(_ origin: String) throws {
  let address = origin.contains("[") ? "fd00::10" : "192.168.1.10"
  let sessions = try AdminSessions(
    digest: keyDigest(syntheticAdminSecret), publicOrigin: origin, listenAddress: address)
  sessions.bind(port: 18081)
  let host = String(origin.dropFirst(7))
  let login: HTTPHeaders = ["host": host, "origin": origin, "sec-fetch-site": "same-origin"]
  let session = try sessions.login(username: "admin", secret: syntheticAdminSecret, headers: login)
  #expect(
    sessions.cookie(session.token, age: 10)
      == "codexone_admin=\(session.token); Path=/; Max-Age=10; HttpOnly; SameSite=Strict")
  #expect(
    sessions.cookie("", age: 0) == "codexone_admin=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")
  var proof = login
  proof.add(name: "cookie", value: "codexone_admin=" + session.token)
  #expect(try sessions.authorize(proof, mutation: false) == session.csrf)
  #expect(throws: GatewayProtocolError.self) { try sessions.authorize(proof, mutation: true) }
  proof.add(name: "x-codexone-csrf", value: session.csrf)
  #expect(try sessions.authorize(proof, mutation: true) == session.csrf)
  for header in ["host", "origin", "sec-fetch-site"] {
    var wrong = proof
    wrong.replaceOrAdd(name: header, value: "synthetic-foreign")
    wrong.add(name: "x-forwarded-host", value: host)
    wrong.add(name: "x-forwarded-proto", value: "http")
    #expect(throws: GatewayProtocolError.self) { try sessions.authorize(wrong, mutation: true) }
  }
  var wrongCookie = proof
  wrongCookie.replaceOrAdd(name: "cookie", value: AdminSessions.cookieName + "=" + session.token)
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.authorize(wrongCookie, mutation: true)
  }
  try sessions.logout(proof)
  #expect(throws: ExecutionError.unauthorized) { try sessions.authorize(proof, mutation: false) }
}

@Test(
  arguments: [nil, "https://admin.example", "http://127.0.0.1:19876", "http://localhost:19876"]
    as [String?])
func httpsAndLoopbackCookiesStayByteForByteUnchanged(_ origin: String?) throws {
  let sessions = try AdminSessions(digest: keyDigest(syntheticAdminSecret), publicOrigin: origin)
  #expect(
    sessions.cookie("synthetic", age: 123)
      == "__Host-codexone_admin=synthetic; Path=/; Max-Age=123; HttpOnly; Secure; SameSite=Strict")
  #expect(
    sessions.cookie("", age: 0)
      == "__Host-codexone_admin=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict")
}

@Test func httpOriginRequiresThePrivateListenAddressEvenInAdapterAssembly() throws {
  for listen in [nil, "192.168.1.11", "0.0.0.0", "8.8.8.8"] as [String?] {
    #expect(throws: ExecutionError.invalidCommand) {
      try AdminSessions(
        digest: keyDigest(syntheticAdminSecret), publicOrigin: "http://192.168.1.10:18081",
        listenAddress: listen)
    }
  }
}
