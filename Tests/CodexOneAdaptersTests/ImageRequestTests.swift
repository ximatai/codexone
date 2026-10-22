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
@Test func imageRequestsShareReferenceValidationAndRejectUnsupportedParametersBeforeDispatch()
  throws
{
  let config = try syntheticImageConfiguration()
  let url = "data:image/png;base64," + syntheticImagePNG.base64EncodedString()
  func request(_ extra: [String: JSONValue] = [:], editing: Bool = false) throws -> ImagesRequest {
    var fields: [String: JSONValue] = ["prompt": .string("synthetic edit")]
    for (key, value) in extra { fields[key] = value }
    return try ImagesRequest(
      data: JSONValue.object(fields).data(), contentType: "application/json", editing: editing,
      configuration: config)
  }
  let generation = try request()
  #expect(generation.response.admissionModel == "synthetic-image")
  #expect(generation.response.model == "synthetic-host")
  #expect(generation.response.requirements.route == .images)
  let edit = try request(
    [
      "images": .array([.object(["image_url": .string(url)])]),
      "mask": .object(["image_url": .string(url)]),
    ], editing: true)
  #expect(
    edit.response.document["tools"]?.array?.first?["input_image_mask"]?["image_url"]?.string == url)
  #expect(!edit.response.requirements.visionInput)
  for fields: [String: JSONValue] in [
    ["model": .number(123)], ["model": .null], ["model": .object([:])],
    ["n": .number(2)], ["size": .string("2048x1024")], ["response_format": .string("url")],
    ["background": .string("transparent"), "output_format": .string("jpeg")],
    ["output_compression": .number(50)], ["user": .string("unrecognized")],
    ["partial_images": .number(4)],
  ] { #expect(throws: (any Error).self) { try request(fields) } }
  #expect(throws: (any Error).self) { try request(editing: true) }
  #expect(throws: (any Error).self) {
    try request(
      ["images": .array([.object(["image_url": .string("https://example.invalid/image.png")])])],
      editing: true)
  }
  let response = try ResponseRequest(
    data: JSONValue.object([
      "model": .string("synthetic-host"),
      "input": .array([
        .object([
          "role": .string("user"),
          "content": .array([.object(["type": .string("input_image"), "image_url": .string(url)])]),
        ])
      ]),
    ]).data())
  #expect(response.requirements.visionInput && response.requirements.imageModel == nil)
  #expect(throws: (any Error).self) {
    try ResponseRequest(data: generation.response.document.data())
  }
}
@Test func multipartImagesPreserveBinaryAndMaskAndRejectAmbiguousHeaders() throws {
  var body = Data(
    "--synthetic\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nsynthetic edit\r\n--synthetic\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"synthetic.png\"\r\nContent-Type: image/png\r\n\r\n"
      .utf8)
  body.append(syntheticImagePNG)
  body.append(Data("\r\n--synthetic--\r\n".utf8))
  let request = try ImagesRequest(
    data: body, contentType: "multipart/form-data; boundary=synthetic", editing: true,
    configuration: syntheticImageConfiguration())
  #expect(request.response.requirements.route == .images)
  #expect(request.response.document["input"]?.array?.first?["content"]?.array?.count == 2)
  for length in [0, 1, body.count - 3] {
    #expect(throws: (any Error).self) {
      try imageMultipart(
        Data(body.prefix(length)), contentType: "multipart/form-data; boundary=synthetic")
    }
  }
}
@Test func imageCompletionWaitsForResponseTerminalAndKeepsToolUsageSeparate() throws {
  let config = try syntheticImageConfiguration()
  let request = try ImagesRequest(
    data: Data(#"{"prompt":"synthetic"}"#.utf8), contentType: "application/json", editing: false,
    configuration: config)
  let encoded = syntheticImagePNG.base64EncodedString()
  let item: JSONValue = .object([
    "type": .string("image_generation_call"), "id": .string("ig_synthetic"),
    "status": .string("completed"), "result": .string(encoded),
    "usage": .object(["input_tokens": .number(2), "output_tokens": .number(3)]),
  ])
  let response: JSONValue = .object([
    "id": .string("resp_synthetic"), "status": .string("completed"), "output": .array([item]),
    "usage": .object([
      "input_tokens": .number(5), "output_tokens": .number(7),
      "input_tokens_details": .object(["cached_tokens": .number(0)]),
    ]),
  ])
  #expect(
    try imageReply(
      .object(["type": .string("response.output_item.done"), "item": item]), streaming: true,
      editing: false) == nil)
  let reply = try imageReply(
    .object(["type": .string("response.completed"), "response": response]), streaming: true,
    editing: true)
  #expect(reply?["type"]?.string == "image_edit.completed")
  let model = SingleIdentityConfiguration.Model(
    id: "synthetic-host", inputMicrosPerMillion: 1_000_000, outputMicrosPerMillion: 1_000_000)
  let usage = try #require(
    try request.response.usage(response, model: model, configuration: config))
  #expect(
    usage.inputTokens == 5 && usage.outputTokens == 7 && usage.imageInputTokens == 2
      && usage.imageOutputTokens == 3)
  #expect(usage.images == 1 && usage.estimatedMicros == 25 && usage.completeness == .complete)
  var missing = response.object!
  var noUsage = item.object!
  noUsage.removeValue(forKey: "usage")
  missing["output"] = .array([.object(noUsage)])
  let partial = try #require(
    try request.response.usage(.object(missing), model: model, configuration: config))
  #expect(
    partial.completeness == .partial && partial.imageInputTokens == nil && partial.images == 1)
  #expect(throws: (any Error).self) {
    try ProviderObservation(
      event: .object(["type": .string("response.completed"), "response": response]), model: model,
      functionNames: [])
  }
  let observed = try ProviderObservation(
    event: .object(["type": .string("response.completed"), "response": response]), model: model,
    functionNames: [], allowImages: true)
  #expect(
    observed.terminal && observed.bindings.contains(.init(type: "item", rawID: "ig_synthetic")))
}
