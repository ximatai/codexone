import CodexOneCore
import Dispatch
import Foundation
import Synchronization
import Vapor

/// Independent administrator authentication for headless requests and protected browser sessions.
public struct KeyAdminAPI: Sendable {
  private let digest: String
  private let store: any KeyGovernanceStore
  private let sessions: AdminSessions
  private let availableModels: [String]
  private let imageModels: [String]
  private let usage: UsageAdminAPI?
  private let storageMonitoring: (any StorageMonitoring)?
  public static func load(
    path: String, store: any KeyGovernanceStore, forbiddenDigest: String? = nil,
    publicOrigin: String? = nil, availableModels: [String] = [], imageModels: [String] = [],
    usage: UsageAdminAPI? = nil, storageMonitoring: (any StorageMonitoring)? = nil
  ) async throws -> Self {
    let digest = try await loadDigest(path)
    guard digest != forbiddenDigest else { throw ExecutionError.invalidCommand }
    guard availableModels.count <= 32, imageModels.count <= 16,
      (availableModels + imageModels).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 })
    else { throw ExecutionError.invalidCommand }
    return Self(
      digest: digest, store: store,
      sessions: try AdminSessions(digest: digest, publicOrigin: publicOrigin),
      availableModels: availableModels, imageModels: imageModels, usage: usage,
      storageMonitoring: storageMonitoring)
  }
  public static func validateCredential(
    path: String, forbiddenDigest: String? = nil, publicOrigin: String? = nil
  ) async throws {
    if let publicOrigin { _ = try AdminSessions.canonicalOrigin(publicOrigin) }
    guard try await loadDigest(path) != forbiddenDigest else { throw ExecutionError.invalidCommand }
  }
  private static func loadDigest(_ path: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let secret = try readRuntimeSecret(path)
          guard secret.utf8.count >= 32, !secret.hasPrefix("co1_") else {
            throw ExecutionError.invalidCommand
          }
          continuation.resume(returning: try bearerDigest(["Bearer " + secret]))
        } catch { continuation.resume(throwing: ExecutionError.invalidCommand) }
      }
    }
  }
  func bind(port: Int) { sessions.bind(port: port) }
  func register(_ app: Application, accounts: AccountAdminAPI? = nil) {
    let api = app.grouped("api").grouped(AdminFailureMiddleware())
    let guardMiddleware = KeyAdminGuard(digest: digest, sessions: sessions)
    let routes = api.grouped("keys").grouped(guardMiddleware)
    accounts?.register(api.grouped("accounts").grouped(guardMiddleware))
    usage?.register(api.grouped("usage").grouped(guardMiddleware))
    if let storageMonitoring {
      api.grouped("runtime").grouped(guardMiddleware).get("storage") { _ async throws -> Response in
        let observation = storageMonitoring.storageObservation
        var object =
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))
          as! [String: Any]
        object["admissionAllowed"] = observation.admissionAllowed
        object["optionalWorkAllowed"] = observation.optionalWorkAllowed
        let data = try JSONSerialization.data(withJSONObject: object)
        return Response(
          status: .ok, headers: ["content-type": "application/json", "cache-control": "no-store"],
          body: .init(data: data))
      }
    }
    api.post("session") { request async throws -> Response in
      let document = try Self.body(request, allowed: ["secret"])
      guard let secret = document["secret"]?.string else { throw ExecutionError.invalidCommand }
      let created = try sessions.login(secret: secret, headers: request.headers)
      let response = try Self.response(
        .object(["authenticated": .bool(true), "csrf": .string(created.csrf)]))
      response.headers.add(
        name: "set-cookie", value: Self.cookie(created.token, age: created.maximumAge))
      return response
    }
    api.get("session") { request async throws -> Response in
      let csrf = try sessions.authorize(request.headers, mutation: false)
      return try Self.response(.object(["authenticated": .bool(true), "csrf": .string(csrf)]))
    }
    api.delete("session") { request async throws -> Response in
      try sessions.logout(request.headers)
      let response = try Self.response(.object(["authenticated": .bool(false)]))
      response.headers.add(name: "set-cookie", value: Self.cookie("", age: 0))
      return response
    }
    routes.get("options") { _ async throws -> Response in
      try Self.response(
        .object([
          "models": .array(availableModels.map { .string($0) }),
          "imageModels": .array(imageModels.map { .string($0) }),
        ]))
    }
    routes.get { request async throws -> Response in
      let query = URLComponents(string: request.url.string)?.queryItems ?? []
      guard query.count <= 1, query.allSatisfy({ $0.name == "after" && $0.value != nil }) else {
        throw ExecutionError.invalidCommand
      }
      let keys = try await store.listKeys(after: query.first?.value)
      return try Self.response(
        .object([
          "keys": .array(keys.map(Self.metadata)),
          "nextCursor": keys.count == 64 ? .string(keys.last!.id) : .null,
        ]))
    }
    routes.post { request async throws -> Response in
      let document = try Self.body(request, allowed: ["principal", "models", "limits"])
      let dto = try JSONDecoder().decode(CreateKeyDTO.self, from: document.data())
      let secret = generateKeySecret()
      let key = try await store.createKey(
        id: UUID().uuidString, principal: dto.principal,
        digest: keyDigest(secret), policy: dto.policy())
      return try Self.response(
        .object(["key": Self.metadata(key), "secret": .string(secret)]), status: .created)
    }
    routes.put(":id") { request async throws -> Response in
      let document = try Self.body(
        request, allowed: ["revision", "enabled", "models", "limits"])
      let dto = try JSONDecoder().decode(UpdateKeyDTO.self, from: document.data())
      let key = try await store.updateKey(
        id: request.parameters.get("id") ?? "", revision: dto.revision,
        enabled: dto.enabled, policy: dto.policy())
      return try Self.response(.object(["key": Self.metadata(key)]))
    }
    routes.post(":id", "rotate") { request async throws -> Response in
      let document = try Self.body(request, allowed: ["revision"])
      guard let revision = document["revision"]?.integer else {
        throw ExecutionError.invalidCommand
      }
      let secret = generateKeySecret()
      let key = try await store.rotateKey(
        id: request.parameters.get("id") ?? "", revision: revision,
        digest: keyDigest(secret))
      return try Self.response(
        .object(["key": Self.metadata(key), "secret": .string(secret)]), status: .created)
    }
  }
  private static func cookie(_ token: String, age: Int) -> String {
    AdminSessions.cookieName + "=" + token
      + "; Path=/; Max-Age=\(age); HttpOnly; Secure; SameSite=Strict"
  }
  private static func body(_ request: Request, allowed: Set<String>) throws -> JSONValue {
    guard request.headers["content-type"].count == 1,
      request.headers.first(name: "content-type")?.lowercased().hasPrefix("application/json")
        == true,
      request.headers["content-encoding"].isEmpty
    else { throw ExecutionError.invalidCommand }
    guard let buffer = request.body.data else { throw ExecutionError.invalidCommand }
    let document = try JSONValue.decode(Data(buffer.readableBytesView))
    let optional: Set<String> =
      allowed.contains("limits") ? ["visionInput", "imageGeneration", "imageModels"] : []
    guard let object = document.object,
      Set(object.keys).subtracting(optional) == allowed
        && Set(object.keys).isSubset(of: allowed.union(optional))
    else {
      throw ExecutionError.invalidCommand
    }
    if let limits = document["limits"] {
      guard let keys = limits.object?.keys,
        Set(keys) == ["requests", "active", "unresolved", "budgetMicros", "unresolvedMicros"]
      else { throw ExecutionError.invalidCommand }
    }
    return document
  }
  private static func metadata(_ key: ManagedKey) -> JSONValue {
    .object([
      "id": .string(key.id), "principal": .string(key.principal),
      "revision": .number(Decimal(key.revision)),
      "enabled": .bool(key.enabled), "models": .array(key.policy.models.map { .string($0) }),
      "visionInput": .bool(key.policy.visionInput),
      "imageGeneration": .bool(key.policy.imageGeneration),
      "imageModels": .array(key.policy.imageModels.map { .string($0) }),
      "createdAtUnixSeconds": .number(Decimal(key.createdAtUnixSeconds)),
      "limits": .object([
        "requests": key.policy.limits.requests.map { .number(Decimal($0)) } ?? .null,
        "active": key.policy.limits.active.map { .number(Decimal($0)) } ?? .null,
        "unresolved": key.policy.limits.unresolved.map { .number(Decimal($0)) } ?? .null,
        "budgetMicros": key.policy.limits.budgetMicros.map { .number(Decimal($0)) } ?? .null,
        "unresolvedMicros": key.policy.limits.unresolvedMicros.map { .number(Decimal($0)) }
          ?? .null,
      ]),
    ])
  }
  private static func response(_ document: JSONValue, status: HTTPStatus = .ok) throws -> Response {
    Response(
      status: status,
      headers: [
        "content-type": "application/json", "cache-control": "no-store", "connection": "close",
      ],
      body: .init(data: try document.data()))
  }
}

