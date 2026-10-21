import CodexOneCore
import Foundation
import NIOHTTP1
import Synchronization

/// Single-admin, ephemeral browser sessions. Only complete requests reach this bounded state.
final class AdminSessions: Sendable {
  struct Created: Sendable {
    let token: String
    let csrf: String
    let maximumAge: Int
  }
  private struct Session: Sendable {
    let csrf: String
    let expires: ContinuousClock.Instant
  }
  private struct State {
    var port: Int?
    var sessions: [String: Session] = [:]
  }
  static let cookieName = "__Host-codexone_admin"
  private let digest: String
  private let publicOrigin: String?
  private let maximumAge: Int
  private let state = Mutex(State())
  private let clock = ContinuousClock()

  init(digest: String, publicOrigin: String?, maximumAge: Int = 1800) throws {
    guard (1...1800).contains(maximumAge) else { throw ExecutionError.invalidCommand }
    self.digest = digest
    self.publicOrigin = try publicOrigin.map(Self.canonicalOrigin)
    self.maximumAge = maximumAge
  }
  func bind(port: Int) {
    state.withLock { value in
      precondition((1...65535).contains(port))
      value.sessions.removeAll()
      value.port = port
    }
  }
  func login(secret: String, headers: HTTPHeaders) throws -> Created {
    try checkBrowser(headers, mutation: true)
    guard headers["authorization"].isEmpty,
      (32...512).contains(secret.utf8.count),
      Self.equal(keyDigest(secret), digest)
    else { throw ExecutionError.unauthorized }
    let token = Self.nonce(prefix: "as1_")
    let csrf = Self.nonce(prefix: "ac1_")
    let replacing = try? cookieToken(headers)
    try state.withLock { value in
      let now = clock.now
      value.sessions = value.sessions.filter { $0.value.expires > now }
      if let replacing { value.sessions.removeValue(forKey: keyDigest(replacing)) }
      guard value.sessions.count < 16 else { throw ExecutionError.capacity }
      value.sessions[keyDigest(token)] = Session(
        csrf: csrf, expires: now.advanced(by: .seconds(maximumAge)))
    }
    return Created(token: token, csrf: csrf, maximumAge: maximumAge)
  }
  func authorize(_ headers: HTTPHeaders, mutation: Bool) throws -> String {
    try checkBrowser(headers, mutation: mutation)
    guard headers["authorization"].isEmpty else { throw ExecutionError.unauthorized }
    let token = try cookieToken(headers)
    return try state.withLock { value in
      let now = clock.now
      value.sessions = value.sessions.filter { $0.value.expires > now }
      guard let session = value.sessions[keyDigest(token)] else {
        throw ExecutionError.unauthorized
      }
      if mutation {
        let proof = headers["x-codexone-csrf"]
        guard proof.count == 1, Self.equal(proof[0], session.csrf) else {
          throw GatewayProtocolError(403, "invalid_csrf")
        }
      }
      return session.csrf
    }
  }
  func logout(_ headers: HTTPHeaders) throws {
    _ = try authorize(headers, mutation: true)
    let token = try cookieToken(headers)
    state.withLock { _ = $0.sessions.removeValue(forKey: keyDigest(token)) }
  }
  func checkBrowser(_ headers: HTTPHeaders, mutation: Bool) throws {
    let port = state.withLock { $0.port }
    guard let port else { throw ExecutionError.capacity }
    let origin = try publicOrigin ?? Self.canonicalOrigin("http://127.0.0.1:\(port)")
    let authority = String(origin.split(separator: "/", omittingEmptySubsequences: true)[1])
    let hosts = headers["host"]
    guard hosts.count == 1, [authority, "127.0.0.1:\(port)"].contains(hosts[0].lowercased()) else {
      throw GatewayProtocolError(403, "invalid_management_host")
    }
    let origins = headers["origin"]
    guard origins.count <= 1, !mutation || origins.count == 1,
      origins.isEmpty || origins[0] == origin,
      headers["sec-fetch-site"].isEmpty || headers["sec-fetch-site"] == ["same-origin"]
    else { throw GatewayProtocolError(403, "invalid_management_origin") }
  }
  private func cookieToken(_ headers: HTTPHeaders) throws -> String {
    let values = headers["cookie"]
    guard values.count == 1, values[0].utf8.count <= 4096 else { throw ExecutionError.unauthorized }
    let matches = values[0].split(separator: ";").compactMap { component -> String? in
      let pair = component.trimmingCharacters(in: .whitespaces).split(
        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, pair[0] == Self.cookieName else { return nil }
      return String(pair[1])
    }
    guard matches.count == 1, matches[0].hasPrefix("as1_"), matches[0].utf8.count == 47,
      matches[0].utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 95
      })
    else { throw ExecutionError.unauthorized }
    return matches[0]
  }
  static func canonicalOrigin(_ input: String) throws -> String {
    guard input.utf8.count <= 2048, input.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
      var url = URLComponents(string: input), url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, ["", "/"].contains(url.path),
      let host = url.host, !host.isEmpty,
      url.port == nil || (1...65535).contains(url.port!),
      url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(host))
    else { throw ExecutionError.invalidCommand }
    url.host = host.lowercased()
    url.path = ""
    if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) {
      url.port = nil
    }
    guard let normalized = url.string else { throw ExecutionError.invalidCommand }
    return normalized
  }
  private static func nonce(prefix: String) -> String {
    prefix + String(generateKeySecret().dropFirst(4))
  }
  private static func equal(_ a: String, _ b: String) -> Bool {
    guard a.utf8.count == b.utf8.count else { return false }
    return zip(a.utf8, b.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
