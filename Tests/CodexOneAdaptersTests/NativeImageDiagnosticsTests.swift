import AsyncHTTPClient
import Foundation
import NIOCore
import Synchronization
import Testing

@testable import CodexOneAdapters

struct NativeImageDiagnosticsTests {
  private struct Unknown: Error, CustomStringConvertible {
    var description: String { "synthetic-private-marker" }
  }

  @Test func contentTypeTokensNeverRetainArbitraryValues() {
    #expect(NativeImageDiagnostics.contentTypeToken("Application/JSON; charset=utf-8") == "json")
    #expect(NativeImageDiagnostics.contentTypeToken(nil) == "missing")
    #expect(NativeImageDiagnostics.contentTypeToken("text/event-stream") == "sse")
    #expect(NativeImageDiagnostics.contentTypeToken("synthetic-private-marker") == "other")
    #expect(NativeImageDiagnostics.contentTypeToken(String(repeating: "x", count: 257)) == "other")
  }

  @Test func errorTokensUseTypesAndAllowlistedCasesOnly() {
    let cases: [(any Error, String)] = [
      (HTTPClientError.remoteConnectionClosed, "remoteConnectionClosed"),
      (HTTPClientError.readTimeout, "readTimeout"),
      (HTTPClientError.connectTimeout, "connectTimeout"),
      (HTTPClientError.deadlineExceeded, "deadlineExceeded"),
      (HTTPClientError.cancelled, "cancelled"),
      (CancellationError(), "cancelled"),
      (IOError(errnoCode: 54, reason: "synthetic-private-marker"), "io_errno_54"),
      (IOError(errnoCode: -1, reason: "synthetic-private-marker"), "other"),
      (GatewayProtocolError(502, "execution_indeterminate"), "gateway_execution_indeterminate"),
      (GatewayProtocolError(502, "synthetic-private-marker"), "other"),
      (HTTPClientError.invalidURL, "other"),
      (Unknown(), "other"),
    ]
    for (error, token) in cases {
      #expect(NativeImageDiagnostics.errorToken(error) == token)
    }
    #expect(NativeImageDiagnostics.errorToken(nil) == "none")
  }

  private final class Clock: Sendable {
    let start = ContinuousClock.now
    let offset = Mutex(0)
    func set(_ milliseconds: Int) { offset.withLock { $0 = milliseconds } }
    func now() -> ContinuousClock.Instant {
      start.advanced(by: .milliseconds(offset.withLock { $0 }))
    }
  }

  @Test func fakeBodyCapturesTimesBytesAndLongestGapWithoutChangingCollection() async throws {
    let clock = Clock()
    let diagnostics = NativeImageDiagnostics(streaming: false, now: { clock.now() })
    clock.set(10)
    diagnostics.receivedHeaders(status: 200)
    let index = Mutex(0)
    let stream = AsyncThrowingStream<ByteBuffer, any Error>(unfolding: {
      let next = index.withLock {
        let next = $0
        $0 += 1
        return next
      }
      switch next {
      case 0:
        clock.set(40)
        return ByteBuffer(string: "ab")
      case 1:
        clock.set(90)
        return ByteBuffer(string: "cde")
      case 2:
        clock.set(110)
        return ByteBuffer()
      default:
        clock.set(130)
        return nil
      }
    })
    let body = try await collectProgressBody(
      .stream(stream), progress: ExecutionProgress(try ExecutionBudget()), maximum: 5,
      onChunk: { diagnostics.receivedBody(bytes: $0) })
    #expect(body == Data("abcde".utf8))
    let id = "00000000-0000-4000-8000-000000000001"
    let metadata = diagnostics.metadata(error: nil, requestID: id)
    #expect(metadata["phase"]?.description == "completed")
    #expect(metadata["error_type"]?.description == "none")
    #expect(metadata["transport_stream"]?.description == "false")
    #expect(metadata["headers_ms"]?.description == "10")
    #expect(metadata["first_body_ms"]?.description == "40")
    #expect(metadata["last_body_gap_ms"]?.description == "50")
    #expect(metadata["elapsed_ms"]?.description == "130")
    #expect(metadata["body_bytes"]?.description == "5")
    #expect(metadata["upstream_status"]?.description == "200")
    #expect(metadata["request_id"]?.description == id)
    #expect(metadata.count == 11)
  }