private struct KeyLimitsDTO: Decodable {
  let requests: Int64?, active: Int64?, unresolved: Int64?, budgetMicros: Int64?,
    unresolvedMicros: Int64?
  var value: ExecutionLimits {
    .init(
      requests: requests, active: active, unresolved: unresolved,
      budgetMicros: budgetMicros, unresolvedMicros: unresolvedMicros)
  }
}
private struct CreateKeyDTO: Decodable {
  let principal: String, models: [String], limits: KeyLimitsDTO
  let visionInput: Bool?, imageGeneration: Bool?, imageModels: [String]?
  func policy() throws -> KeyPolicy {
    try .init(
      models: models, limits: limits.value, visionInput: visionInput ?? false,
      imageGeneration: imageGeneration ?? false, imageModels: imageModels ?? [])
  }
}
private struct UpdateKeyDTO: Decodable {
  let revision: Int64, enabled: Bool, models: [String], limits: KeyLimitsDTO
  let visionInput: Bool?, imageGeneration: Bool?, imageModels: [String]?
  func policy() throws -> KeyPolicy {
    try .init(
      models: models, limits: limits.value, visionInput: visionInput ?? false,
      imageGeneration: imageGeneration ?? false, imageModels: imageModels ?? [])
  }
}
private struct KeyAdminGuard: AsyncMiddleware {
  let digest: String
  let sessions: AdminSessions
  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    if !request.headers["authorization"].isEmpty {
      guard request.headers["origin"].isEmpty, request.headers["sec-fetch-site"].isEmpty,
        request.headers["cookie"].isEmpty
      else { throw GatewayProtocolError(403, "mixed_browser_credentials") }
      let supplied = try bearerDigest(request.headers["authorization"])
      guard zip(supplied.utf8, digest.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
        throw ExecutionError.unauthorized
      }
      request.storage[AdminOwnerKey.self] = digest
    } else {
      request.storage[AdminOwnerKey.self] = try sessions.authorize(
        request.headers, mutation: request.method != .GET)
    }
    return try await next.respond(to: request)
  }
}
private struct AdminFailureMiddleware: AsyncMiddleware {
  private let capacity = KeyAdminCapacity()
  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    do {
      guard capacity.reserve() else { throw GatewayProtocolError(503, "management_capacity") }
      defer { capacity.release() }
      return try await next.respond(to: request)
    } catch {
      let status: Int
      let code: String
      if let failure = error as? GatewayProtocolError {
        status = failure.status
        code = failure.code
      } else if let failure = error as? QuotaObservationFailure {
        status = 503
        code = failure == .capacity ? "observation_capacity" : "observation_unavailable"
      } else if let failure = error as? AccountRefreshError {
        switch failure {
        case .invalidCommand:
          status = 400
          code = "invalid_authorization_command"
        case .conflict:
          status = 409
          code = "account_conflict"
        case .authorizationRequired:
          status = 409
          code = "authorization_required"
        case .storageUnavailable:
          status = 503
          code = "account_storage_unavailable"
        default:
          status = 503
          code = "account_unavailable"
        }
      } else if let failure = error as? ExecutionError {
        switch failure {
        case .invalidCommand:
          status = 400
          code = "invalid_command"
        case .conflict:
          status = 409
          code = "revision_conflict"
        case .unauthorized:
          status = 401
          code = "invalid_admin_credential"
        default:
          status = 503
          code = "management_unavailable"
        }
      } else {
        status = 400
        code = "invalid_command"
      }
      return Response(
        status: .init(statusCode: status),
        headers: [
          "content-type": "application/json", "cache-control": "no-store", "connection": "close",
        ],
        body: .init(
          data: try JSONValue.object([
            "error": .object([
              "code": .string(code), "message": .string("Management request failed."),
              "request_id": .string(UUID().uuidString),
            ])
          ]).data()))
    }
  }
}

private final class KeyAdminCapacity: Sendable {
  private let active = Mutex(0)
  func reserve() -> Bool {
    active.withLock { count in
      guard count < 16 else { return false }
      count += 1
      return true
    }
  }
  func release() { active.withLock { $0 -= 1 } }
}
