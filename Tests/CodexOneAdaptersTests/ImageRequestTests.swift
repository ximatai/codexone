import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

func syntheticImageConfiguration() throws -> ImageConfiguration {
  try JSONDecoder().decode(
    ImageConfiguration.self,
    from: Data(
      #"{"defaultModel":"synthetic-image","models":[{"id":"synthetic-image","hostModel":"synthetic-host","sizePolicy":"fixed1536","supportsTransparency":true,"supportsInputFidelity":true,"inputMicrosPerMillion":2000000,"outputMicrosPerMillion":3000000}]}"#
        .utf8))
}
@Test func nativeImagesPreserveBytesAndLeaveParametersToProvider() throws {
  let config = try syntheticImageConfiguration()
  let raw = Data(
    #"{ "model" : "synthetic-image", "unknown":{"future":true}, "n":3, "size":"future", "prompt":"synthetic" }"#
      .utf8)
  let request = try ImagesRequest(
    data: raw, contentType: "application/json", editing: false, configuration: config)
  #expect(request.body == raw)
  let defaulted = try ImagesRequest(
    data: Data(#"{"prompt":"synthetic","unknown":1}"#.utf8), contentType: "application/json",
    editing: false, configuration: config)
  #expect(try JSONValue.decode(defaulted.body)["model"] == .string("synthetic-image"))
  #expect(try JSONValue.decode(defaulted.body)["unknown"] == .number(1))
  for model: JSONValue in [.null, .number(1)] {
    #expect(throws: (any Error).self) {
      try ImagesRequest(
        data: JSONValue.object(["model": model]).data(), contentType: "application/json",
        editing: false, configuration: config)
    }
  }
  #expect(throws: (any Error).self) {
    try ImagesRequest(
      data: Data(#"{"images":[{"image_url":"https://example.invalid/image"}]}"#.utf8),
      contentType: "application/json", editing: true, configuration: config)
  }
}

@Test func nativeImageUsageDoesNotInventMissingCounters() throws {
  let model = try #require(syntheticImageConfiguration().models.first)
  let image: JSONValue = .object(["b64_json": .string(syntheticImagePNG.base64EncodedString())])
  let complete = NativeImageObservation(
    .object([
      "data": .array([image]),
      "usage": .object(["input_tokens": .number(2), "output_tokens": .number(3)]),
    ]), model: model)
  #expect(complete.images == 1)
  #expect(complete.usage?.estimatedMicros == 13)
  #expect(complete.usage?.imageInputTokens == 2 && complete.usage?.imageOutputTokens == 3)
  #expect(complete.usage?.completeness == .complete)
  let partial = NativeImageObservation(.object(["data": .array([image])]), model: model)
  #expect(partial.usage?.imageInputTokens == nil && partial.usage?.imageOutputTokens == nil)
  #expect(partial.usage?.completeness == .partial)
  #expect(NativeImageObservation(.object(["data": .array([])]), model: model).images == 0)
}

@Test func imageCapacityTimesOutAndReleasesExactlyOnceOnCancellation() async throws {
  let capacity = ImageCapacity(limit: 1)
  let first = try await capacity.acquire()
  do {
    _ = try await capacity.acquire(timeout: .milliseconds(50))
    Issue.record("Capacity must time out")
  } catch let error as GatewayProtocolError {
    #expect(
      error.status == 429 && error.code == "image_capacity_exhausted" && error.cooldownSeconds == 1)
  }
  let waiting = Task { try await capacity.acquire() }
  waiting.cancel()
  do {
    _ = try await waiting.value
    Issue.record("Cancelled waiter admitted")
  } catch is CancellationError {}
  first.release()
  first.release()
  let next = try await capacity.acquire(timeout: .milliseconds(50))
  do {
    _ = try await capacity.acquire(timeout: .milliseconds(50))
    Issue.record("Double release increased capacity")
  } catch {}
  next.release()
  _ = try await capacity.acquire(timeout: .milliseconds(50))
}

@Test func visionCompactionAndImageToolsDoNotRequireTheMappedConversationHost() throws {
  let config = try syntheticImageConfiguration()
  let input: [JSONValue] = [
    .object([
      "role": .string("user"),
      "content": .array([
        .object(["type": .string("input_image"), "image_url": .string("synthetic-opaque")])
      ]),
    ])
  ]
  for compact in [false, true] {
    let request = try ResponseRequest(
      data: JSONValue.object([
        "model": .string("synthetic-other"),
        "input": .array(
          input + (compact ? [] : [.object(["type": .string("compaction_trigger")])])),
        "tools": .array([.object(["type": .string("image_generation")])]),
      ]).data(), mode: compact ? .compact : .generation, imageConfiguration: config)
    #expect(
      request.requirements.visionInput && request.requirements.imageModel == "synthetic-image")
    #expect(request.mode == .compact)
  }
}
