import CodexOneCore
import Foundation
import Vapor

/// Registers only beneath the shared, authenticated management route group.
public struct AccountAdminAPI: Sendable {
  private let store: any AccountGovernanceStore
  private let authorization: any AccountAuthorizing
  private let refreshing: any AccountRefreshing
  public init(
    store: any AccountGovernanceStore, authorization: any AccountAuthorizing,
    refreshing: any AccountRefreshing
  ) {
    self.store = store
    self.authorization = authorization
    self.refreshing = refreshing
  }
  func register(_ routes: any RoutesBuilder) {
    routes.get { request async throws -> Response in
      let query = URLComponents(string: request.url.string)?.queryItems ?? []
      guard query.count <= 1, query.allSatisfy({ $0.name == "after" && $0.value != nil }) else {
        throw ExecutionError.invalidCommand
      }
      let accounts = try await store.listAccounts(after: query.first?.value)
      return try Self.response(
        .object([
          "accounts": .array(accounts.map(Self.metadata)),
          "nextCursor": accounts.count == 64 ? .string(accounts.last!.id) : .null,
        ]))
    }
    routes.put(":id") { request async throws -> Response in
      let document = try Self.body(request, allowed: ["revision", "mode"])
      guard let revision = document["revision"]?.integer,
        let raw = document["mode"]?.string, let mode = AccountMode(rawValue: raw)
      else { throw ExecutionError.invalidCommand }
      let account = try await store.setAccountMode(
        id: request.parameters.get("id") ?? "", revision: revision, mode: mode)
      return try Self.response(.object(["account": Self.metadata(account)]))
    }
    routes.post(":id", "refresh") { request async throws -> Response in
      let document = try Self.body(request, allowed: ["revision"])
      guard let revision = document["revision"]?.integer else {
        throw ExecutionError.invalidCommand
      }
      let account = try await refreshing.refreshAccount(
        id: request.parameters.get("id") ?? "", revision: revision)
      return try Self.response(.object(["account": Self.metadata(account)]))
    }
    routes.post("authorization") { request async throws -> Response in
      guard let owner = request.storage[AdminOwnerKey.self] else {
        throw ExecutionError.unauthorized
      }
      let document = try Self.body(request, allowed: ["target"])
      let target: AccountAuthorizationTarget
      if document["target"] == .null {
        target = .create
      } else {
        guard let object = document["target"]?.object, Set(object.keys) == ["id", "revision"],
          let id = object["id"]?.string, let revision = object["revision"]?.integer
        else { throw ExecutionError.invalidCommand }
        target = .reauthorize(id: id, revision: revision)
      }
      let started = try await authorization.begin(owner: owner, target: target)
      return try Self.response(
        .object([
          "flowID": .string(started.flowID), "authorizationURL": .string(started.authorizationURL),
          "expiresInSeconds": .number(Decimal(started.expiresInSeconds)),
        ]))
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
      return try Self.response(.object(["account": Self.metadata(account)]))
    }
    routes.delete("authorization", ":flowID") { request async throws -> Response in
      guard let owner = request.storage[AdminOwnerKey.self] else {
        throw ExecutionError.unauthorized
      }
      await authorization.discard(owner: owner, flowID: request.parameters.get("flowID") ?? "")
      return try Self.response(.object(["discarded": .bool(true)]))
    }
  }
  private static func metadata(_ account: ManagedAccount) -> JSONValue {
    .object([
      "id": .string(account.id), "revision": .number(Decimal(account.revision)),
      "credentialVersion": .number(Decimal(account.credentialVersion)),
      "mode": .string(account.mode.rawValue),
      "authorization": .string(account.authorization.rawValue),
      "createdAtUnixSeconds": .number(Decimal(account.createdAtUnixSeconds)),
    ])
  }
  private static func body(_ request: Request, allowed: Set<String>) throws -> JSONValue {
    guard request.headers["content-type"].count == 1,
      request.headers.first(name: "content-type")?.lowercased().split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces) == "application/json",
      request.headers["content-encoding"].isEmpty,
      let buffer = request.body.data
    else { throw ExecutionError.invalidCommand }
    let document = try JSONValue.decode(Data(buffer.readableBytesView))
    guard let object = document.object, Set(object.keys) == allowed else {
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
