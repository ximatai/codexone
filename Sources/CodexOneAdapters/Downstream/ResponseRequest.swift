import CodexOneCore
import Foundation

struct GatewayProtocolError: Error, Sendable {
  let status: Int
  let code: String
  let cooldownSeconds: Int64?
  init(_ status: Int, _ code: String, cooldownSeconds: Int64? = nil) {
    self.cooldownSeconds = cooldownSeconds
    self.status = status
    self.code = code
  }
}

struct ResponseRequest: Sendable {
  var requirements = ExecutionRequirements()
  var admissionModel: String { requirements.route == .images ? requirements.imageModel! : model }
  let model: String
  let streaming: Bool
  let references: [ObjectBinding]
  let functionNames: Set<String>
  let customToolNames: Set<String>
  let mode: ExecutionMode
  let streamCompaction: Bool
  let document: JSONValue
  init(data: Data, mode: ExecutionMode = .generation, imageConfiguration: ImageConfiguration? = nil)
    throws
  {
    try self.init(
      data: data, mode: mode, imageConfiguration: imageConfiguration,
      maximumBytes: ImageLimits.requestBytes)
  }
  init(normalizedImage: JSONValue, imageConfiguration: ImageConfiguration?) throws {
    try self.init(
      data: normalizedImage.data(escapingSlashes: false), mode: .generation,
      imageConfiguration: imageConfiguration, maximumBytes: ImageLimits.normalizedRequestBytes)
  }
  private init(
    data: Data, mode: ExecutionMode, imageConfiguration: ImageConfiguration?, maximumBytes: Int
  ) throws {
    guard data.count <= maximumBytes else {
      throw GatewayProtocolError(413, "request_too_large")
    }
    let document: JSONValue
    do { document = try JSONValue.decode(data) } catch {
      throw GatewayProtocolError(400, "invalid_json")
    }
    guard let fields = document.object else { throw GatewayProtocolError(400, "invalid_request") }
    let allowed: Set<String> = [
      "model", "input", "instructions", "tools", "tool_choice", "parallel_tool_calls",
      "reasoning", "text", "temperature", "top_p", "max_output_tokens", "store", "stream",
      "previous_response_id",
      "service_tier", "truncation", "include", "metadata", "prompt_cache_key",
      "prompt_cache_retention", "background", "client_metadata", "stream_options",
    ]
    let compactAllowed: Set<String> = [
      "model", "input", "instructions", "previous_response_id", "prompt_cache_key",
      "prompt_cache_retention", "service_tier",
    ]
    guard fields.keys.allSatisfy((mode == .compact ? compactAllowed : allowed).contains),
      let model = fields["model"]?.string,
      !model.isEmpty, model.utf8.count <= 128
    else { throw GatewayProtocolError(400, "unsupported_request") }
    for boolean in ["store", "stream", "background", "parallel_tool_calls"] {
      if let value = fields[boolean], value.bool == nil {
        throw GatewayProtocolError(400, "invalid_request")
      }
    }
    guard fields["background"]?.bool != true else {
      throw GatewayProtocolError(400, "unsupported_background")
    }
    self.model = model
    self.streaming = fields["stream"]?.bool == true
    var references: [ObjectBinding] = []
    if let previous = fields["previous_response_id"], previous != .null {
      guard let id = previous.string, !id.isEmpty, id.utf8.count <= 256 else {
        throw GatewayProtocolError(400, "invalid_reference")
      }
      references.append(.init(type: "response", rawID: id))
    }
    if let reasoning = fields["reasoning"], reasoning != .null {
      guard reasoning.object?.keys.allSatisfy({ ["effort", "summary"].contains($0) }) == true else {
        throw GatewayProtocolError(400, "unsupported_reasoning")
      }
      if let effort = reasoning["effort"] {
        guard
          effort.string.map({ !$0.isEmpty && $0.utf8.count <= 32 }) == true
            || effort.integer.map({ (0...1_000_000).contains($0) }) == true
        else { throw GatewayProtocolError(400, "unsupported_reasoning") }
      }
      if let summary = reasoning["summary"] {
        guard ["auto", "concise", "detailed", "none"].contains(summary.string ?? "") else {
          throw GatewayProtocolError(400, "unsupported_reasoning")
        }
      }
    }
    for key in ["metadata", "client_metadata"] {
      if let metadata = fields[key], metadata != .null {
        guard let values = metadata.object, values.count <= 32,
          values.allSatisfy({
            $0.key.utf8.count <= 128 && ($0.value.string?.utf8.count ?? 1025) <= 1024
          })
        else { throw GatewayProtocolError(400, "unsupported_metadata") }
      }
    }
    for key in [
      "instructions", "service_tier", "prompt_cache_key", "prompt_cache_retention", "truncation",
    ] {
      if let value = fields[key], value != .null, value.string == nil {
        throw GatewayProtocolError(400, "unsupported_request")
      }
    }
    if let text = fields["text"], text != .null {
      guard text.object?.keys.allSatisfy({ ["verbosity", "format"].contains($0) }) == true else {
        throw GatewayProtocolError(400, "unsupported_text")
      }
      if let verbosity = text["verbosity"] {
        guard ["low", "medium", "high"].contains(verbosity.string ?? "") else {
          throw GatewayProtocolError(400, "unsupported_text")
        }
      }
      if let format = text["format"] {
        let type = format["type"]?.string ?? ""
        let keys: Set<String> =
          type == "json_schema" ? ["type", "name", "schema", "strict", "description"] : ["type"]
        guard ["text", "json_object", "json_schema"].contains(type),
          format.object?.keys.allSatisfy(keys.contains) == true
        else { throw GatewayProtocolError(400, "unsupported_text") }
        if type == "json_schema" {
          guard format["name"]?.string != nil, format["schema"]?.object != nil,
            format["strict"] == nil || format["strict"]?.bool != nil
          else { throw GatewayProtocolError(400, "unsupported_text") }
        }
      }
    }
    let imageTools =
      fields["tools"]?.array?.filter { $0["type"]?.string == "image_generation" } ?? []
    guard imageTools.count <= 1, imageTools.isEmpty || mode == .generation else {
      throw GatewayProtocolError(400, "unsupported_tools")
    }
    let imageTool = try imageTools.first.map {
      try ImageToolRequest($0, configuration: imageConfiguration, host: model)
    }
    let tools = try ClientTools(fields["tools"])
    self.functionNames = tools.functions
    self.customToolNames = tools.custom
    if let options = fields["stream_options"] {
      guard options.object?.keys.allSatisfy({ $0 == "include_usage" }) == true,
        options["include_usage"]?.bool != nil
      else { throw GatewayProtocolError(400, "unsupported_stream_options") }
    }
    if let choice = fields["tool_choice"] {
      if let mode = choice.string {
        guard ["auto", "none", "required"].contains(mode) else {
          throw GatewayProtocolError(400, "unsupported_tools")
        }
      } else if choice == .object(["type": .string("image_generation")]), imageTool != nil {
        // The only built-in tool enabled in this slice.
      } else {
        guard let name = choice["name"]?.string,
          choice["namespace"] == nil || choice["namespace"]?.string != nil,
          choice.object?.keys.allSatisfy({ ["type", "name", "namespace"].contains($0) }) == true
        else { throw GatewayProtocolError(400, "unsupported_tools") }
        let key = try ClientTools.key(name: name, namespace: choice["namespace"]?.string)
        guard
          choice["type"]?.string == "function" && tools.functions.contains(key)
            || choice["type"]?.string == "custom" && tools.custom.contains(key)
        else { throw GatewayProtocolError(400, "unsupported_tools") }
      }
    }
    if let include = fields["include"] {
      guard let includes = include.array, includes.count <= 1,
        includes.allSatisfy({ $0.string == "reasoning.encrypted_content" })
      else { throw GatewayProtocolError(400, "unsupported_include") }
    }
    guard let input = fields["input"] else { throw GatewayProtocolError(400, "invalid_input") }
    var streamCompaction = false
    var visionInput = false
    var imageBytes = 0
    var imagePixels = 0
    var imageCount = 0
    var firstImage: ImagePayload?
    if input.string == nil {
      guard let items = input.array, items.count <= 256 else {
        throw GatewayProtocolError(400, "invalid_input")
      }
      for (index, item) in items.enumerated() {
        guard let object = item.object else { throw GatewayProtocolError(400, "invalid_input") }
        let type = object["type"]?.string ?? "message"
        if let declared = object["type"], declared.string == nil {
          throw GatewayProtocolError(400, "unsupported_input")
        }
        if let status = object["status"], status != .null {
          guard
            ["in_progress", "completed", "incomplete", "failed", "cancelled"].contains(
              status.string ?? "")
          else { throw GatewayProtocolError(400, "unsupported_input") }
        }
        if let name = object["name"], name != .null {
          guard let name = name.string, (try? ClientTools.key(name: name)) != nil else {
            throw GatewayProtocolError(400, "unsupported_input")
          }
        }
        switch type {
        case "compaction_trigger":
          guard mode == .generation, !streamCompaction, index == items.count - 1,
            object.count == 1
          else { throw GatewayProtocolError(400, "unsupported_compaction_trigger") }
          streamCompaction = true
        case "message":
          guard let role = object["role"]?.string,
            ["user", "assistant", "system", "developer"].contains(role),
            let content = object["content"]
          else { throw GatewayProtocolError(400, "invalid_input") }
          if content.string == nil {
            guard let parts = content.array, parts.count <= 128 else {
              throw GatewayProtocolError(400, "unsupported_input")
            }
            for part in parts where part["type"]?.string == "input_image" {
              guard role == "user",
                part.object?.keys.allSatisfy({ ["type", "image_url", "detail"].contains($0) })
                  == true,
                let url = part["image_url"]?.string,
                part["detail"] == nil
                  || ["auto", "low", "high", "original"].contains(part["detail"]?.string ?? "")
              else { throw GatewayProtocolError(400, "invalid_image") }
              let image = try ImagePayload(dataURL: url, maximumBytes: ImageLimits.imageBytes)
              imageBytes += image.bytes.count
              imagePixels += image.width * image.height
              imageCount += 1
              guard imageBytes <= ImageLimits.totalImageBytes, imagePixels <= 33_554_432,
                imageCount <= 4
              else { throw GatewayProtocolError(413, "image_input_too_large") }
              if firstImage == nil { firstImage = image }
              visionInput = true
            }
            guard

              parts.allSatisfy({ part in
                let type = part["type"]?.string ?? ""
                if type == "input_image" { return true }
                let keys: Set<String> =
                  type == "refusal"
                  ? ["type", "refusal"] : ["type", "text", "annotations", "logprobs"]
                return ["input_text", "output_text", "refusal"].contains(type)
                  && (type == "refusal" ? part["refusal"]?.string : part["text"]?.string) != nil
                  && (part["annotations"] == nil || part["annotations"]?.array == [])
                  && (part["logprobs"] == nil || part["logprobs"] == .null
                    || part["logprobs"]?.array == [])
                  && part.object?.keys.allSatisfy(keys.contains) == true
              })
            else {
              throw GatewayProtocolError(400, "unsupported_input")
            }
          }
        case "function_call_output", "custom_tool_call_output":
          guard let id = object["call_id"]?.string, !id.isEmpty, id.utf8.count <= 256,
            object["output"]?.string != nil
          else { throw GatewayProtocolError(400, "invalid_input") }
          references.append(.init(type: "function_call", rawID: id))
        case "function_call", "custom_tool_call":
          guard let name = object["name"]?.string,
            (type == "function_call" ? object["arguments"]?.string : object["input"]?.string)
              != nil,
            let id = object["call_id"]?.string, !id.isEmpty, id.utf8.count <= 256
          else { throw GatewayProtocolError(400, "invalid_input") }
          _ = try ClientTools.key(name: name, namespace: object["namespace"]?.string)
          references.append(.init(type: "function_call", rawID: id))
        case "reasoning", "compaction":
          if let binding = try opaqueContext(object["encrypted_content"], kind: type) {
            references.append(binding)
          } else if type != "reasoning" || object["id"]?.string == nil {
            throw GatewayProtocolError(400, "invalid_private_context")
          }
          if let content = object["content"], content != .null {
            guard type == "reasoning", let parts = content.array, parts.count <= 128,
              parts.allSatisfy({
                $0["type"]?.string == "reasoning_text" && $0["text"]?.string != nil
                  && $0.object?.keys.allSatisfy({ ["type", "text"].contains($0) }) == true
              })
            else { throw GatewayProtocolError(400, "unsupported_input") }
          }
          if let summary = object["summary"] {
            guard type == "reasoning", let parts = summary.array, parts.count <= 128,
              parts.allSatisfy({
                $0["type"]?.string == "summary_text" && $0["text"]?.string != nil
                  && $0.object?.keys.allSatisfy({ ["type", "text"].contains($0) }) == true
              })
            else { throw GatewayProtocolError(400, "unsupported_input") }
          }
        case "image_generation_call":
          guard imageTool != nil, let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 256
          else { throw GatewayProtocolError(400, "invalid_reference") }
          references.append(.init(type: "item", rawID: id))
        case "item_reference":
          guard let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 256 else {
            throw GatewayProtocolError(400, "invalid_reference")
          }
          references.append(.init(type: "item", rawID: id))
        default: throw GatewayProtocolError(400, "unsupported_input")
        }
        // File, conversation and other private references are not allowed as unknown fields.
        let fieldsByType: [String: Set<String>] = [
          "message": ["role", "content", "phase"],
          "function_call": ["name", "arguments", "call_id", "namespace"],
          "custom_tool_call": ["name", "input", "call_id", "namespace"],
          "function_call_output": ["name", "output", "call_id", "namespace"],
          "custom_tool_call_output": ["name", "output", "call_id", "namespace"],
          "reasoning": ["summary", "content", "encrypted_content"],
          "compaction": ["encrypted_content"],
          "compaction_trigger": [],
          "item_reference": [],
          "image_generation_call": [],
        ]
        let allowedItem = fieldsByType[type, default: []].union(["type", "id", "status"])
        guard object.keys.allSatisfy(allowedItem.contains) else {
          throw GatewayProtocolError(400, "unsupported_input")
        }
        if let namespaceValue = object["namespace"] {
          guard let namespace = namespaceValue.string else {
            throw GatewayProtocolError(400, "unsupported_input")
          }
          _ = try ClientTools.key(name: object["name"]?.string ?? "output", namespace: namespace)
        }
        if let phase = object["phase"] {
          guard type == "message",
            ["analysis", "commentary", "final_answer"].contains(phase.string ?? "")
          else { throw GatewayProtocolError(400, "unsupported_input") }
        }
        if let idValue = object["id"] {
          guard let id = idValue.string, !id.isEmpty, id.utf8.count <= 256 else {
            throw GatewayProtocolError(400, "invalid_reference")
          }
          let completeContext =
            ["reasoning", "compaction"].contains(type)
            && object["encrypted_content"]?.string != nil
          if !["message", "function_call_output", "custom_tool_call_output"].contains(type)
            && !completeContext
          {
            references.append(.init(type: "item", rawID: id))
          }
        }
      }
    }
    let uniqueReferences = references.reduce(into: [ObjectBinding]()) { result, reference in
      if !result.contains(reference) { result.append(reference) }
    }
    guard uniqueReferences.count <= 32 else {
      throw GatewayProtocolError(400, "too_many_references")
    }
    if let mask = imageTool?.document["input_image_mask"] {
      guard mask.object?.count == 1, let url = mask["image_url"]?.string, let firstImage else {
        throw GatewayProtocolError(400, "invalid_mask")
      }
      let payload = try ImagePayload(dataURL: url, maximumBytes: ImageLimits.imageBytes)
      guard imageBytes + payload.bytes.count <= ImageLimits.totalImageBytes else {
        throw GatewayProtocolError(413, "image_input_too_large")
      }
      try payload.validateMask(for: firstImage)
    }
    guard data.count <= 524_288 || visionInput || imageTool != nil else {
      throw GatewayProtocolError(413, "request_too_large")
    }
    guard !(streamCompaction || mode == .compact) || (!visionInput && imageTool == nil) else {
      throw GatewayProtocolError(400, "unsupported_image_compaction")
    }
    requirements = try .init(
      route: .conversation, visionInput: visionInput, imageModel: imageTool?.model.id)
    self.references = uniqueReferences
    self.streamCompaction = streamCompaction
    self.mode = streamCompaction ? .compact : mode
    // Inline message/result IDs are local client correlation labels, not provider references.
    // Remove them at the boundary so a guessed ID cannot make an inline item retrieve private state.
    var upstreamFields = fields
    if let items = input.array {
      upstreamFields["input"] = .array(
        items.map { item in
          var object = item.object!
          let type = object["type"]?.string ?? "message"
          if ["message", "function_call_output", "custom_tool_call_output"].contains(type)
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
}
