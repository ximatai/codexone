import CodexOneCore
import Crypto
import Dispatch
import Foundation

/// One active AES-256-GCM key and bounded decrypt-only keys, injected outside the database.
public struct AccountCredentialCipher: AccountCredentialProtection, Sendable,
  CustomStringConvertible,
  CustomDebugStringConvertible
{
  private let keys: [String: SymmetricKey]
  public var availableKeyIDs: [String] { keys.keys.sorted() }
  public let keyID: String
  public var description: String { "AccountCredentialCipher(redacted)" }
  public var debugDescription: String { description }
  private static let maximumEnvelopeBytes = 49_152

  public static func load(
    path: String, adminCredentialPath: String? = nil, forbiddenDigest: String? = nil
  ) async throws -> Self {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let data = try readPrivateData(path, maximum: 8192)
          guard let raw = String(data: data, encoding: .utf8) else {
            throw ExecutionError.invalidCommand
          }
          let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          let active: String
          let old: [String]
          if text.hasPrefix("{") {
            struct Keyring: Decodable {
              let format: Int
              let active: String
              let decryptOnly: [String]
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["format", "active", "decryptOnly"]
            else { throw ExecutionError.invalidCommand }
            let ring = try JSONDecoder().decode(Keyring.self, from: data)
            guard ring.format == 1 else { throw ExecutionError.invalidCommand }
            active = ring.active
            old = ring.decryptOnly
          } else {
            active = text
            old = []
          }
          let materials = [active] + old
          let admin = try adminCredentialPath.map { try readRuntimeSecret($0) }
          guard admin?.lowercased() != text.lowercased() else {
            throw ExecutionError.invalidCommand
          }
          for material in materials {
            guard admin?.lowercased() != material.lowercased(),
              ![material, material.lowercased(), material.uppercased()].contains(where: {
                keyDigest($0) == forbiddenDigest
              })
            else { throw ExecutionError.invalidCommand }
          }
          continuation.resume(returning: try Self(activeHexKey: active, decryptOnlyHexKeys: old))
        } catch {
          continuation.resume(throwing: ExecutionError.invalidCommand)
        }
      }
    }
  }
  // Internal construction is reserved for synthetic tests. Runtime uses the private file loader.
  init(hexKey: String) throws { try self.init(activeHexKey: hexKey, decryptOnlyHexKeys: []) }
  init(activeHexKey: String, decryptOnlyHexKeys: [String]) throws {
    guard decryptOnlyHexKeys.count <= 7 else { throw ExecutionError.capacity }
    let active = try Self.material(activeHexKey)
    var result = [active.0: active.1]
    for hex in decryptOnlyHexKeys {
      let item = try Self.material(hex)
      guard result[item.0] == nil else { throw ExecutionError.invalidCommand }
      result[item.0] = item.1
    }
    keyID = active.0
    keys = result
  }
  private static func material(_ hexKey: String) throws -> (String, SymmetricKey) {
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
    return (
      SHA256.hash(data: material).prefix(16).map { String(format: "%02x", $0) }.joined(),
      SymmetricKey(data: material)
    )
  }
  public func seal(_ credential: AccountCredential, context: AccountCredentialContext) throws
    -> String
  {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      let plaintext = try encoder.encode(Payload(credential))
      guard plaintext.count <= 33_000 else { throw ExecutionError.invalidCommand }
      let box = try AES.GCM.seal(
        plaintext, using: keys[keyID]!, authenticating: aad(context, keyID: keyID))
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
      guard parts.count == 3, parts[0] == "v1", let key = keys[String(parts[1])],
        let combined = Data(base64Encoded: String(parts[2])), combined.count >= 28,
        combined.base64EncodedString() == parts[2]
      else { throw ExecutionError.invalidCommand }
      let box = try AES.GCM.SealedBox(combined: combined)
      let plaintext = try AES.GCM.open(
        box, using: key, authenticating: aad(context, keyID: String(parts[1])))
      guard plaintext.count <= 33_000 else { throw ExecutionError.invalidCommand }
      let decoded = try JSONDecoder().decode(Payload.self, from: plaintext)
      return try AccountCredential(
        accessToken: decoded.accessToken, refreshToken: decoded.refreshToken,
        idToken: decoded.idToken, expiresAtUnixSeconds: decoded.expiresAtUnixSeconds)
    } catch { throw ExecutionError.invalidCommand }
  }
  static func envelopeKeyID(_ envelope: String) throws -> String {
    guard envelope.utf8.count <= maximumEnvelopeBytes else { throw ExecutionError.invalidCommand }
    let parts = envelope.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "v1", parts[1].utf8.count == 32,
      parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw ExecutionError.invalidCommand }
    return String(parts[1])
  }
  private func aad(_ context: AccountCredentialContext, keyID: String) throws -> Data {
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
