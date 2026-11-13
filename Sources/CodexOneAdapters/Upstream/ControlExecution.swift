import AsyncHTTPClient
import CodexOneCore
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Synchronization

struct ControlRoute: Sendable {
  let path: String
  var local: Bool { path == "/backend-api/codex/analytics-events/events" }
  var realtime: Bool { path == "/backend-api/codex/realtime/calls" }
  var seconds: Int { path == "/backend-api/codex/memories/trace_summarize" ? 300 : 60 }
  static let requestBytes = 8 * 1024 * 1024
  static let responseBytes = 16 * 1024 * 1024
  static func match(method: HTTPMethod, path: String) -> Self? {
    let posts = [
      "alpha/search", "memories/trace_summarize", "realtime/calls", "safety/arc",
      "thread/goal/get", "thread/goal/set", "thread/goal/clear", "analytics-events/events",
    ]
    if method == .POST && posts.contains(where: { path == "/backend-api/codex/" + $0 }) {
      return Self(path: path)
    }
    if method == .GET
      && [
        "/backend-api/codex/thread/goal/get", "/backend-api/codex/agent-identities/jwks",
        "/backend-api/wham/agent-identities/jwks",
      ].contains(path)
    {
      return Self(path: path)
    }
    return nil
  }
}

private enum ControlLog {
  static let logger = Logger(label: "codexone.control")
  static let gate = Mutex(ProtocolFailureLogGate())
  static func record(
    route: ControlRoute, key: String, account: String?, status: Int, start: ContinuousClock.Instant
  ) {
    guard gate.withLock({ $0.admit(now: .now) }) else { return }
    let elapsed = start.duration(to: .now).components
    var metadata: Logger.Metadata = [
      "status": .string(String(status)),
      "elapsed_ms": .string(
        String(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)),
    ]
    if !route.realtime {
      metadata["path_category"] = .string(String(route.path.dropFirst("/backend-api/".count)))
      metadata["key_id"] = .string(key)
      if let account { metadata["account_id"] = .string(account) }
    }
    logger.info("Control request ended", metadata: metadata)
  }
}

struct ControlReply: Sendable {
  let status: Int
  let headers: HTTPHeaders
  let body: Data
}

