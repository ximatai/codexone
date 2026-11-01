import CodexOneCore
import CodexOneRuntime
import Crypto
import Foundation
import NIOCore
import Synchronization
import Testing

@testable import CodexOneAdapters

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test(.timeLimit(.minutes(1))) func deviceSocketAdminAPIDefaultMethodStatusAndCancellationGuards()
  async throws
{
  try await withOAuth { h in
    try prepareDevice(h, poll: .headersStall)
    let secret = "synthetic-device-admin-" + String(repeating: "a", count: 32)
    let key = h.root.appendingPathComponent("admin")
    try Data(secret.utf8).write(to: key)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    let keys = try await KeyAdminAPI.load(path: key.path, store: h.store)
    let gate = DevicePollGate()
    let authorization = try AccountAuthorizationSupervisor(
      application: h.app, provider: h.provider, pollWait: gate.wait)
    let accounts = AccountAdminAPI(
      store: h.store, authorization: authorization, refreshing: h.supervisor)
    let port = AccountAdminPort()
    let admin = AdminService(
      group: h.group, port: 0, reportProvider: { .init(checks: []) }, keys: keys,
      accounts: accounts, onBound: { bound in port.value.withLock { $0 = bound } })
    let owner = Task {
      try await GatewayRuntime(services: [authorization, admin]).run(handleSignals: false)
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    do {
      try await awaitDevice { port.value.withLock { $0 > 0 } }
      let client = AccountAdminClient(port: port.value.withLock { $0 }, session: session)
      let bearer = ["authorization": "Bearer " + secret]
      let origin = "http://127.0.0.1:\(client.port)"
      let login = try await client.call(
        "POST", "/api/session",
        body: .object([
          "username": .string("admin"), "secret": .string(secret),
        ]), headers: ["origin": origin])
      let cookie = try #require(login.2?.split(separator: ";").first.map(String.init))
      let csrf = try #require(login.1["csrf"]?.string)
      let browser = ["origin": origin, "cookie": cookie, "x-codexone-csrf": csrf]
      for invalid: JSONValue in [
        .object(["target": .null, "method": .string("other")]),
        .object(["target": .null, "method": .null]),
        .object(["target": .null, "extra": .bool(true)]),
      ] {
        #expect(
          try await client.call(
            "POST", "/api/accounts/authorization", body: invalid, headers: bearer
          ).0 == 400)
      }
      let created = try await client.call(
        "POST", "/api/accounts/authorization", body: .object(["target": .null]), headers: bearer)
      #expect(created.0 == 200 && created.3 == "no-store")
      #expect(
        created.1["method"]?.string == "device" && created.1["userCode"]?.string == "SYNTH-CODE")
      #expect(created.1["device_auth_id"] == nil && created.1["deviceAuthID"] == nil)
      let path = "/api/accounts/authorization/" + (try #require(created.1["flowID"]?.string))
      for method in ["GET", "DELETE"] {
        let denied = try await client.call(method, path, headers: browser)
        #expect(denied.0 == 409 && denied.3 == "no-store")
        #expect(!String(decoding: try denied.1.data(), as: UTF8.self).contains("SYNTH-CODE"))
      }
      let pending = try await client.call("GET", path, headers: bearer)
      #expect(
        pending.0 == 200 && pending.1["status"]?.string == "pending"
          && pending.1["userCode"]?.string == "SYNTH-CODE")
      #expect(try await client.call("GET", path + "?owner=other", headers: bearer).0 == 400)
      gate.pulse()
      try await awaitDevice { calls(h, devicePoll) == 1 }
      #expect(try await client.call("DELETE", path, headers: bearer).0 == 200)
      #expect(h.provider.activeRequests == 0 && calls(h, "/oauth/token") == 0)
      #expect(try await client.call("GET", path, headers: bearer).0 == 409)
      // DELETE must also await an already dispatched exchange, not only the polling POST.
      try prepareDevice(h)
      h.server.set(.headersStall)
      let exchanging = try await client.call(
        "POST", "/api/accounts/authorization", body: .object(["target": .null]), headers: bearer)
      let exchangePath =
        "/api/accounts/authorization/" + (try #require(exchanging.1["flowID"]?.string))
      gate.pulse()
      try await awaitDevice { calls(h, "/oauth/token") == 1 }
      #expect(try await client.call("DELETE", exchangePath, headers: bearer).0 == 200)
      #expect(h.provider.activeRequests == 0 && calls(h, "/oauth/token") == 1)
      #expect(try await h.store.listAccounts(after: nil).isEmpty)
      try prepareDevice(h, poll: .reply(Data("synthetic-private-body".utf8), status: 429))
      let rejected = try await client.call(
        "POST", "/api/accounts/authorization", body: .object(["target": .null]), headers: bearer)
      let rejectedPath =
        "/api/accounts/authorization/" + (try #require(rejected.1["flowID"]?.string))
      gate.pulse()
      try await awaitDevice {
        try await client.call("GET", rejectedPath, headers: bearer).1["status"]?.string == "failed"
      }
      let failed = try await client.call("GET", rejectedPath, headers: bearer)
      #expect(failed.0 == 200 && failed.3 == "no-store")
      #expect(failed.1["status"]?.string == "failed")
      #expect(failed.1["failureCode"]?.string == "provider_rejected")
      #expect(failed.1["providerStatus"] == nil && failed.1["userCode"] == nil)
      #expect(
        !String(decoding: try failed.1.data(), as: UTF8.self).contains("synthetic-private-body"))
      try noDeviceMaterialInDatabase(h)
    } catch {
      owner.cancel()
      _ = await owner.result
      throw error
    }
    owner.cancel()
    try await owner.value
  }
}
