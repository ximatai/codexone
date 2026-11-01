import CodexOneCore
import Crypto
import Foundation
import Testing

@testable import CodexOneAdapters

@Test(.timeLimit(.minutes(1)))
func deviceProviderBoundsCreationAndRetainsTrustedIdentityValidation() async throws {
  let path = "/api/accounts/deviceauth/usercode"
  // The official client sends the interval as a string; a JSON number is accepted too.
  for interval in ["1", "3", "30", "999", " 5 ", 7] as [Any] {
    try await withOAuth { h in
      let data = try JSONSerialization.data(withJSONObject: [
        "device_auth_id": "synthetic-device-id-private", "user_code": "SYNTH-CODE",
        "interval": interval, "expires_in": 1200,
      ])
      h.server.state.mutex.withLock { $0.devicePlans[path] = .reply(data) }
      let device = try await h.provider.requestDeviceCode()
      let seconds =
        (interval as? Int) ?? Int((interval as! String).trimmingCharacters(in: .whitespaces))!
      #expect(device.intervalSeconds == min(30, max(3, seconds)))
      #expect(device.expiresInSeconds == 900)
      #expect(device.verificationURL == "http://127.0.0.1:\(h.server.port)/codex/device")
      #expect(String(reflecting: device) == "AccountDeviceCode(redacted)")
      #expect(h.server.counts.invalid == 0)
    }
  }
  for data in [
    Data(#"{"device_auth_id":"synthetic","user_code":"SYNTH-CODE","interval":"oops"}"#.utf8),
    Data(#"{"device_auth_id":"synthetic","user_code":"SYNTH-CODE","interval":-3}"#.utf8),
    Data(#"{"device_auth_id":"synthetic","user_code":"SYNTH-CODE","interval":"0"}"#.utf8),
    Data(
      #"{"device_auth_id":"synthetic","user_code":"SYNTH-CODE","interval":"3","expires_in":0}"#.utf8
    ),
    Data(#"{"user_code":"SYNTH-CODE","interval":"3"}"#.utf8),
  ] {
    try await withOAuth { h in
      h.server.state.mutex.withLock { $0.devicePlans[path] = .reply(data) }
      await #expect(throws: AccountRefreshError.unavailable) {
        try await h.provider.requestDeviceCode()
      }
      #expect(h.server.counts.calls == 1 && h.provider.activeRequests == 0)
    }
  }
  let invalidTokens = [
    try oauthTokens(idAudience: "synthetic-wrong-client"),
    try oauthTokens(accessAccount: "synthetic-other-account"),
    try oauthTokens(idIssuer: "https://untrusted.example.invalid"),
    try oauthTokens(idExpiry: testUnixSeconds - 1),
    try oauthTokens(includeID: false),
  ]
  for data in invalidTokens {
    try await withOAuth { h in
      h.server.state.mutex.withLock { $0.deviceRedirect = true }
      h.server.set(.reply(data))
      await #expect(throws: (any Error).self) {
        try await h.provider.authorizeDevice(
          .init(code: "synthetic-code+/=", verifier: oauthVerifier))
      }
      #expect(h.server.counts.calls == 1 && h.server.counts.invalid == 0)
    }
  }
}
