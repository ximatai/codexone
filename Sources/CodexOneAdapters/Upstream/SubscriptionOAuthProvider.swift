import AsyncHTTPClient
import CodexOneCore
import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import ServiceLifecycle
import Synchronization

public struct VerifiedSubscriptionLogin: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let namespace: String
  public let credential: AccountCredential
  public var description: String { "VerifiedSubscriptionLogin(redacted)" }
  public var debugDescription: String { description }
}

/// Fixed production authority; HTTP is available only through an explicit synthetic test factory.
public final class SubscriptionOAuthProvider: Service, AccountRefreshProvider, Sendable {
  public enum Authority: Sendable {
    case openAI
    case syntheticLoopback(port: Int)
  }
  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  public static let callbackURI = "http://localhost:1455/auth/callback"
  static let issuer = "https://auth.openai.com"
  static let dataOrigin = "https://chatgpt.com/backend-api/codex"
  private struct State {
    var started = false
    var client: HTTPClient?
    var active = 0
  }
  private let state = Mutex(State())
  private let group: any EventLoopGroup
  let clock: WallClock
  let realm: String
  private let timeoutMilliseconds: Int
  private let proxy: UpstreamHTTPProxy?
  public var isAccepting: Bool { state.withLock { $0.client != nil } }
  public var activeRequests: Int { state.withLock { $0.active } }

