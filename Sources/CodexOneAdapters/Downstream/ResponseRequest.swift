import CodexOneCore
import Foundation

enum ProtocolRejectionDetail: String, Sendable {
  case reasoningEffort = "reasoning_effort"
  case toolsImage = "tools_image"
  case upstreamTurnLifecycle = "upstream_turn_lifecycle"
  case upstreamTurnCreated = "upstream_turn_created"
  case upstreamTurnResponseID = "upstream_turn_response_id"
  case downstreamJSONWrite = "downstream_json_write"
  case upstreamEvent = "upstream_event"
  case upstreamMediaTypeJSON = "upstream_media_type_json"
  case upstreamMediaTypeHTML = "upstream_media_type_html"
  case upstreamMediaTypeOther = "upstream_media_type_other"
}

struct GatewayProtocolError: Error, Sendable {
  let status: Int
  let code: String
  let cooldownSeconds: Int64?
  let detail: ProtocolRejectionDetail?
  let upstreamStatus: Int?
  /// Sanitized provider error members forwarded so clients can apply their own error handling.
  let providerError: JSONValue?
  let explicitProviderRejection: Bool
  init(
    _ status: Int, _ code: String, cooldownSeconds: Int64? = nil,
    detail: ProtocolRejectionDetail? = nil, upstreamStatus: Int? = nil,
    providerError: JSONValue? = nil, explicitProviderRejection: Bool = false
  ) {
    self.explicitProviderRejection = explicitProviderRejection
    self.upstreamStatus = upstreamStatus
    self.detail = detail
    self.cooldownSeconds = cooldownSeconds
    self.status = status
    self.code = code
    self.providerError = providerError
  }
}

