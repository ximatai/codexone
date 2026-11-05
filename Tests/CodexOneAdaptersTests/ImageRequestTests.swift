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
    #"{ "model" : "synthetic-image", "unknown":{"future":true}, "service_tier":"priority", "n":3, "size":"future", "prompt":"synthetic" }"#
      .utf8)
  let request = try ImagesRequest(
    data: raw, contentType: "application/json", editing: false, configuration: config)
  #expect(request.body == raw)
  #expect(request.serviceTier == "priority")
  let defaulted = try ImagesRequest(
    data: Data(#"{"prompt":"synthetic","unknown":1}"#.utf8), contentType: "application/json",
    editing: false, configuration: config)
  #expect(defaulted.serviceTier == nil)
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

@Test func imageExtendedFormatsRequireVerifiedAccountAndNonStreamingTransport() throws {
  let baseline = try syntheticImageConfiguration()
  var document = try JSONValue.decode(JSONEncoder().encode(baseline)).object!
  var model = document["models"]!.array![0].object!
  model["verifiedGenerationOutputFormatsByAccount"] = .object([
    "synthetic-a": .array([.string("gif")]),
    "synthetic-b": .array([.string("svg")]),
  ])
  document["models"] = .array([.object(model)])
  let verified = try JSONDecoder().decode(
    ImageConfiguration.self, from: JSONValue.object(document).data())
  func request(
    _ format: String, _ extra: JSONObject = [:], editing: Bool = false,
    config: ImageConfiguration? = nil
  ) throws -> ImagesRequest {
    var fields = extra
    fields["output_format"] = .string(format)
    return try ImagesRequest(
      data: JSONValue.object(fields).data(), contentType: "application/json",
      editing: editing, configuration: config ?? verified)
  }
  for format in ["gif", "svg", "unconfirmed-future"] {
    #expect(throws: GatewayProtocolError.self) { try request(format, config: baseline) }
  }
  #expect(try request("gif").verifiedAccountIDs == ["synthetic-a"])
  #expect(try request("svg").verifiedAccountIDs == ["synthetic-b"])
  #expect(try !request("gif").upstreamStreaming)
  #expect(try !request("svg").upstreamStreaming)
  #expect(try request("png").upstreamStreaming)
  #expect(try request("png").verifiedAccountIDs == nil)
  for format in ["gif", "svg"] {
    for invalid: JSONObject in [
      ["stream": .bool(true)], ["partial_images": .number(0)],
      ["output_compression": .number(90)],
    ] {
      #expect(throws: GatewayProtocolError.self) { try request(format, invalid) }
    }
  }
  #expect(throws: GatewayProtocolError.self) { try request("svg", editing: true) }
  #expect(throws: GatewayProtocolError.self) { try request("svg", ["n": .number(2)]) }
  #expect(throws: GatewayProtocolError.self) {
    try request("svg", ["prompt_rewriter": .bool(true)])
  }
  #expect(try request("svg", ["n": .number(1)]).verifiedAccountIDs == ["synthetic-b"])
  let explanation = protocolErrorEnvelope(
    GatewayProtocolError(400, "image_format_not_verified"),
    requestID: "synthetic", diagnostics: false)
  #expect(explanation["error"]?["message"]?.string?.contains("not been verified") == true)
}

@Test func nativeImageCriticalDuplicateMembersAreRejectedWithoutChangingUnknownFields() throws {
  let config = try syntheticImageConfiguration()
  let duplicated = #"{"model":"synthetic-image","output_format":"png","output_fo\u0072mat":"gif"}"#
  for encoding: String.Encoding in [.utf8, .utf16LittleEndian, .utf16BigEndian] {
    let data = try #require(duplicated.data(using: encoding))
    #expect(throws: GatewayProtocolError.self) {
      try ImagesRequest(
        data: data, contentType: "application/json", editing: false, configuration: config)
    }
  }
  let unknown = Data(
    #"{"model":"synthetic-image","future":1,"future":2,"output_format":"png"}"#.utf8)
  #expect(
    try ImagesRequest(
      data: unknown, contentType: "application/json", editing: true,
      configuration: config
    ).body == unknown)
  for format in ["gif", "svg"] {
    #expect(throws: GatewayProtocolError.self) {
      try ImageToolRequest(
        .object(["type": .string("image_generation"), "output_format": .string(format)]),
        configuration: config)
    }
  }
}
