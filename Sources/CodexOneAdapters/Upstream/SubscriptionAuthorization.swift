import CodexOneCore
import Crypto
import Foundation

extension SubscriptionOAuthProvider: AccountAuthorizationProvider {
  public func authorize(code: String, verifier: String, expectedNonce: String) async throws
    -> VerifiedAccountAuthorization
  {
    let verified = try await exchangeAuthorizationCode(
      code: code, verifier: verifier, expectedNonce: expectedNonce)
    return VerifiedAccountAuthorization(
      namespace: verified.namespace, credential: verified.credential)
  }
}

extension SubscriptionOAuthProvider {
  public func requestDeviceCode() async throws -> AccountDeviceCode {
    let response = try await post(
      ["client_id": Self.clientID], path: "/api/accounts/deviceauth/usercode", device: true)
    let deviceID = try requiredString(response, "device_auth_id")
    let userCode = try requiredString(response, "user_code")
    guard deviceID.utf8.count <= 4096, userCode.utf8.count <= 128,
      deviceID.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
      userCode.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
      let interval = response["interval"]?.string, let seconds = Int(interval), seconds > 0
    else { throw AccountRefreshError.unavailable }
    var expiry = 900
    if let value = response["expires_in"] {
      guard let seconds = value.integer, seconds > 0, seconds <= 1_000_000 else {
        throw AccountRefreshError.unavailable
      }
      expiry = min(900, Int(seconds))
    }
    return AccountDeviceCode(
      deviceAuthID: deviceID, userCode: userCode, verificationURL: realm + "/codex/device",
      intervalSeconds: seconds, expiresInSeconds: expiry)
  }
  public func pollDeviceCode(_ device: AccountDeviceCode) async throws -> AccountDeviceGrant? {
    let response = try await post(
      ["device_auth_id": device.deviceAuthID, "user_code": device.userCode],
      path: "/api/accounts/deviceauth/token", device: true)
    if response == .null { return nil }
    let code = try requiredString(response, "authorization_code")
    let verifier = try requiredString(response, "code_verifier")
    let challenge = try requiredString(response, "code_challenge")
    guard code.utf8.count <= 4096, code.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
      Self.unreserved(verifier, minimum: 43, maximum: 128),
      challenge == Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    else { throw AccountRefreshError.unavailable }
    return AccountDeviceGrant(code: code, verifier: verifier)
  }
  public func authorizeDevice(_ grant: AccountDeviceGrant) async throws
    -> VerifiedAccountAuthorization
  {
    let response = try await post(
      [
        "grant_type": "authorization_code", "client_id": Self.clientID, "code": grant.code,
        "code_verifier": grant.verifier, "redirect_uri": realm + "/deviceauth/callback",
      ], form: true)
    // No locally generated nonce exists in this flow. Trust remains the fixed endpoint's direct response.
    let verified = try verifyLogin(response, nonce: nil)
    return VerifiedAccountAuthorization(
      namespace: verified.namespace, credential: verified.credential)
  }
}
