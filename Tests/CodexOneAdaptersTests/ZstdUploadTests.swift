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

@Test func httpUploadDiscardInvalidatesAnIteratorBeforeReturningIngressCapacity() async throws {
  let size = 65_537
  let budget = RequestBodyBudget(capacity: size, headroomCapacity: 0)
  let lease = budget.lease()
  try lease.reserve(size)
  let payload = HTTPUploadPayload(data: Data(count: size), lease: lease)
  payload.useFinalEncoding()
  var iterator = UploadBody(
    payload: payload, progress: ExecutionProgress(try ExecutionBudget()),
    upload: RequestUpload(bytes: size, transport: "http")
  ).makeAsyncIterator()
  _ = try #require(try await iterator.next())
  await #expect(throws: CancellationError.self) {
    payload.discard()
    try await iterator.next()
  }
  #expect(budget.occupiedBytes == size)
  lease.release()
  #expect(budget.occupiedBytes == 0)
}

@Test(arguments: [true, false])
func zstdReservationLastsThroughTransportEOFAndEncodingNegotiation(earlyAcceptance: Bool)
  async throws
{
  let size = 9 * 1024 * 1024
  let budget = RequestBodyBudget(capacity: size)
  let lease = budget.lease()
  try lease.reserve(size)
  let waiting = budget.lease()
  let ticket = try #require(try waiting.beginWaiting(size))
  defer { budget.cancelWait(ticket) }
  let payload = HTTPUploadPayload(data: Data(repeating: 65, count: size), lease: lease)
  let progress = ExecutionProgress(try ExecutionBudget())
  let pool = ZstdUploadPool()
  #expect(pool.reserve())
  let owner = ZstdUpload(
    payload: payload, pool: pool, progress: progress,
    upload: RequestUpload(bytes: size, transport: "http", encoding: "zstd"))
  if earlyAcceptance { payload.useFinalEncoding() }
  var chunks = 0
  while try await owner.next() != nil {
    chunks += 1
    // Even the final frame bytes must be consumed before EOF releases the workspace.
    #expect(pool.active == 1)
    #expect(!waiting.reserveIfReady(size, ticket: ticket))
  }
  #expect(chunks > 0)
  #expect(pool.active == 0)
  await owner.close()
  #expect(pool.active == 0)
  if !earlyAcceptance {
    #expect(!waiting.reserveIfReady(size, ticket: ticket))
    payload.retryPlaintext()
    var retry = UploadBody(
      payload: payload, progress: progress,
      upload: RequestUpload(bytes: size, transport: "http")
    ).makeAsyncIterator()
    _ = try #require(try await retry.next())
    #expect(!waiting.reserveIfReady(size, ticket: ticket))
    while try await retry.next() != nil {}
  }
  #expect(waiting.reserveIfReady(size, ticket: ticket))
  try await pool.shutdown()
}

@Test func stagedResponsesRetryReplaysThePreparedBytesAndReturnsTheLease() async throws {
  try await withStagingTestDirectory { directory in
    let input = Data(#"{"model":"synthetic-host","input":"hello"}"#.utf8)
    let expected = Data(
      #"{"model":"synthetic-host","input":[{"role":"user","content":"hello"}],"store":false,"stream":true}"#
        .utf8)
    let capacity = EncryptedHTTPBody.diskBytes(expected.count)
    let staging = HTTPBodyStaging(directory: directory.path, capacity: capacity)
    let incoming = try await staging.begin(length: input.count)
    defer { incoming.discard() }
    try await incoming.append(input)
    let request = try await ResponseRequest(data: incoming.decodeInput())
    let document = try request.preparedDocument(
      contract: .codexSubscription, nativeWebSocket: false)
    let payload = try await staging.encode(PendingHTTPBody(document), lease: incoming.lease)
    defer { payload.discard() }
    let pool = ZstdUploadPool()
    #expect(pool.reserve())
    let progress = ExecutionProgress(try ExecutionBudget())
    let first = ZstdUpload(
      payload: payload, pool: pool, progress: progress,
      upload: RequestUpload(bytes: payload.count, transport: "http", encoding: "zstd"))
    var compressed = Data()
    while let chunk = try await first.next() {
      compressed.append(contentsOf: chunk.readableBytesView)
    }
    var restored = Data(count: expected.count)
    let count = restored.withUnsafeMutableBytes { destination in
      compressed.withUnsafeBytes { source in
        ZSTD_decompress(
          destination.baseAddress, destination.count, source.baseAddress, source.count)
      }
    }
    #expect(count == expected.count && restored == expected)
    await #expect(throws: GatewayProtocolError.self) {
      try await staging.begin(length: input.count)
    }
    // A 415 selects one plaintext retry in the existing HTTP execution path.
    payload.retryPlaintext()
    var replay = UploadBody(
      payload: payload, progress: progress,
      upload: RequestUpload(bytes: payload.count, transport: "http")
    ).makeAsyncIterator()
    var replayed = Data()
    while let chunk = try await replay.next() {
      replayed.append(contentsOf: chunk.readableBytesView)
    }
    #expect(replayed == expected)
    let next = try await staging.begin(length: input.count)
    next.discard()
    #expect(throws: CancellationError.self) { try payload.chunk(at: 0) }
    try await pool.shutdown()
    try await staging.workers.shutdownGracefully()
  }
}
