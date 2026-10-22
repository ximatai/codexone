import CodexOneCore
import Crypto
import Dispatch
import Foundation

/// One versioned AES-256-GCM master key, injected separately from the core database.
public struct AccountCredentialCipher: AccountCredentialProtection, Sendable,
  CustomStringConvertible,
  CustomDebugStringConvertible
{
  private let key: SymmetricKey
  public let keyID: String
  public var description: String { "AccountCredentialCipher(redacted)" }
  public var debugDescription: String { description }
  private static let maximumEnvelopeBytes = 49_152

  public static func load(path: String) async throws -> Self {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do { continuation.resume(returning: try Self(hexKey: readRuntimeSecret(path))) } catch {
          continuation.resume(throwing: ExecutionError.invalidCommand)
        }
      }
    }
  }
  // Internal construction is reserved for synthetic tests. Runtime uses the private file loader.
  init(hexKey: String) throws {
    let bytes = Array(hexKey.utf8)
    guard bytes.count == 64 else { throw ExecutionError.invalidCommand }
    func nibble(_ value: UInt8) throws -> UInt8 {
      switch value {
      case 48...57: return value - 48
      case 97...102: return value - 97 + 10
      case 65...70: return value - 65 + 10
      default: throw ExecutionError.invalidCommand
      }
    }
    var material = Data()
    for index in stride(from: 0, to: bytes.count, by: 2) {
      try material.append((nibble(bytes[index]) << 4) | nibble(bytes[index + 1]))
    }
    key = SymmetricKey(data: material)
    keyID = SHA256.hash(data: material).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
  public func seal(_ credential: AccountCredential, context: AccountCredentialContext) throws
    -> String
  {
    do {
      let plaintext = try JSONEncoder().encode(Payload(credential))
      guard plaintext.count <= 33_000 else { throw ExecutionError.invalidCommand }
      let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad(context))
      guard let combined = box.combined else { throw ExecutionError.invalidCommand }
      let envelope = "v1." + keyID + "." + combined.base64EncodedString()
      guard envelope.utf8.count <= Self.maximumEnvelopeBytes else {
        throw ExecutionError.invalidCommand
      }
      return envelope
    } catch { throw ExecutionError.invalidCommand }
  }
  public func open(_ envelope: String, context: AccountCredentialContext) throws
    -> AccountCredential
  {
    do {
      guard envelope.utf8.count <= Self.maximumEnvelopeBytes else {
        throw ExecutionError.invalidCommand
      }
      let parts = envelope.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0] == "v1", parts[1] == keyID,
        let combined = Data(base64Encoded: String(parts[2])), combined.count >= 28,
        combined.base64EncodedString() == parts[2]
      else { throw ExecutionError.invalidCommand }
      let box = try AES.GCM.SealedBox(combined: combined)
      let plaintext = try AES.GCM.open(box, using: key, authenticating: aad(context))
      guard plaintext.count <= 33_000 else { throw ExecutionError.invalidCommand }
      let decoded = try JSONDecoder().decode(Payload.self, from: plaintext)
      return try AccountCredential(
        accessToken: decoded.accessToken, refreshToken: decoded.refreshToken,
        idToken: decoded.idToken, expiresAtUnixSeconds: decoded.expiresAtUnixSeconds)
    } catch { throw ExecutionError.invalidCommand }
  }
  private func aad(_ context: AccountCredentialContext) throws -> Data {
    try JSONEncoder().encode([
      "codexone.account-credential", "1", keyID, context.identity, context.namespace,
      String(context.version),
    ])
  }
  private struct Payload: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresAtUnixSeconds: Int64
    init(_ value: AccountCredential) {
      accessToken = value.accessToken
      refreshToken = value.refreshToken
      idToken = value.idToken
      expiresAtUnixSeconds = value.expiresAtUnixSeconds
    }
  }
}
