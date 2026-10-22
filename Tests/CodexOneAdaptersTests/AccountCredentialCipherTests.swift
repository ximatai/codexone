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
  let admin = root.appendingPathComponent("admin")
  try Data(syntheticMaster.uppercased().utf8).write(to: admin)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: admin.path)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(path: file.path, adminCredentialPath: admin.path)
  }
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(
      path: file.path, forbiddenDigest: keyDigest(syntheticMaster))
  }
  try Data("independent-synthetic-administrator-secret".utf8).write(to: admin)
  _ = try await AccountCredentialCipher.load(path: file.path, adminCredentialPath: admin.path)

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

@Test func keyringWritesOnlyActiveAndOpensLegacyWithOriginalAAD() throws {
  let old = try AccountCredentialCipher(hexKey: String(repeating: "2a", count: 32))
  let ring = try AccountCredentialCipher(
    activeHexKey: String(repeating: "3b", count: 32),
    decryptOnlyHexKeys: [String(repeating: "2a", count: 32)])
  let context = try AccountCredentialContext(
    identity: "synthetic", namespace: "synthetic/keyring", version: 2)
  let credential = try AccountCredential(
    accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
    expiresAtUnixSeconds: 2_000_000_000)
  let legacy = try old.seal(credential, context: context)
  #expect(try ring.open(legacy, context: context).accessToken == credential.accessToken)
  let fresh = try ring.seal(credential, context: context)
  #expect(try AccountCredentialCipher.envelopeKeyID(fresh) == ring.keyID)
  #expect(throws: ExecutionError.invalidCommand) { try old.open(fresh, context: context) }
  #expect(throws: ExecutionError.invalidCommand) {
    try ring.open(
      legacy, context: .init(identity: "other", namespace: context.namespace, version: 2))
  }
  #expect(throws: ExecutionError.invalidCommand) {
    try AccountCredentialCipher(
      activeHexKey: String(repeating: "2A", count: 32),
      decryptOnlyHexKeys: [String(repeating: "2a", count: 32)])
  }
}

@Test func privateKeyringRejectsUnknownFieldsReusedOldKeysAndUnsafeAliases() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("ring")
  let admin = root.appendingPathComponent("admin")
  let active = String(repeating: "4c", count: 32)
  let old = String(repeating: "5d", count: 32)
  func write(_ object: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  try write(["format": 1, "active": active, "decryptOnly": [old]])
  let ring = try await AccountCredentialCipher.load(path: file.path)
  #expect(ring.availableKeyIDs.count == 2)
  let entireKeyring = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(
    in: .whitespacesAndNewlines)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(
      path: file.path, forbiddenDigest: keyDigest(entireKeyring))
  }
  try old.uppercased().write(to: admin, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: admin.path)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(path: file.path, adminCredentialPath: admin.path)
  }
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(
      path: file.path, forbiddenDigest: keyDigest(old.uppercased()))
  }
  try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("alias"))
  await #expect(throws: ExecutionError.invalidCommand) {
    try await AccountCredentialCipher.load(path: file.path)
  }
  try FileManager.default.removeItem(at: root.appendingPathComponent("alias"))
  for object: [String: Any] in [
    ["format": 1, "active": active, "decryptOnly": [old], "extra": true],
    ["format": 2, "active": active, "decryptOnly": [old]],
    ["format": 1, "active": active, "decryptOnly": Array(repeating: old, count: 8)],
    ["format": 1, "active": active, "decryptOnly": [active.uppercased()]],
  ] {
    try write(object)
    await #expect(throws: ExecutionError.invalidCommand) {
      try await AccountCredentialCipher.load(path: file.path)
    }
  }
}
