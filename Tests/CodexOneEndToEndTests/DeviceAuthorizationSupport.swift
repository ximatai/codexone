import CodexOneCore
import CodexOneRuntime
import Crypto
import Foundation
import NIOCore
import Synchronization
import Testing

@testable import CodexOneAdapters

let deviceCreate = "/api/accounts/deviceauth/usercode"
let devicePoll = "/api/accounts/deviceauth/token"
let deviceCode = Data(
  #"{"device_auth_id":"synthetic-device-id-private","user_code":"SYNTH-CODE","interval":"1"}"#.utf8)
func deviceGrant() throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "authorization_code": "synthetic-code+/=", "code_verifier": oauthVerifier,
    "code_challenge": SubscriptionOAuthProvider.base64URL(
      Data(SHA256.hash(data: Data(oauthVerifier.utf8)))),
  ])
}
/// Pulses replace elapsed polling intervals; cancellation terminates an outstanding next().
final class DevicePollGate: Sendable {
  private struct State {
    var tokens = 0
    var waiting: [(UUID, AsyncStream<Void>.Continuation)] = []
  }
  private let state = Mutex(State())
  func pulse() {
    state.withLock { value in
      while !value.waiting.isEmpty {
        let signal = value.waiting.removeFirst().1
        let result = signal.yield(())
        signal.finish()
        if case .enqueued = result { return }
      }
      value.tokens += 1
    }
  }
  func wait(_ duration: Duration) async throws {
    #expect(duration >= .seconds(3) && duration <= .seconds(30))
    let id = UUID()
    let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    state.withLock { value in
      if value.tokens > 0 {
        value.tokens -= 1
        channel.continuation.yield(())
        channel.continuation.finish()
      } else {
        value.waiting.append((id, channel.continuation))
      }
    }
    defer { state.withLock { $0.waiting.removeAll { $0.0 == id } } }
    var iterator = channel.stream.makeAsyncIterator()
    guard await iterator.next() != nil else { throw CancellationError() }
    try Task.checkCancellation()
  }
}
func prepareDevice(_ h: OAuthHarness, create: OAuthPlan? = nil, poll: OAuthPlan? = nil)
  throws
{
  let grant = try deviceGrant()
  h.server.state.mutex.withLock {
    $0.devicePlans = [
      deviceCreate: create ?? .reply(deviceCode), devicePoll: poll ?? .reply(grant),
    ]
    $0.deviceRedirect = true
  }
  h.server.set(.reply(try oauthTokens(nonce: "device-has-no-local-nonce")))
}
func calls(_ h: OAuthHarness, _ path: String) -> Int {
  h.server.state.mutex.withLock { $0.paths[path, default: 0] }
}
func noDeviceMaterialInDatabase(_ h: OAuthHarness) throws {
  for url in try FileManager.default.contentsOfDirectory(
    at: h.root, includingPropertiesForKeys: nil)
  where url.lastPathComponent.hasPrefix("core.sqlite") {
    let bytes = try Data(contentsOf: url)
    for secret in ["SYNTH-CODE", "synthetic-device-id-private"] {
      #expect(bytes.range(of: Data(secret.utf8)) == nil)
    }
  }
}

func awaitDevice(_ condition: @Sendable () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while ContinuousClock.now < deadline {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Synthetic device flow did not converge within its elapsed-time budget")
  throw AccountRefreshError.unavailable
}
