import Foundation

struct ClientTools: Sendable {
  var functions = Set<String>()
  var custom = Set<String>()

  static func key(name: String, namespace: String? = nil) throws -> String {
    for value in [name, namespace].compactMap({ $0 }) {
      guard !value.isEmpty, value.utf8.count <= 128,
        value.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || [45, 46, 95].contains($0)
        })
      else { throw GatewayProtocolError(400, "unsupported_tools") }
    }
    return namespace.map { $0 + ":" + name } ?? name
  }

  init(_ value: JSONValue?) throws {
    guard let value else { return }
    guard let tools = value.array, tools.count <= 64 else {
      throw GatewayProtocolError(400, "unsupported_tools")
    }
    var count = 0
    func declarations(_ tools: [JSONValue], namespace: String?) throws -> (Set<String>, Set<String>)
    {
      var functions = Set<String>()
      var custom = Set<String>()
      for tool in tools {
        count += 1
        if tool["type"]?.string == "image_generation" {
          guard namespace == nil, count <= 64 else {
            throw GatewayProtocolError(400, "unsupported_tools")
          }
          continue  // Validated against the deployment mapping by ResponseRequest.
        }
        guard count <= 64, let name = tool["name"]?.string else {
          throw GatewayProtocolError(400, "unsupported_tools")
        }
        let key = try Self.key(name: name, namespace: namespace)
        if let description = tool["description"],
          description.string == nil || description.string!.utf8.count > 8192
        {
          throw GatewayProtocolError(400, "unsupported_tools")
        }
        for boolean in ["strict", "defer_loading"] {
          if let value = tool[boolean], value.bool == nil {
            throw GatewayProtocolError(400, "unsupported_tools")
          }
        }
        switch tool["type"]?.string {
        case "namespace":
          guard namespace == nil, let nested = tool["tools"]?.array,
            tool.object?.keys.allSatisfy({ ["type", "name", "description", "tools"].contains($0) })
              == true
          else { throw GatewayProtocolError(400, "unsupported_tools") }
          let result = try declarations(nested, namespace: name)
          guard functions.isDisjoint(with: result.0), custom.isDisjoint(with: result.1) else {
            throw GatewayProtocolError(400, "unsupported_tools")
          }
          functions.formUnion(result.0)
          custom.formUnion(result.1)
        case "function":
          guard
            tool.object?.keys.allSatisfy({
              ["type", "name", "description", "parameters", "strict", "defer_loading"].contains($0)
            }) == true,
            functions.insert(key).inserted
          else { throw GatewayProtocolError(400, "unsupported_tools") }
        case "custom":
          guard
            tool.object?.keys.allSatisfy({
              ["type", "name", "description", "format", "defer_loading"].contains($0)
            }) == true,
            custom.insert(key).inserted
          else { throw GatewayProtocolError(400, "unsupported_tools") }
          if let format = tool["format"] {
            if format["type"]?.string == "text" {
              guard format.object?.keys.allSatisfy({ $0 == "type" }) == true else {
                throw GatewayProtocolError(400, "unsupported_tools")
              }
            } else {
              guard format["type"]?.string == "grammar",
                ["lark", "regex"].contains(format["syntax"]?.string ?? ""),
                let definition = format["definition"]?.string, definition.utf8.count <= 65_536,
                format.object?.keys.allSatisfy({ ["type", "syntax", "definition"].contains($0) })
                  == true
              else { throw GatewayProtocolError(400, "unsupported_tools") }
            }
          }
        default: throw GatewayProtocolError(400, "unsupported_tools")
        }
      }
      return (functions, custom)
    }
    (functions, custom) = try declarations(tools, namespace: nil)
    guard functions.isDisjoint(with: custom) else {
      throw GatewayProtocolError(400, "unsupported_tools")
    }
  }
}