  @Test func midBodyDisconnectRetainsOriginalErrorAndPartialTiming() async throws {
    let clock = Clock()
    let diagnostics = NativeImageDiagnostics(streaming: true, now: { clock.now() })
    clock.set(10)
    diagnostics.receivedHeaders(status: 200)
    let first = Mutex(true)
    let stream = AsyncThrowingStream<ByteBuffer, any Error>(unfolding: {
      if first.withLock({
        let result = $0
        $0 = false
        return result
      }) {
        clock.set(45)
        return ByteBuffer(string: "synthetic")
      }
      clock.set(80)
      throw HTTPClientError.remoteConnectionClosed
    })
    do {
      _ = try await collectProgressBody(
        .stream(stream), progress: ExecutionProgress(try ExecutionBudget()), maximum: 100,
        onChunk: { diagnostics.receivedBody(bytes: $0) })
      Issue.record("Expected disconnect")
    } catch {
      #expect(error as? HTTPClientError == .remoteConnectionClosed)
      let metadata = diagnostics.metadata(error: error, requestID: "synthetic-private-marker")
      #expect(metadata["phase"]?.description == "in_body")
      #expect(metadata["error_type"]?.description == "remoteConnectionClosed")
      #expect(metadata["first_body_ms"]?.description == "45")
      #expect(metadata["last_body_gap_ms"]?.description == "35")
      #expect(metadata["elapsed_ms"]?.description == "80")
      #expect(metadata["body_bytes"]?.description == "9")
      #expect(metadata["request_id"] == nil)
    }
  }

  @Test func beforeHeadersDisconnectOmitsUnknownTimesAndStatus() {
    let clock = Clock()
    let diagnostics = NativeImageDiagnostics(streaming: false, now: { clock.now() })
    clock.set(25)
    let metadata = diagnostics.metadata(
      error: HTTPClientError.remoteConnectionClosed, requestID: "untrusted")
    #expect(metadata["phase"]?.description == "before_headers")
    #expect(metadata["error_type"]?.description == "remoteConnectionClosed")
    #expect(metadata["elapsed_ms"]?.description == "25")
    #expect(metadata["body_bytes"]?.description == "0")
    #expect(metadata["headers_ms"] == nil)
    #expect(metadata["first_body_ms"] == nil)
    #expect(metadata["upstream_status"] == nil)
    #expect(metadata["request_id"] == nil)
  }

  @Test func providerBodyDisconnectKeepsStatusClassificationAndTransportCause() async {
    let diagnostics = NativeImageDiagnostics(streaming: false)
    diagnostics.receivedHeaders(status: 429)
    let first = Mutex(true)
    let stream = AsyncThrowingStream<ByteBuffer, any Error>(unfolding: {
      if first.withLock({
        let result = $0
        $0 = false
        return result
      }) {
        return ByteBuffer(string: "{")
      }
      throw HTTPClientError.remoteConnectionClosed
    })
    let error = await ProviderError.failure(
      response: .init(status: .tooManyRequests, body: .stream(stream)), diagnostics: diagnostics)
    #expect(error.status == 429)
    #expect(error.code == "upstream_rate_limited")
    let metadata = diagnostics.metadata(error: error, requestID: "untrusted")
    #expect(metadata["error_type"]?.description == "remoteConnectionClosed")
    #expect(metadata["body_bytes"]?.description == "1")
    #expect(metadata["upstream_status"]?.description == "429")
  }

  @Test func collectorStillRejectsOversizedBody() async throws {
    let diagnostics = NativeImageDiagnostics(streaming: false)
    do {
      _ = try await collectProgressBody(
        .bytes(ByteBuffer(string: "abc")), progress: ExecutionProgress(try ExecutionBudget()),
        maximum: 2, onChunk: { diagnostics.receivedBody(bytes: $0) })
      Issue.record("Expected size rejection")
    } catch {
      #expect((error as? GatewayProtocolError)?.code == "upstream_response_too_large")
      #expect(
        diagnostics.metadata(error: error, requestID: "untrusted")["body_bytes"]?.description == "3"
      )
    }
  }
}
