import Foundation
import NIOCore
import Testing
import libzstd

@testable import CodexOneAdapters

@Test func zstdBoundedStepsPreserveBytesAndFrameParameters() throws {
  for size in [0, 1, 65_535, 65_536, 65_537, 1_048_576] {
    var seed: UInt64 = 123_456_789
    let data = Data(
      (0..<size).map { _ -> UInt8 in
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return UInt8(truncatingIfNeeded: seed)
      })
    let encoder = ZstdEncoder()
    var compressed = Data()
    var complete = false
    var steps = 0
    while !complete {
      let (buffer, ended) = try encoder.step(data)
      if let buffer {
        #expect(buffer.readableBytes <= 65_536)
        compressed.append(contentsOf: buffer.readableBytesView)
      }
      complete = ended
      steps += 1
      #expect(steps < 100)
    }
    #expect(compressed.prefix(4) == Data([0x28, 0xb5, 0x2f, 0xfd]))
    // Frame content size absent, checksum absent, dictionary absent.
    #expect(compressed[4] & 0xc7 == 0)
    var restored = Data(count: max(1, size))
    let count = restored.withUnsafeMutableBytes { output in
      compressed.withUnsafeBytes { input in
        ZSTD_decompress(output.baseAddress, output.count, input.baseAddress, input.count)
      }
    }
    #expect(ZSTD_isError(count) == 0)
    #expect(count == size)
    #expect(restored.prefix(size) == data)
    encoder.close()
    encoder.close()
  }
}

@Test func zstdCapacityCancellationAndCloseAreOwned() async throws {
  let pool = ZstdUploadPool()
  for _ in 0..<4 { #expect(pool.reserve()) }
  #expect(!pool.reserve())
  for _ in 0..<4 { pool.release() }
  for _ in 0..<20 {
    #expect(pool.reserve())
    let owner = ZstdUpload(
      data: Data(repeating: 65, count: 1024 * 1024), pool: pool,
      progress: ExecutionProgress(try ExecutionBudget()),
      upload: RequestUpload(bytes: 1024 * 1024, transport: "http", encoding: "zstd"))
    let pull = Task { try await owner.next() }
    async let first: Void = owner.close()
    async let second: Void = owner.close()
    _ = await (first, second)
    _ = try? await pull.value
    #expect(pool.active == 0)
    await #expect(throws: CancellationError.self) { try await owner.next() }
  }
  try await pool.shutdown()
  #expect(!pool.reserve())
  let encoder = ZstdEncoder()
  encoder.cancel()
  #expect(throws: CancellationError.self) { try encoder.step(Data()) }
}

@Test func zstdWorkerFailureAndCancellationReturnReservation() async throws {
  let pool = ZstdUploadPool()
  #expect(pool.reserve())
  let owner = ZstdUpload(
    data: Data(repeating: 65, count: 65_537), pool: pool,
    progress: ExecutionProgress(try ExecutionBudget()),
    upload: RequestUpload(bytes: 65_537, transport: "http", encoding: "zstd"))
  // Pool rejection exercises the job-error path, including close after next throws.
  try await pool.shutdown()
  await #expect(throws: (any Error).self) { try await owner.next() }
  await owner.close()
  #expect(pool.active == 0)
}

@Test func zstdReservationLastsUntilTransportPullsEOF() async throws {
  let pool = ZstdUploadPool()
  #expect(pool.reserve())
  let owner = ZstdUpload(
    data: Data(repeating: 65, count: 65_537), pool: pool,
    progress: ExecutionProgress(try ExecutionBudget()),
    upload: RequestUpload(bytes: 65_537, transport: "http", encoding: "zstd"))
  var chunks = 0
  while try await owner.next() != nil {
    chunks += 1
    // Even the final frame bytes must be consumed before EOF releases the workspace.
    #expect(pool.active == 1)
  }
  #expect(chunks > 0)
  #expect(pool.active == 0)
  await owner.close()
  #expect(pool.active == 0)
  try await pool.shutdown()
}
