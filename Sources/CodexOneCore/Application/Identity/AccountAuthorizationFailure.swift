/// Safe authorization diagnostics. No provider payload or underlying error is retained.
public struct AccountAuthorizationFailure: Error, Sendable, Equatable {
  public enum Code: String, Sendable, CaseIterable {
    case providerRejected = "provider_rejected"
    case exchangeFailed = "exchange_failed"
    case identityMismatch = "identity_mismatch"
    case verificationFailed = "verification_failed"
    case revisionConflict = "revision_conflict"
    case deviceCodeUnavailable = "device_code_unavailable"
    case authorizationFailed = "authorization_failed"
  }
  public let code: Code
  /// Numeric HTTP evidence only, without importing a transport type into Core.
  public let providerStatus: Int?
  public init(_ code: Code, providerStatus: Int? = nil) {
    self.code = code
    self.providerStatus = providerStatus.flatMap { (100...599).contains($0) ? $0 : nil }
  }
}
