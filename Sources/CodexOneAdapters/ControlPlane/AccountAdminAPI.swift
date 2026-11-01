import CodexOneCore
import Foundation
import Vapor

/// Registers only beneath the shared, authenticated management route group.
public struct AccountAdminAPI: Sendable {
  private let priming: (any QuotaPrimingExecuting)?
  private let resetCredits: (any AccountResetCreditManaging)?
  private let clock: WallClock
  private let credentials: AccountCredentials?
  private let store: any AccountGovernanceStore
  private let authorization: any AccountAuthorizing
  private let refreshing: any AccountRefreshing
  private let observing: (any AccountQuotaObserving)?
  public init(
    store: any AccountGovernanceStore, authorization: any AccountAuthorizing,
    refreshing: any AccountRefreshing, observing: (any AccountQuotaObserving)? = nil,
    credentials: AccountCredentials? = nil, clock: WallClock = .system,
    resetCredits: (any AccountResetCreditManaging)? = nil,
    priming: (any QuotaPrimingExecuting)? = nil
  ) {
    self.priming = priming
    self.resetCredits = resetCredits
    self.clock = clock
    self.credentials = credentials
    self.store = store
    self.authorization = authorization
    self.refreshing = refreshing
    self.observing = observing
  }
  func register(_ routes: any RoutesBuilder) {
    routes.get { request async throws -> Response in
      let query = URLComponents(string: request.url.string)?.queryItems ?? []
      guard query.count <= 1, query.allSatisfy({ $0.name == "after" && $0.value != nil }) else {
        throw ExecutionError.invalidCommand
      }
      let accounts = try await store.listAccounts(after: query.first?.value)
      var metadata: [JSONValue] = []
      for account in accounts {
        var value = try await self.metadata(account).object!
        value["observability"] = try await observability(id: account.id, detail: false)
        metadata.append(.object(value))
      }
      return try Self.response(
        .object([
          "accounts": .array(metadata),
          "nextCursor": accounts.count == 64 ? .string(accounts.last!.id) : .null,
        ]))
    }
    routes.get(":id", "quota-priming") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      return try await Self.response(primingDTO(id: request.parameters.get("id") ?? ""))
    }
    routes.put(":id", "quota-priming") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      let body = try Self.body(request, allowed: ["revision", "enabled", "model", "message"])
      guard let revision = body["revision"]?.integer, let enabled = body["enabled"]?.bool,
        let model = body["model"]?.string, let message = body["message"]?.string,
        priming?.models.contains(model) == true, let store = store as? any QuotaPrimingStore
      else { throw ExecutionError.invalidCommand }
      _ = try await store.setQuotaPrimingSettings(
        id: request.parameters.get("id") ?? "", revision: revision,
        settings: .init(enabled: enabled, model: model, message: message))
      return try await Self.response(primingDTO(id: request.parameters.get("id") ?? ""))
    }
    routes.get(":id", "reset-credits") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      guard let resetCredits else { throw QuotaObservationFailure.closed }
      let id = request.parameters.get("id") ?? ""
      let list = try await resetCredits.listResetCredits(id: id)
      var dto = try JSONValue.decode(JSONEncoder().encode(list)).object!
      dto["state"] = try await self.resetCreditStateDTO(id: id)
      return try Self.response(.object(dto))
    }
    routes.get(":id", "reset-credits", "state") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      return try await Self.response(
        self.resetCreditStateDTO(id: request.parameters.get("id") ?? ""))
    }
    routes.put(":id", "reset-credits", "settings") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      let body = try Self.body(request, allowed: ["revision", "autoUseBeforeExpiry", "leadHours"])
      guard let revision = body["revision"]?.integer,
        let enabled = body["autoUseBeforeExpiry"]?.bool,
        let hours = body["leadHours"]?.integer, (1...168).contains(hours),
        let resetStore = store as? any AccountResetCreditStore
      else { throw ExecutionError.invalidCommand }
      let id = request.parameters.get("id") ?? ""
      _ = try await resetStore.setResetCreditSettings(
        id: id, revision: revision,
        settings: .init(autoUseBeforeExpiry: enabled, leadHours: Int(hours)))
      return try await Self.response(self.resetCreditStateDTO(id: id))
    }
    routes.post(":id", "reset-credits", "consume") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      let body = try Self.body(request, allowed: [], optional: ["creditID"])
      if let value = body["creditID"] {
        guard let id = value.string, ResetCredit.validIdentifier(id) else {
          throw ExecutionError.invalidCommand
        }
      }
      guard let resetCredits else { throw QuotaObservationFailure.closed }
      let result = try await resetCredits.consumeResetCredit(
        id: request.parameters.get("id") ?? "", creditID: body["creditID"]?.string)
      return try Self.response(JSONValue.decode(JSONEncoder().encode(result)))
    }
    routes.get(":id", "observation") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      return try await Self.response(
        observability(id: request.parameters.get("id") ?? "", detail: true))
    }
    routes.post(":id", "observe") { request async throws -> Response in
      _ = try Self.body(request, allowed: [])
      guard let observing else { throw QuotaObservationFailure.closed }
      let id = request.parameters.get("id") ?? ""
      _ = try await observing.observeAccount(id: id)
      return try await Self.response(observability(id: id, detail: true))
    }
    routes.put(":id", "display-name") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      let document = try Self.body(request, allowed: ["revision", "displayName"])
      guard let revision = document["revision"]?.integer,
        document["displayName"] == .null || document["displayName"]?.string != nil
      else { throw ExecutionError.invalidCommand }
      let account = try await store.setAccountDisplayName(
        id: request.parameters.get("id") ?? "",
        revision: revision, displayName: document["displayName"]?.string)
      return try Self.response(.object(["account": await self.metadata(account)]))
    }
    routes.put(":id") { request async throws -> Response in
      let document = try Self.body(request, allowed: ["revision", "mode"])
      guard let revision = document["revision"]?.integer,
        let raw = document["mode"]?.string, let mode = AccountMode(rawValue: raw)
      else { throw ExecutionError.invalidCommand }
      let account = try await store.setAccountMode(
        id: request.parameters.get("id") ?? "", revision: revision, mode: mode)
      return try Self.response(.object(["account": await self.metadata(account)]))
    }
    routes.post(":id", "refresh") { request async throws -> Response in
      let document = try Self.body(request, allowed: ["revision"])
      guard let revision = document["revision"]?.integer else {
        throw ExecutionError.invalidCommand
      }
      let account = try await refreshing.refreshAccount(
        id: request.parameters.get("id") ?? "", revision: revision)
      return try Self.response(.object(["account": await self.metadata(account)]))
    }
    routes.post("authorization") { request async throws -> Response in
      guard let owner = request.storage[AdminOwnerKey.self] else {
        throw ExecutionError.unauthorized
      }
      let document = try Self.body(request, allowed: ["target"], optional: ["method"])
      let method: AccountAuthorizationMethod
      if document["method"] == nil {
        method = .device
      } else if let raw = document["method"]?.string,
        let parsed = AccountAuthorizationMethod(rawValue: raw)
      {
        method = parsed
      } else {
        throw ExecutionError.invalidCommand
      }
      let target: AccountAuthorizationTarget
      if document["target"] == .null {
        target = .create
      } else {
        guard let object = document["target"]?.object, Set(object.keys) == ["id", "revision"],
          let id = object["id"]?.string, let revision = object["revision"]?.integer
        else { throw ExecutionError.invalidCommand }
        target = .reauthorize(id: id, revision: revision)
      }
      let started = try await authorization.begin(owner: owner, target: target, method: method)
      var dto: [String: JSONValue] = [
        "flowID": .string(started.flowID), "method": .string(started.method.rawValue),
        "expiresInSeconds": .number(Decimal(started.expiresInSeconds)),
      ]
      if method == .callback { dto["authorizationURL"] = .string(started.authorizationURL) }
      if let code = started.userCode { dto["userCode"] = .string(code) }
      if let url = started.verificationURL { dto["verificationURL"] = .string(url) }
      if let interval = started.intervalSeconds {
        dto["intervalSeconds"] = .number(Decimal(interval))
      }
      if let failure = started.failureCode { dto["failureCode"] = .string(failure) }
      return try Self.response(.object(dto))
    }
    routes.get("authorization", ":flowID") { request async throws -> Response in
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      guard let owner = request.storage[AdminOwnerKey.self] else {
        throw ExecutionError.unauthorized
      }
      let status = try await authorization.status(
        owner: owner, flowID: request.parameters.get("flowID") ?? "")
      return try Self.response(JSONValue.decode(JSONEncoder().encode(status)))
    }
    routes.post("authorization", ":flowID") { request async throws -> Response in
      guard let owner = request.storage[AdminOwnerKey.self] else {
        throw ExecutionError.unauthorized
      }
      let document = try Self.body(request, allowed: ["callbackURL"])
      guard let callbackURL = document["callbackURL"]?.string else {
        throw ExecutionError.invalidCommand
      }
      let account = try await authorization.complete(
        owner: owner, flowID: request.parameters.get("flowID") ?? "", callbackURL: callbackURL)
      return try Self.response(.object(["account": await self.metadata(account)]))
    }
    routes.delete("authorization", ":flowID") { request async throws -> Response in
      guard let owner = request.storage[AdminOwnerKey.self] else {
        throw ExecutionError.unauthorized
      }
      guard request.url.query == nil else { throw ExecutionError.invalidCommand }
      let id = request.parameters.get("flowID") ?? ""
      _ = try await authorization.status(owner: owner, flowID: id)
      await authorization.discard(owner: owner, flowID: id)
      return try Self.response(.object(["discarded": .bool(true)]))
    }
  }
  private func primingDTO(id: String) async throws -> JSONValue {
    guard let store = store as? any QuotaPrimingStore else { throw QuotaObservationFailure.closed }
    let state = try await store.quotaPrimingState(id: id)
    return .object([
      "revision": .number(Decimal(state.revision)),
      "settings": try JSONValue.decode(JSONEncoder().encode(state.settings)),
      "models": .array((priming?.models ?? []).map { .string($0) }),
      "defaultModel": priming?.defaultModel.map { .string($0) } ?? .null,
      "lastAttemptAt": state.lastAttemptAt.map { .number(Decimal($0)) } ?? .null,
      "lastResult": state.lastResult.map { .string($0) } ?? .null,
      "attention": state.attention.map { .string($0) } ?? .null,
    ])
  }
  private func resetCreditStateDTO(id: String) async throws -> JSONValue {
    guard let resetStore = store as? any AccountResetCreditStore else {
      throw QuotaObservationFailure.closed
    }
    let state = try await resetStore.resetCreditState(id: id)
    return .object([
      "revision": .number(Decimal(state.revision)),
      "settings": try JSONValue.decode(JSONEncoder().encode(state.settings)),
      "pending": .bool(state.intent != nil),
      "pendingCreditID": state.intent?.creditID.map { .string($0) } ?? .null,
      "lastCode": state.lastCode.map { .string($0.rawValue) } ?? .null,
      "lastAttemptAt": state.lastAttemptAt.map { .number(Decimal($0)) } ?? .null,
    ])
  }
  private func observability(id: String, detail: Bool) async throws -> JSONValue {
    guard let observations = store as? any AccountObservationStore,
      let health = store as? any AccountHealthStore
    else { throw ExecutionError.storageUnavailable }
    let quota = try await observations.quotaObservation(id: id)
    let status = try await health.accountHealth(id: id)
    return accountObservationDTO(
      quota, health: status, observing: observing?.isAccepting == true, detail: detail,
      now: clock.unixSeconds)
  }
  private func metadata(_ account: ManagedAccount) async throws -> JSONValue {
    let updated = try await store.credentialUpdatedAtUnixSeconds(id: account.id)
    let expiration = try? await credentials?.accessExpiresAtUnixSeconds(id: account.id)
    return .object([
      "accessExpiresAtUnixSeconds": expiration.map { .number(Decimal($0)) } ?? .null,
      "credentialUpdatedAtUnixSeconds": updated.map { .number(Decimal($0)) } ?? .null,
      "displayName": account.displayName.map { .string($0) } ?? .null,
      "id": .string(account.id), "revision": .number(Decimal(account.revision)),
      "credentialVersion": .number(Decimal(account.credentialVersion)),
      "mode": .string(account.mode.rawValue),
      "authorization": .string(account.authorization.rawValue),
      "createdAtUnixSeconds": .number(Decimal(account.createdAtUnixSeconds)),
    ])
  }
  private static func body(_ request: Request, allowed: Set<String>, optional: Set<String> = [])
    throws -> JSONValue
  {
    guard request.headers["content-type"].count == 1,
      request.headers.first(name: "content-type")?.lowercased().split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces) == "application/json",
      request.headers["content-encoding"].isEmpty,
      let buffer = request.body.data
    else { throw ExecutionError.invalidCommand }
    let document = try JSONValue.decode(Data(buffer.readableBytesView))
    guard let object = document.object, allowed.isSubset(of: Set(object.keys)),
      Set(object.keys).isSubset(of: allowed.union(optional))
    else {
      throw ExecutionError.invalidCommand
    }
    return document
  }
  private static func response(_ document: JSONValue) throws -> Response {
    Response(
      status: .ok,
      headers: [
        "content-type": "application/json", "cache-control": "no-store", "connection": "close",
      ],
      body: .init(data: try document.data()))
  }
}
struct AdminOwnerKey: StorageKey { typealias Value = String }
