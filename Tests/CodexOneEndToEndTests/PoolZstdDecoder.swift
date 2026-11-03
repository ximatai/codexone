import CodexOneCore
import Foundation
import NIOCore
import libzstd

/// Synthetic provider fixture: decode incrementally, never collect compressed input.
final class PoolZstdDecoder {
  private let context: OpaquePointer
  private let output: UnsafeMutableRawPointer
  private(set) var ended = false

  init() throws {
    guard let context = ZSTD_createDStream() else { throw ExecutionError.invalidCommand }
    self.context = context
    guard ZSTD_isError(ZSTD_initDStream(context)) == 0 else {
      ZSTD_freeDStream(context)
      throw ExecutionError.invalidCommand
    }
    output = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 8)
  }
  deinit {
    ZSTD_freeDStream(context)
    output.deallocate()
  }
  func append(_ bytes: ByteBuffer, to body: inout Data) throws {
    guard !ended else { throw ExecutionError.invalidCommand }
    try bytes.withUnsafeReadableBytes { source in
      var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
      while input.pos < input.size {
        var out = ZSTD_outBuffer(dst: output, size: 65_536, pos: 0)
        let result = ZSTD_decompressStream(context, &out, &input)
        guard ZSTD_isError(result) == 0, out.pos <= 32 * 1024 * 1024 - body.count else {
          throw ExecutionError.invalidCommand
        }
        body.append(contentsOf: UnsafeRawBufferPointer(start: output, count: out.pos))
        if result == 0 {
          ended = true
          guard input.pos == input.size else { throw ExecutionError.invalidCommand }
        }
      }
    }
  }
}
