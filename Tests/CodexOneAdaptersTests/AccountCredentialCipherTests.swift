import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private let syntheticMaster = String(repeating: "5a", count: 32)
private func syntheticCredential() throws -> AccountCredential {
  try AccountCredential(
    accessToken: "synthetic-access-token", refreshToken: "synthetic-refresh-token",
    idToken: "synthetic.id.token", expiresAtUnixSeconds: 2_000_000_000)
}
@Test func accountCredentialEnvelopeAuthenticatesIdentityNamespaceAndVersion() throws {
  let cipher = try AccountCredentialCipher(hexKey: syntheticMaster)
  let context = try AccountCredentialContext(
    identity: "i", namespace: "synthetic/account-a", version: 1)
  let credential = try syntheticCredential()
  let first = try cipher.seal(credential, context: context)
  let second = try cipher.seal(credential, context: context)
  #expect(first != second)
  #expect(!first.contains(credential.accessToken) && !first.contains(credential.refreshToken))
  let opened = try cipher.open(first, context: context)
  #expect(opened.accessToken == credential.accessToken)
  #expect(opened.refreshToken == credential.refreshToken)
  #expect(opened.idToken == credential.idToken)
  #expect(opened.expiresAtUnixSeconds == credential.expiresAtUnixSeconds)
  for other in [
    try AccountCredentialContext(identity: "other", namespace: context.namespace, version: 1),
    try AccountCredentialContext(identity: "i", namespace: "synthetic/account-b", version: 1),
    try AccountCredentialContext(identity: "i", namespace: context.namespace, version: 2),
  ] {
    #expect(throws: ExecutionError.invalidCommand) { try cipher.open(first, context: other) }
  }
  let otherKey = try AccountCredentialCipher(hexKey: String(repeating: "3c", count: 32))
  #expect(throws: ExecutionError.invalidCommand) { try otherKey.open(first, context: context) }
  #expect(String(describing: credential) == "AccountCredential(redacted)")
  #expect(String(reflecting: cipher) == "AccountCredentialCipher(redacted)")
}
@Test func accountCredentialEnvelopeRejectsTamperingAndUnboundedOrUnknownFormats() throws {
  let cipher = try AccountCredentialCipher(hexKey: syntheticMaster)
  let context = try AccountCredentialContext(identity: "i", namespace: "synthetic", version: 1)
  let envelope = try cipher.seal(syntheticCredential(), context: context)
  let parts = envelope.split(separator: ".")
  var ciphertext = try #require(Data(base64Encoded: String(parts[2])))
  ciphertext[12] ^= 1
  let tampered = "v1." + cipher.keyID + "." + ciphertext.base64EncodedString()
  for invalid in [
    tampered, envelope.replacingOccurrences(of: "v1.", with: "v2."), envelope + ".extra",
    "v1." + cipher.keyID + ".AAAA", String(repeating: "x", count: 49_153),
  ] {
    #expect(throws: ExecutionError.invalidCommand) { try cipher.open(invalid, context: context) }
  }
  #expect(throws: ExecutionError.invalidCommand) {
    try AccountCredentialCipher(hexKey: "private-invalid-key")
  }
  #expect(throws: ExecutionError.invalidCommand) {
    try AccountCredential(
      accessToken: "invalid token", refreshToken: "synthetic", idToken: nil, expiresAtUnixSeconds: 1
    )
  }
  #expect(throws: ExecutionError.invalidCommand) {
    try AccountCredential(
      accessToken: String(repeating: "a", count: 16_384),
      refreshToken: String(repeating: "b", count: 16_384), idToken: "c", expiresAtUnixSeconds: 1)
  }
  for character in ["a", "/"] {
    let maximum = try AccountCredential(
      accessToken: String(repeating: character, count: 16_384),
      refreshToken: String(repeating: character, count: 16_384), idToken: nil,
      expiresAtUnixSeconds: 1)
    let opened = try cipher.open(cipher.seal(maximum, context: context), context: context)
    #expect(opened.accessToken == maximum.accessToken)
    #expect(opened.refreshToken == maximum.refreshToken)
  }
}
@Test func accountMasterKeyUsesIndependentPrivateFileValidation() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("key")
  try Data(syntheticMaster.utf8).write(to: file)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  let cipher = try await AccountCredentialCipher.load(path: file.path)
  #expect(cipher.keyID.count == 32)
  let link = root.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(path: link.path)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(path: file.path)
  }
}
