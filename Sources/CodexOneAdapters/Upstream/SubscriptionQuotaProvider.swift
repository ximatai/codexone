import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import ServiceLifecycle
import Synchronization

/// Passive quota GETs have their own network capacity; they cannot consume refresh slots.
public final class SubscriptionQuotaProvider: Service, AccountQuotaProvider, Sendable {
  private struct State {
    var started = false
    var client: HTTPClient?
    var active = 0
  }
  private let state = Mutex(State())
  private let group: any EventLoopGroup
  private let verifier: SubscriptionOAuthProvider
  private let target: SubscriptionDataTarget
  private let timeoutMilliseconds: Int
  private let proxy: UpstreamHTTPProxy?
  public var isAccepting: Bool { state.withLock { $0.client != nil } }
  public var activeRequests: Int { state.withLock { $0.active } }
  public convenience init(
    group: any EventLoopGroup, verifier: SubscriptionOAuthProvider, proxy: UpstreamHTTPProxy? = nil
  ) throws {
    try self.init(
      group: group, verifier: verifier, target: .openAI, timeoutMilliseconds: 5000, proxy: proxy)
  }
  /// Explicit credential-free fixture assembly; never selected by production configuration.
  public static func syntheticLoopback(
    group: any EventLoopGroup, verifier: SubscriptionOAuthProvider, port: Int,
    proxy: UpstreamHTTPProxy? = nil
  ) throws -> SubscriptionQuotaProvider {
    guard verifier.realm.hasPrefix("http://127.0.0.1:"), (1...65535).contains(port) else {
      throw QuotaObservationFailure.unavailable
    }
    return try .init(
      group: group, verifier: verifier, target: .syntheticLoopback(port: port), proxy: proxy)
  }
  init(
    group: any EventLoopGroup, verifier: SubscriptionOAuthProvider, target: SubscriptionDataTarget,
    timeoutMilliseconds: Int = 5000, proxy: UpstreamHTTPProxy? = nil
  ) throws {
    guard (1...30_000).contains(timeoutMilliseconds) else {
      throw QuotaObservationFailure.unavailable
    }
    self.proxy = proxy
    self.group = group
    self.verifier = verifier
    self.target = target
    self.timeoutMilliseconds = timeoutMilliseconds
  }
  public func run() async throws {
    try state.withLock { value in
      guard !value.started else { throw QuotaObservationFailure.closed }
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
    do { try await gracefulShutdown() } catch is CancellationError {} catch {
      state.withLock { $0.client = nil }
      try await client.shutdown()
      throw QuotaObservationFailure.unavailable
    }
    state.withLock { $0.client = nil }
    try await client.shutdown()
  }
  public func observe(_ work: AccountObservationWork) async throws -> SubscriptionQuota {
    let access = try verifier.quotaAccess(work: work, target: target)
    let client = try state.withLock { value in
      guard let client = value.client else { throw QuotaObservationFailure.closed }
      guard value.active < 4 else { throw QuotaObservationFailure.capacity }
      value.active += 1
      return client
    }
    defer { state.withLock { $0.active -= 1 } }
    do {
      return try await withThrowingTaskGroup(of: SubscriptionQuota.self) { tasks in
        defer { tasks.cancelAll() }
        tasks.addTask { [timeoutMilliseconds] in
          var request = HTTPClientRequest(url: access.baseURL)
          request.method = .GET
          request.headers = access.headers
          request.headers.add(name: "accept", value: "application/json")
          request.headers.add(name: "user-agent", value: "codex-cli")
          let response = try await client.execute(
            request, deadline: .now() + .milliseconds(Int64(timeoutMilliseconds)))
          guard response.status == .ok else {
            if response.status == .unauthorized {
              throw QuotaObservationFailure.authorizationRejected
            }
            if response.status == .tooManyRequests { throw QuotaObservationFailure.rateLimited }
            throw QuotaObservationFailure.unavailable
          }
          guard response.headers["content-type"].count == 1,
            response.headers["content-encoding"].isEmpty,
            response.headers["content-type"][0].split(
              separator: ";", omittingEmptySubsequences: false
            )
            .first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
          else { throw QuotaObservationFailure.invalidResponse }
          let bytes = try await response.body.collect(upTo: 65_536)
          let document: JSONValue
          do { document = try JSONValue.decode(Data(bytes.readableBytesView)) } catch {
            throw QuotaObservationFailure.invalidResponse
          }
          if let returnedAccount = document["account_id"], returnedAccount != .null {
            guard returnedAccount.string == access.headers.first(name: "chatgpt-account-id") else {
              throw QuotaObservationFailure.invalidResponse
            }
          }
          do { return try Self.parse(document) } catch {
            throw QuotaObservationFailure.invalidResponse
          }
        }
        tasks.addTask { [timeoutMilliseconds] in
          try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
          throw QuotaObservationFailure.unavailable
        }
        guard let value = try await tasks.next() else { throw QuotaObservationFailure.unavailable }
        return value
      }
    } catch {
      if Task.isCancelled { throw QuotaObservationFailure.closed }
      throw error as? QuotaObservationFailure ?? .unavailable
    }
  }
  static func parse(_ value: JSONValue) throws -> SubscriptionQuota {
    guard value.object != nil else { throw QuotaObservationFailure.invalidResponse }
    func optionalBool(_ value: JSONValue?) throws -> Bool? {
      guard let value, value != .null else { return nil }
      guard let result = value.bool else { throw QuotaObservationFailure.invalidResponse }
      return result
    }
    func integer(_ value: JSONValue?) throws -> Int64? {
      guard let value, value != .null else { return nil }
      guard let result = value.integer else { throw QuotaObservationFailure.invalidResponse }
      return result
    }
    func window(_ value: JSONValue?) throws -> SubscriptionQuotaWindow? {
      guard let value, value != .null else { return nil }
      guard value.object != nil else { throw QuotaObservationFailure.invalidResponse }
      let used: Double?
      if let number = value["used_percent"], number != .null {
        guard case .number(let decimal) = number else {
          throw QuotaObservationFailure.invalidResponse
        }
        used = NSDecimalNumber(decimal: decimal).doubleValue
      } else {
        used = nil
      }
      return try .init(
        usedPercent: used, durationSeconds: integer(value["limit_window_seconds"]),
        resetsAtUnixSeconds: integer(value["reset_at"]))
    }
    func limit(_ value: JSONValue, id: String) throws -> SubscriptionQuotaLimit {
      guard value.object != nil else { throw QuotaObservationFailure.invalidResponse }
      return try .init(
        id: id, allowed: optionalBool(value["allowed"]),
        limitReached: optionalBool(value["limit_reached"]),
        primary: window(value["primary_window"]), secondary: window(value["secondary_window"]))
    }
    var limits: [SubscriptionQuotaLimit] = []
    if let base = value["rate_limit"], base != .null { limits.append(try limit(base, id: "codex")) }
    if let additional = value["additional_rate_limits"], additional != .null {
      guard let entries = additional.array, entries.count <= 16 else {
        throw QuotaObservationFailure.invalidResponse
      }
      for entry in entries {
        guard let name = entry["metered_feature"]?.string ?? entry["limit_name"]?.string else {
          throw QuotaObservationFailure.invalidResponse
        }
        if let details = entry["rate_limit"], details != .null {
          limits.append(try limit(details, id: name))
        }
      }
    }
    return try .init(limits: limits)
  }
}
