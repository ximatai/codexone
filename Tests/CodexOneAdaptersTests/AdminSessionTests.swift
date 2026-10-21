import CodexOneCore
import Foundation
import NIOHTTP1
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
  let session = try sessions.login(secret: syntheticAdminSecret, headers: loginHeaders())
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
    created.append(try sessions.login(secret: syntheticAdminSecret, headers: loginHeaders()))
  }
  #expect(throws: ExecutionError.capacity) {
    try sessions.login(secret: syntheticAdminSecret, headers: loginHeaders())
  }
  var replacing = loginHeaders()
  replacing.add(name: "cookie", value: AdminSessions.cookieName + "=" + created[0].token)
  let fresh = try sessions.login(secret: syntheticAdminSecret, headers: replacing)
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.authorize(sessionHeaders(created[0]), mutation: false)
  }
  try sessions.logout(sessionHeaders(fresh, mutation: true))
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.authorize(sessionHeaders(fresh), mutation: false)
  }
  _ = try sessions.login(secret: syntheticAdminSecret, headers: loginHeaders())
}

@Test func expiredAndRestartedSessionsCannotAuthorizeButCanLoginAgain() async throws {
  let sessions = try AdminSessions(
    digest: keyDigest(syntheticAdminSecret), publicOrigin: nil, maximumAge: 1)
  sessions.bind(port: 19876)
  let session = try sessions.login(secret: syntheticAdminSecret, headers: loginHeaders())
  try await Task.sleep(for: .milliseconds(1100))
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
  let fresh = try restarted.login(secret: syntheticAdminSecret, headers: stale)
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
  let session = try sessions.login(secret: syntheticAdminSecret, headers: headers)
  var proof = sessionHeaders(session, mutation: true)
  proof.replaceOrAdd(name: "origin", value: "https://foreign.example")
  proof.add(name: "x-forwarded-host", value: "admin.example")
  #expect(throws: GatewayProtocolError.self) { try sessions.authorize(proof, mutation: true) }
  #expect(throws: ExecutionError.unauthorized) {
    try sessions.login(secret: "synthetic-wrong-admin-credential", headers: headers)
  }
}
