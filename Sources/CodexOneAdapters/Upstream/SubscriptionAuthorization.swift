import CodexOneCore

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