struct ResponseRequest: Sendable {
  static let liteMetadataKey = "ws_request_header_x_openai_internal_codex_responses_lite"
  /// Most recent soft references kept for account affinity; older history adds no routing value.
  static let maximumAffinityHints = 64
  var requirements = ExecutionRequirements()
  var admissionModel: String { model }
  let model: String
  let streaming: Bool
  /// References that read provider-side state; each must be owned by the caller.
  let references: [ObjectBinding]
  /// Opaque client history labels used only to keep pooled continuations on their account.
  let affinityHints: [ObjectBinding]
  let mode: ExecutionMode
  let streamCompaction: Bool
  let usesResponsesLite: Bool
  let document: JSONValue
  init(data: Data, mode: ExecutionMode = .generation, imageConfiguration: ImageConfiguration? = nil)
    throws
  {
    try self.init(
      data: data, mode: mode, imageConfiguration: imageConfiguration,
      maximumBytes: RequestBodyLimits.maximumBytes, previousTools: nil)
  }
  init(
    data: Data, mode: ExecutionMode, imageConfiguration: ImageConfiguration?,
    previousTools: ClientToolSnapshot?
  ) throws {
    try self.init(
      data: data, mode: mode, imageConfiguration: imageConfiguration,
      maximumBytes: RequestBodyLimits.maximumBytes, previousTools: previousTools)
  }
  /// Only the gateway's own responsibilities are enforced here: permissions, bounded size,
  /// provider-state references and execution mode. Everything else is the provider's contract.
  private init(
    data: Data, mode: ExecutionMode, imageConfiguration: ImageConfiguration?, maximumBytes: Int,
    previousTools: ClientToolSnapshot?
  ) throws {
    guard data.count <= maximumBytes else {
      throw GatewayProtocolError(413, "request_too_large")
    }
    let document: JSONValue
    do { document = try JSONValue.decode(data) } catch {
      throw GatewayProtocolError(400, "invalid_json")
    }
    guard var fields = document.object else { throw GatewayProtocolError(400, "invalid_request") }
    guard let model = fields["model"]?.string, !model.isEmpty, model.utf8.count <= 128 else {
      throw GatewayProtocolError(400, "unsupported_request")
    }
    for boolean in ["store", "stream", "background"] {
      if let value = fields[boolean], value != .null, value.bool == nil {
        throw GatewayProtocolError(400, "invalid_request")
      }
    }
    guard fields["background"]?.bool != true else {
      throw GatewayProtocolError(400, "unsupported_background")
    }
    // Server-stored conversations and prompts cannot be proven to belong to this caller;
    // generate is a WS-only warmup control removed before this point.
    for key in ["conversation", "prompt", "generate"]
    where fields[key] != nil && fields[key] != .null {
      throw GatewayProtocolError(400, "unsupported_request")
    }
    self.model = model
    self.streaming = fields["stream"]?.bool == true
    var references: [ObjectBinding] = []
    var hints: [ObjectBinding] = []
    if let previous = fields["previous_response_id"], previous != .null {
      guard let id = previous.string, !id.isEmpty, id.utf8.count <= 256 else {
        throw GatewayProtocolError(400, "invalid_reference")
      }
      references.append(.init(type: "response", rawID: id))
    }
    // Known nullable optional members mean unspecified; strip only those nulls.
    if let reasoning = fields["reasoning"]?.object {
      fields["reasoning"] = .object(reasoning.filter { $0.value != .null })
    }
    if let text = fields["text"]?.object {
      fields["text"] = .object(
        text.filter { !(["verbosity", "format"].contains($0.key) && $0.value == .null) })
    }
    for key in ["tool_choice", "parallel_tool_calls"] where fields[key] == .null {
      fields.removeValue(forKey: key)
    }
    let input = fields["input"]
    guard input != nil, input != .null else { throw GatewayProtocolError(400, "invalid_input") }
    let items = input?.array ?? []
    // Image generation stays a permissioned, top-level declaration only.
    let topLevelTools = fields["tools"]?.array ?? []
    let packages = items.filter { $0["type"]?.string == "additional_tools" }
    func nestedImageTool(_ tools: [JSONValue]) -> Bool {
      tools.contains {
        $0["type"]?.string == "image_generation"
          || ($0["type"]?.string == "namespace" && nestedImageTool($0["tools"]?.array ?? []))
      }
    }
    let imageTools = topLevelTools.filter { $0["type"]?.string == "image_generation" }
    guard imageTools.count <= 1,
      !topLevelTools.contains(where: {
        $0["type"]?.string == "namespace" && nestedImageTool($0["tools"]?.array ?? [])
      }),
      !packages.contains(where: { nestedImageTool($0["tools"]?.array ?? []) })
    else { throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsImage) }
    let imageTool = try imageTools.first.map {
      try ImageToolRequest($0, configuration: imageConfiguration)
    }
    let inherited =
      fields["tools"] == nil && packages.isEmpty
        && previousTools?.model == model
        && fields["previous_response_id"]?.string == previousTools?.responseID
      ? previousTools : nil
    usesResponsesLite =
      !packages.isEmpty
      || fields["client_metadata"]?[Self.liteMetadataKey]?.string == "true"
      || inherited?.usesResponsesLite == true
    var streamCompaction = false
    var visionInput = false
    var firstImageURL: String?
    func scanImages(_ value: JSONValue) {
      if let object = value.object {
        if object["type"]?.string == "input_image" {
          visionInput = true
          if firstImageURL == nil { firstImageURL = object["image_url"]?.string }
        }
        for child in object.values { scanImages(child) }
      } else if let parts = value.array {
        for part in parts { scanImages(part) }
      }
    }
    scanImages(input!)
    func hint(_ binding: ObjectBinding) {
      hints.removeAll { $0 == binding }
      hints.append(binding)
      if hints.count > Self.maximumAffinityHints { hints.removeFirst() }
    }
    for (index, item) in items.enumerated() {
      guard let object = item.object else { continue }
      let type = object["type"]?.string ?? "message"
      switch type {
      case "compaction_trigger":
        guard mode == .generation, !streamCompaction, index == items.count - 1, object.count == 1
        else {
          throw GatewayProtocolError(400, "unsupported_compaction_trigger")
        }
        streamCompaction = true
      case "item_reference":
        guard let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 256 else {
          throw GatewayProtocolError(400, "invalid_reference")
        }
        references.append(.init(type: "item", rawID: id))
        continue
      // An item named only by ID makes the provider read stored state, like item_reference.
      case "image_generation_call" where object["result"]?.string == nil,
        "reasoning" where object["encrypted_content"]?.string == nil:
        guard let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 256 else { break }
        references.append(.init(type: "item", rawID: id))
        continue
      default: break
      }
      if let call = object["call_id"]?.string, !call.isEmpty, call.utf8.count <= 256 {
        hint(.init(type: "function_call", rawID: call))
      }
      if ["reasoning", "compaction"].contains(type),
        let binding = try? opaqueContext(object["encrypted_content"], kind: type)
      {
        hint(binding)
      } else if let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 256,
        !Self.localLabelTypes.contains(type)
      {
        hint(.init(type: "item", rawID: id))
      }
    }
    let uniqueReferences = references.reduce(into: [ObjectBinding]()) { result, reference in
      if !result.contains(reference) { result.append(reference) }
    }
    guard uniqueReferences.count <= 32 else {
      throw GatewayProtocolError(400, "too_many_references")
    }
    if let mask = imageTool?.document["input_image_mask"] {
      guard mask.object?.count == 1, let url = mask["image_url"]?.string, let firstImageURL else {
        throw GatewayProtocolError(400, "invalid_mask")
      }
      let image = try ImagePayload(dataURL: firstImageURL, maximumBytes: ImageLimits.imageBytes)
      let payload = try ImagePayload(dataURL: url, maximumBytes: ImageLimits.imageBytes)
      try payload.validateMask(for: image)
    }
    requirements = try .init(
      route: .conversation, visionInput: visionInput, imageModel: imageTool?.model.id)
    self.references = uniqueReferences
    self.affinityHints = hints.filter { !uniqueReferences.contains($0) }
    self.streamCompaction = streamCompaction
    self.mode = streamCompaction ? .compact : mode
    // Inline message/result IDs are local client correlation labels, not provider references.
    // Remove them at the boundary so a guessed ID cannot make an inline item retrieve private state.
    var upstreamFields = fields
    if let items = input?.array {
      upstreamFields["input"] = .array(
        items.map { item in
          guard var object = item.object else { return item }
          let type = object["type"]?.string ?? "message"
          if Self.localLabelTypes.contains(type)
            || (["reasoning", "compaction"].contains(type)
              && object["encrypted_content"]?.string != nil)
          {
            object.removeValue(forKey: "id")
          }
          return .object(object)
        })
    }
    if let imageTool, let declarations = fields["tools"]?.array {
      upstreamFields["tools"] = .array(
        declarations.map { $0["type"]?.string == "image_generation" ? imageTool.document : $0 })
    }
    self.document = .object(upstreamFields)
  }

  private static let localLabelTypes: Set<String> = [
    "message", "function_call_output", "custom_tool_call_output", "additional_tools",
  ]
}
