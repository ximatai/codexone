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
  /// Error type/case name only (see `safeCause`), never a message, payload or credential.
  public let cause: String?
  public init(_ code: Code, providerStatus: Int? = nil, cause: String? = nil) {
    self.code = code
    self.providerStatus = providerStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    self.cause = cause.map { String($0.prefix(80)) }
  }
  /// Bounded diagnostic name for an underlying error: its type, plus the case for payload-free enums.
  public static func safeCause(_ error: any Error) -> String {
    let type = String(describing: Swift.type(of: error))
    let mirror = Mirror(reflecting: error)
    guard mirror.displayStyle == .enum, mirror.children.isEmpty else { return String(type.prefix(80)) }
    return String((type + "." + String(describing: error)).prefix(80))
  }
}
