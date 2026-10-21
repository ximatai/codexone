import CodexOneCore
import Foundation

struct GatewayProtocolError: Error, Sendable {
  let status: Int
  let code: String
  init(_ status: Int, _ code: String) {
    self.status = status
    self.code = code
  }
}

struct ResponseRequest: Sendable {
  let model: String
  let streaming: Bool
  let references: [ObjectBinding]
  let functionNames: Set<String>
  let document: JSONValue
  init(data: Data) throws {
    guard data.count <= 524_288 else { throw GatewayProtocolError(413, "request_too_large") }
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
      "prompt_cache_retention", "background",
    ]
    guard fields.keys.allSatisfy(allowed.contains), let model = fields["model"]?.string,
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
    if let tools = fields["tools"] {
      guard let tools = tools.array, tools.count <= 64 else {
        throw GatewayProtocolError(400, "unsupported_tools")
      }
      for tool in tools {
        guard tool["type"]?.string == "function", let name = tool["name"]?.string,
          !name.isEmpty, name.utf8.count <= 128
        else { throw GatewayProtocolError(400, "unsupported_tools") }
      }
    }
    if let choice = fields["tool_choice"] {
      if let mode = choice.string {
        guard ["auto", "none", "required"].contains(mode) else {
          throw GatewayProtocolError(400, "unsupported_tools")
        }
      } else {
        guard choice["type"]?.string == "function", let name = choice["name"]?.string,
          fields["tools"]?.array?.contains(where: { $0["name"]?.string == name }) == true
        else {
          throw GatewayProtocolError(400, "unsupported_tools")
        }
      }
    }
    if let include = fields["include"] {
      guard include.array == [] else { throw GatewayProtocolError(400, "unsupported_include") }
    }
    guard let input = fields["input"] else { throw GatewayProtocolError(400, "invalid_input") }
    if input.string == nil {
      guard let items = input.array, items.count <= 256 else {
        throw GatewayProtocolError(400, "invalid_input")
      }
      for item in items {
        guard let object = item.object else { throw GatewayProtocolError(400, "invalid_input") }
        let type = object["type"]?.string ?? "message"
        switch type {
        case "message":
          guard let role = object["role"]?.string,
            ["user", "assistant", "system", "developer"].contains(role),
            let content = object["content"]
          else { throw GatewayProtocolError(400, "invalid_input") }
          if content.string == nil {
            guard let parts = content.array, parts.count <= 128,
              parts.allSatisfy({
                ["input_text", "output_text"].contains($0["type"]?.string ?? "")
                  && $0["text"]?.string != nil
                  && $0.object?.keys.allSatisfy({ ["type", "text"].contains($0) }) == true
              })
            else {
              throw GatewayProtocolError(400, "unsupported_input")
            }
          }
        case "function_call_output":
          guard let id = object["call_id"]?.string, !id.isEmpty, id.utf8.count <= 256,
            object["output"]?.string != nil
          else { throw GatewayProtocolError(400, "invalid_input") }
          references.append(.init(type: "function_call", rawID: id))
        case "function_call":
          guard object["name"]?.string != nil, object["arguments"]?.string != nil,
            let id = object["call_id"]?.string, !id.isEmpty, id.utf8.count <= 256
          else { throw GatewayProtocolError(400, "invalid_input") }
          references.append(.init(type: "function_call", rawID: id))
        case "item_reference":
          guard let id = object["id"]?.string, !id.isEmpty, id.utf8.count <= 256 else {
            throw GatewayProtocolError(400, "invalid_reference")
          }
          references.append(.init(type: "item", rawID: id))
        default: throw GatewayProtocolError(400, "unsupported_input")
        }
        // File, conversation and other private references are not allowed as unknown fields.
        let allowedItem: Set<String> = [
          "type", "role", "content", "id", "status", "name", "arguments", "call_id", "output",
        ]
        guard object.keys.allSatisfy(allowedItem.contains) else {
          throw GatewayProtocolError(400, "unsupported_input")
        }
        if let id = object["id"]?.string { references.append(.init(type: "item", rawID: id)) }
      }
    }
    guard references.count <= 32 else { throw GatewayProtocolError(400, "too_many_references") }
    self.functionNames = Set(fields["tools"]?.array?.compactMap { $0["name"]?.string } ?? [])
    self.references = references
    self.document = document
  }
}