  public init(
    group: any EventLoopGroup, authority: Authority = .openAI, timeoutMilliseconds: Int = 10_000,
    proxy: UpstreamHTTPProxy? = nil, clock: WallClock = .system
  ) throws {
    guard (1...30_000).contains(timeoutMilliseconds) else {
      throw AccountRefreshError.invalidCommand
    }
    self.clock = clock
    self.proxy = proxy
    self.group = group
    self.timeoutMilliseconds = timeoutMilliseconds
    switch authority {
    case .openAI: realm = Self.issuer
    case .syntheticLoopback(let port):
      guard (1...65535).contains(port) else { throw AccountRefreshError.invalidCommand }
      realm = "http://127.0.0.1:\(port)"
    }
  }
  public func run() async throws {
    try state.withLock { value in
      guard !value.started else { throw AccountRefreshError.conflict }
      value.started = true
    }
    var pool = HTTPClient.Configuration.ConnectionPool(
      idleTimeout: .seconds(10), concurrentHTTP1ConnectionsPerHostSoftLimit: 4)
    pool.retryConnectionEstablishment = false
    // Connection setup may use the whole request deadline: through an explicit proxy it includes
    // the CONNECT tunnel and TLS handshake, which can approach 3 s on a healthy path.
    var configuration = HTTPClient.Configuration(
      redirectConfiguration: .disallow,
      timeout: .init(
        connect: .milliseconds(Int64(timeoutMilliseconds)), read: .seconds(5)),
      connectionPool: pool,
      proxy: proxy?.clientProxy, decompression: .disabled)
    configuration.httpVersion = .http1Only
    configuration.maximumUsesPerConnection = 1
    let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
    state.withLock { $0.client = client }
    var unexpectedFailure = false
    do { try await gracefulShutdown() } catch is CancellationError {} catch {
      unexpectedFailure = true
    }
    state.withLock { $0.client = nil }
    do { try await client.shutdown() } catch { throw AccountRefreshError.unavailable }
    if unexpectedFailure { throw AccountRefreshError.unavailable }
  }
  /// The caller must own and consume state/nonce and preserve its PKCE verifier exactly once.
  public func authorizationURL(state: String, nonce: String, verifier: String) throws -> String {
    guard Self.unreserved(state, minimum: 32, maximum: 128),
      Self.unreserved(nonce, minimum: 32, maximum: 128),
      Self.unreserved(verifier, minimum: 43, maximum: 128)
    else { throw AccountRefreshError.invalidCommand }
    let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    guard var url = URLComponents(string: realm + "/oauth/authorize") else {
      throw AccountRefreshError.invalidCommand
    }
    url.queryItems = [
      .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.clientID),
      .init(name: "redirect_uri", value: Self.callbackURI),
      .init(name: "scope", value: "openid profile email offline_access"),
      .init(name: "state", value: state), .init(name: "nonce", value: nonce),
      .init(name: "code_challenge", value: challenge),
      .init(name: "code_challenge_method", value: "S256"),
      .init(name: "id_token_add_organizations", value: "true"),
    ]
    guard let result = url.string else { throw AccountRefreshError.invalidCommand }
    return result
  }
  public func exchangeAuthorizationCode(code: String, verifier: String, expectedNonce: String)
    async throws -> VerifiedSubscriptionLogin
  {
    guard !code.isEmpty, code.utf8.count <= 4096, code.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
      Self.unreserved(verifier, minimum: 43, maximum: 128),
      Self.unreserved(expectedNonce, minimum: 32, maximum: 128)
    else { throw AccountRefreshError.invalidCommand }
    do {
      return try await authorizeCallback(
        code: code, verifier: verifier, expectedNonce: expectedNonce)
    } catch { throw AccountRefreshError.unavailable }
  }
  func authorizeCallback(code: String, verifier: String, expectedNonce: String) async throws
    -> VerifiedSubscriptionLogin
  {
    guard !code.isEmpty, code.utf8.count <= 4096, code.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
      Self.unreserved(verifier, minimum: 43, maximum: 128),
      Self.unreserved(expectedNonce, minimum: 32, maximum: 128)
    else { throw AccountAuthorizationFailure(.verificationFailed) }
    let response = try await post(
      [
        "grant_type": "authorization_code", "client_id": Self.clientID, "code": code,
        "code_verifier": verifier, "redirect_uri": Self.callbackURI,
      ], form: true, authorizationFailure: .exchangeFailed)
    return try verifyAuthorizationResponse(response, nonce: expectedNonce)
  }
  public func refresh(credential: AccountCredential, namespace: String) async throws
    -> VerifiedAccountRefresh
  {
    let baseline: SubscriptionClaims
    do {
      guard let idToken = credential.idToken else { throw AccountRefreshError.invalidCommand }
      baseline = try SubscriptionClaims.idToken(
        idToken, nonce: nil, requireCurrent: false, now: clock.unixSeconds)
      guard try identityNamespace(baseline) == namespace else {
        throw AccountRefreshError.invalidCommand
      }
    } catch { throw AccountRefreshError.invalidCommand }
    let response = try await post([
      "grant_type": "refresh_token", "client_id": Self.clientID,
      "refresh_token": credential.refreshToken,
    ])
    do {
      let accessToken = try requiredString(response, "access_token")
      let access = try SubscriptionClaims.accessToken(accessToken, now: clock.unixSeconds)
      guard baseline.matches(access) else { throw AccountRefreshError.unavailable }
      let idToken = try optionalString(response, "id_token") ?? credential.idToken
      if let freshID = response["id_token"]?.string {
        guard
          baseline.matches(
            try SubscriptionClaims.idToken(
              freshID, nonce: nil, requireCurrent: true, now: clock.unixSeconds))
        else { throw AccountRefreshError.unavailable }
      }
      let refreshed = try AccountCredential(
        accessToken: accessToken,
        refreshToken: optionalString(response, "refresh_token") ?? credential.refreshToken,
        idToken: idToken, expiresAtUnixSeconds: expiry(response, claims: access))
      return VerifiedAccountRefresh(namespace: namespace, credential: refreshed)
    } catch { throw AccountRefreshError.unavailable }
  }
  func verifyAuthorizationResponse(_ response: JSONValue, nonce: String?) throws
    -> VerifiedSubscriptionLogin
  {
    do {
      for key in ["access_token", "id_token", "refresh_token"] {
        _ = try requiredString(response, key)
      }
      if let value = response["expires_in"] {
        guard let seconds = value.integer, (1...2_592_000).contains(seconds) else {
          throw AccountRefreshError.unavailable
        }
      }
    } catch { throw AccountAuthorizationFailure(.exchangeFailed, providerStatus: 200) }
    do { return try verifyLogin(response, nonce: nonce) } catch {
      throw AccountAuthorizationFailure(.verificationFailed, providerStatus: 200)
    }
  }
  func verifyLogin(_ response: JSONValue, nonce: String?) throws -> VerifiedSubscriptionLogin {
    let accessToken = try requiredString(response, "access_token")
    let idToken = try requiredString(response, "id_token")
    let identity = try SubscriptionClaims.idToken(
      idToken, nonce: nonce, requireCurrent: true, now: clock.unixSeconds)
    let access = try SubscriptionClaims.accessToken(accessToken, now: clock.unixSeconds)
    guard identity.matches(access) else { throw AccountRefreshError.unavailable }
    let credential = try AccountCredential(
      accessToken: accessToken, refreshToken: requiredString(response, "refresh_token"),
      idToken: idToken, expiresAtUnixSeconds: expiry(response, claims: access))
    return VerifiedSubscriptionLogin(
      namespace: try identityNamespace(identity), credential: credential)
  }
  func identityNamespace(_ claims: SubscriptionClaims) throws -> String {
    // Fixed data origin/protocol; no caller-controlled organization/project routing headers.
    let value = [
      Self.dataOrigin, "codex-subscription", realm, Self.clientID, claims.subject, claims.account,
    ]
    let bytes = try JSONEncoder().encode(value)
    return "subscription-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  private func expiry(_ response: JSONValue, claims: SubscriptionClaims) throws -> Int64 {
    if let value = response["expires_in"] {
      guard let seconds = value.integer, (1...2_592_000).contains(seconds) else {
        throw AccountRefreshError.unavailable
      }
      return min(claims.expires, clock.unixSeconds + seconds)
    }
    return claims.expires
  }
  func requiredString(_ value: JSONValue, _ key: String) throws -> String {
    guard let result = value[key]?.string, !result.isEmpty, result.utf8.count <= 16_384 else {
      throw AccountRefreshError.unavailable
    }
    return result
  }
  private func optionalString(_ value: JSONValue, _ key: String) throws -> String? {
    guard value[key] != nil else { return nil }
    return try requiredString(value, key)
  }
  func post(
    _ fields: [String: String], form: Bool = false, path: String = "/oauth/token",
    device: Bool = false, authorizationFailure: AccountAuthorizationFailure.Code? = nil
  ) async throws -> JSONValue {
    let client = try state.withLock { value in
      guard let client = value.client else { throw AccountRefreshError.closed }
      guard value.active < 4 else { throw AccountRefreshError.capacity }
      value.active += 1
      return client
    }
    defer { state.withLock { $0.active -= 1 } }
    do {
      return try await withThrowingTaskGroup(of: JSONValue.self) { tasks in
        defer { tasks.cancelAll() }
        tasks.addTask { [realm, timeoutMilliseconds] in
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.withoutEscapingSlashes]
          try Task.checkCancellation()
          let body: Data
          if form {
            let allowed = CharacterSet(
              charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let pairs = try fields.keys.sorted().map { key -> String in
              guard let value = fields[key]?.addingPercentEncoding(withAllowedCharacters: allowed)
              else { throw AccountRefreshError.invalidCommand }
              return key + "=" + value
            }
            body = Data(pairs.joined(separator: "&").utf8)
          } else {
            body = try encoder.encode(fields)
          }
          guard body.count <= 65_536 else { throw AccountRefreshError.invalidCommand }
          var request = HTTPClientRequest(url: realm + path)
          request.method = .POST
          request.headers = [
            "content-type": form ? "application/x-www-form-urlencoded" : "application/json",
            "accept": "application/json", "connection": "close",
          ]
          request.body = .bytes(ByteBuffer(data: body))
          let response = try await client.execute(
            request, deadline: .now() + .milliseconds(Int64(timeoutMilliseconds)))
          // Status diagnostics never depend on (or retain) an error response body.
          if let authorizationFailure {
            if device, path.hasSuffix("/usercode"), response.status == .notFound {
              throw AccountAuthorizationFailure(.deviceCodeUnavailable, providerStatus: 404)
            }
            if device, path.hasSuffix("/token"), [.forbidden, .notFound].contains(response.status) {
              return .null
            }
            guard response.status == .ok else {
              throw AccountAuthorizationFailure(
                authorizationFailure, providerStatus: Int(response.status.code))
            }
          }
          do {
            let bytes = try await response.body.collect(upTo: 65_536)
            guard response.headers["content-type"].count == 1,
              response.headers["content-encoding"].isEmpty,
              response.headers["content-type"][0].split(
                separator: ";", omittingEmptySubsequences: false
              )
              .first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
            else { throw AccountRefreshError.unavailable }
            let document = try JSONValue.decode(Data(bytes.readableBytesView))
            guard document.object != nil else { throw AccountRefreshError.unavailable }
            guard response.status == .ok else {
              if Self.authorizationRejected(document, status: Int(response.status.code)) {
                throw AccountRefreshError.authorizationRequired
              }
              throw AccountRefreshError.unavailable
            }
            if let tokenType = document["token_type"] {
              guard tokenType.string?.lowercased() == "bearer" else {
                throw AccountRefreshError.unavailable
              }
            }
            return document
          } catch {
            if let authorizationFailure {
              throw AccountAuthorizationFailure(
                authorizationFailure == .providerRejected
                  ? .authorizationFailed : authorizationFailure,
                providerStatus: Int(response.status.code))
            }
            throw error
          }
        }
        tasks.addTask { [timeoutMilliseconds] in
          try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
          throw AccountRefreshError.unavailable
        }
        guard let result = try await tasks.next() else { throw AccountRefreshError.unavailable }
        return result
      }
    } catch {
      if let failure = error as? AccountAuthorizationFailure { throw failure }
      if let authorizationFailure {
        throw AccountAuthorizationFailure(
          authorizationFailure == .providerRejected ? .authorizationFailed : authorizationFailure,
          // HTTPClientError describes itself by case name only ("HTTPClientError.readTimeout").
          cause: error is HTTPClientError
            ? String(describing: error) : AccountAuthorizationFailure.safeCause(error))
      }
      // No HTTP request can reach the provider before a connection is established.
      if let transport = error as? IOError, transport.errnoCode == ECONNREFUSED {
        throw AccountRefreshError.notCompleted
      }
      if error is NIOConnectionError { throw AccountRefreshError.notCompleted }
      if let transport = error as? HTTPClientError, transport == .connectTimeout {
        throw AccountRefreshError.notCompleted
      }
      if error as? AccountRefreshError == .authorizationRequired {
        throw AccountRefreshError.authorizationRequired
      }
      throw AccountRefreshError.unavailable
    }
  }
  private static func authorizationRejected(_ document: JSONValue, status: Int) -> Bool {
    guard [400, 401].contains(status), document["access_token"] == nil,
      document["refresh_token"] == nil, document["id_token"] == nil
    else { return false }
    if document["error"]?.string == "invalid_grant" { return true }
    return ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(
      document["error"]?["code"]?.string ?? "")
  }
  static func unreserved(_ value: String, minimum: Int, maximum: Int) -> Bool {
    (minimum...maximum).contains(value.utf8.count)
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95, 126].contains($0)
      }
  }
  static func base64URL(_ value: Data) -> String {
    value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
}
