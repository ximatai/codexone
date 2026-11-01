/// Ephemeral provider material, never a management DTO or a persistence value.
public struct AccountDeviceCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let deviceAuthID: String
  public let userCode: String
  public let verificationURL: String
  public let intervalSeconds: Int
  public let expiresInSeconds: Int
  public var description: String { "AccountDeviceCode(redacted)" }
  public var debugDescription: String { description }
  public init(
    deviceAuthID: String, userCode: String, verificationURL: String, intervalSeconds: Int,
    expiresInSeconds: Int = 900
  ) {
    self.deviceAuthID = deviceAuthID
    self.userCode = userCode
    self.verificationURL = verificationURL
    self.intervalSeconds = min(30, max(3, intervalSeconds))
    self.expiresInSeconds = min(900, max(1, expiresInSeconds))
  }
}
public struct AccountDeviceGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let code: String
  public let verifier: String
  public var description: String { "AccountDeviceGrant(redacted)" }
  public var debugDescription: String { description }
  public init(code: String, verifier: String) {
    self.code = code
    self.verifier = verifier
  }
}
public enum AccountDeviceAuthorizationError: Error, Sendable {
  case unavailable
}
public enum AccountAuthorizationMethod: String, Sendable, Encodable {
  case device, callback
}
public struct AccountAuthorizationStatus: Sendable, Encodable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public enum State: String, Sendable, Encodable { case pending, completed, failed, expired }
  public let status: State
  public let expiresInSeconds: Int
  public let userCode: String?
  public let accountID: String?
  public let failureCode: String?
  public var description: String { "AccountAuthorizationStatus(redacted)" }
  public var debugDescription: String { description }
  public init(
    status: State, expiresInSeconds: Int, userCode: String? = nil, accountID: String? = nil,
    failureCode: String? = nil
  ) {
    self.status = status
    self.expiresInSeconds = expiresInSeconds
    self.userCode = userCode
    self.accountID = accountID
    self.failureCode = failureCode
  }
}
