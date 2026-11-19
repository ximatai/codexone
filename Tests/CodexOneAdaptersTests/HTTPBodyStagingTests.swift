import Foundation
import Testing

@testable import CodexOneAdapters

func withStagingTestDirectory(_ operation: (URL) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try await operation(directory)
}

@Test func encryptedStagingRejectsIncompleteBodiesAndReturnsCapacity() async throws {
  try await withStagingTestDirectory { directory in
    let size = EncryptedHTTPBody.block + 19
    let bytes = Data(repeating: 65, count: size)
    let staging = HTTPBodyStaging(
      directory: directory.path, capacity: EncryptedHTTPBody.diskBytes(size))
    let partial = try await staging.begin(length: size)
    try await partial.append(Data(bytes.prefix(size - 1)))
    await #expect(throws: GatewayProtocolError.self) { try await staging.begin(length: size) }
    await #expect(throws: GatewayProtocolError.self) { try await partial.decodeInput() }
    partial.discard()
    let whole = try await staging.begin(length: size)
    try await whole.append(Data(bytes.prefix(101)))
    try await whole.append(Data(bytes.dropFirst(101)))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(try await whole.decodeInput() == bytes)
    whole.discard()
    try await staging.workers.shutdownGracefully()
  }
}