extension HTTPResponseExecution {
  func executeControl(
    _ route: ControlRoute, head: HTTPRequestHead, body: Data,
    deliver: @escaping @Sendable (ControlReply) async throws -> Void
  ) async throws {
    let start = ContinuousClock.now
    if case .single(let config) = access.source, config.managedKeys != true {
      throw ExecutionError.unauthorized
    }
    let policy = try await access.policy(access.digest(head.headers["authorization"]))
    let key = policy.keyID
    let selectedAccount = Mutex<String?>(nil)
    if case .single(let single) = policy { selectedAccount.withLock { $0 = single.owner.identity } }
    var status = 502
    defer {
      ControlLog.record(
        route: route, key: key, account: selectedAccount.withLock { $0 }, status: status,
        start: start)
    }
    do {
      let permit = try controlCapacity.acquire(key: key)
      defer { permit.release() }
      guard body.count <= ControlRoute.requestBytes else {
        throw GatewayProtocolError(413, "request_too_large")
      }
      if route.local {
        status = 202
        try await deliver(
          ControlReply(
            status: 202, headers: ["content-type": "application/json"], body: Data("{}".utf8)))
        return
      }
      status = try await withExecutionDeadline(seconds: route.seconds) {
        let metadataHeaders = try forwardedClientHeaders(
          head.headers, fingerprint: configuration.clientFingerprint, registry: protocolExtensions)
        let work: AccountDispatchWork?
        let authorize: @Sendable () throws -> SubscriptionDataAccess?
        let routing = access.store as? any AccountRoutingStore
        let tracking = access.store.accountExecutions.map { _ in AccountExecution() }
        if case .pool(let gateway, let provider, let target) = try access.gateway(policy) {
          let token = try requestTurnState(headers: metadataHeaders)
          let required = try token.map { try turnStateOwners.owner(key: key, token: $0) }
          let selected = try await gateway.authorizeControl(
            preferred: sessionAffinity.preferred(key: key, headers: metadataHeaders),
            requiredAccount: required, cooldowns: { controlHealth.cooldowns(route: route.path) },
            tracking: tracking)
          selectedAccount.withLock { $0 = selected.account.id }
          work = selected
          authorize = { try provider.dataAccess(work: selected, target: target) }
        } else {
          work = nil
          authorize = { nil }
        }
        defer {
          if let tracking, let work {
            access.store.accountExecutions?.finish(tracking, account: work.account.id)
          }
        }
        let forward: @Sendable () async throws -> Int = {
          let authorization = try authorize()
          guard
            var url = URLComponents(string: authorization?.baseURL ?? configuration.upstreamBaseURL)
          else {
            throw ExecutionError.invalidCommand
          }
          // Preserve the raw query verbatim, including escapes, order, duplicates and empty values.
          url.path = route.path
          url.query = nil
          url.fragment = nil
          let query = head.uri.firstIndex(of: "?").map { String(head.uri[$0...]) } ?? ""
          var upstream = HTTPClientRequest(url: url.string! + query)
          upstream.method = head.method
          upstream.headers = metadataHeaders
          let clientConnectionHeaders = Set(
            head.headers["connection"].flatMap {
              $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            })
          for name in ["content-type", "accept"] where !clientConnectionHeaders.contains(name) {
            for value in head.headers[name] { upstream.headers.add(name: name, value: value) }
          }
          if let authorization {
            for header in authorization.headers {
              upstream.headers.add(name: header.name, value: header.value)
            }
          } else if let token {
            upstream.headers.add(name: "authorization", value: "Bearer " + token)
          }
          upstream.body = .bytes(ByteBuffer(data: body))
          let response = try await client.execute(
            upstream, deadline: .now() + .seconds(Int64(route.seconds + 5)))
          let succeeded = (200...399).contains(Int(response.status.code))
          var data = Data()
          do {
            for try await chunk in response.body {
              try Task.checkCancellation()
              guard chunk.readableBytes <= ControlRoute.responseBytes - data.count else {
                throw GatewayProtocolError(502, "upstream_response_too_large")
              }
              data.append(contentsOf: chunk.readableBytesView)
            }
          } catch
            where !succeeded && (!(error is CancellationError) || tracking?.wasForced == true)
          {
            // The status already classifies the account; an unreadable error body must not hide it.
            data = Data()
          }
          guard succeeded else {
            let document = try? JSONValue.decode(data)
            throw ProviderError.failure(
              status: Int(response.status.code), error: document?["error"] ?? document?["detail"],
              retryAfter: ProviderError.retryAfter(response.headers))
          }
          var headers = forwardedResponseHeaders(response.headers)
          if let identity = authorization?.identity,
            let token = headers.first(name: "x-codex-turn-state")
          {
            turnStateOwners.observe(key: key, token: token, account: identity)
          }
          let allowed: Set<String> = [
            "content-type", "content-encoding", "vary", "cache-control", "etag", "last-modified",
            "retry-after",
          ]
          let connection = Set(
            response.headers["connection"].flatMap {
              $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            })
          for header in response.headers
          where allowed.contains(header.name.lowercased())
            && !connection.contains(header.name.lowercased())
          {
            headers.add(name: header.name, value: header.value)
          }
          try await deliver(
            ControlReply(status: Int(response.status.code), headers: headers, body: data))
          return Int(response.status.code)
        }
        let execute: @Sendable () async throws -> Int = {
          do {
            return try await forward()
          } catch {
            if let work {
              let failure = executionFailure(error)
              if [.authenticationRejected, .rateLimited].contains(failure), let routing {
                try await routing.recordAccountWideOutcome(
                  account: AccountRouteCandidate(work: work),
                  outcome: .init(
                    failure: failure, atUnixSeconds: access.clock.unixSeconds,
                    cooldownSeconds: (error as? GatewayProtocolError)?.cooldownSeconds))
              } else if failure == .upstreamUnavailable {
                controlHealth.record(
                  route: route.path,
                  account: try .init(id: work.account.id, namespace: work.account.namespace),
                  seconds: (error as? GatewayProtocolError)?.cooldownSeconds)
              }
            }
            throw error
          }
        }
        if let tracking, work != nil { return try await tracking.run(execute) }
        return try await execute()
      }
    } catch {
      status = protocolFailure(error).status
      throw error
    }
  }
}
