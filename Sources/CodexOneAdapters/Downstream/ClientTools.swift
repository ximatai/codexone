import Foundation

struct ClientToolSnapshot: Sendable {
  let responseID: String
  let model: String
  let functions: Set<String>
  let custom: Set<String>
  let usesResponsesLite: Bool
}

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
      else { throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsName) }
    }
    return namespace.map { $0 + ":" + name } ?? name
  }

  init(_ value: JSONValue?) throws {
    guard let value else { return }
    guard let tools = value.array else {
      throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsContainer)
    }
    guard tools.count <= 64 else {
      throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsCount)
    }
    var count = 0
    func declarations(_ tools: [JSONValue], namespace: String?) throws -> (Set<String>, Set<String>)
    {
      var functions = Set<String>()
      var custom = Set<String>()
      for tool in tools {
        count += 1
        guard count <= 64 else {
          throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsCount)
        }
        if tool["type"]?.string == "image_generation" {
          guard namespace == nil else {
            throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsImage)
          }
          continue  // Validated against the deployment mapping by ResponseRequest.
        }
        switch tool["type"]?.string {
        case "web_search", "web_search_preview":
          throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsBuiltinSearch)
        case "tool_search":
          throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsDiscovery)
        case "mcp":
          throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsRemoteMCP)
        case "function", "custom", "namespace": break
        default: throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsType)
        }
        guard let name = tool["name"]?.string else {
          throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsName)
        }
        let key = try Self.key(name: name, namespace: namespace)
        if let description = tool["description"],
          description.string == nil || description.string!.utf8.count > 32_768
        {
          throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsDescription)
        }
        for boolean in ["strict", "defer_loading"] {
          if let value = tool[boolean], value.bool == nil {
            throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsBoolean)
          }
        }
        switch tool["type"]?.string {
        case "namespace":
          guard namespace == nil, let nested = tool["tools"]?.array else {
            throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsNamespace)
          }
          guard
            tool.object?.keys.allSatisfy({ ["type", "name", "description", "tools"].contains($0) })
              == true
          else {
            throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsMembers)
          }
          let result = try declarations(nested, namespace: name)
          guard functions.isDisjoint(with: result.0), custom.isDisjoint(with: result.1) else {
            throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsDuplicate)
          }
          functions.formUnion(result.0)
          custom.formUnion(result.1)
        case "function":
          guard
            tool.object?.keys.allSatisfy({
              ["type", "name", "description", "parameters", "strict", "defer_loading"].contains($0)
            }) == true
          else { throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsMembers) }
          guard functions.insert(key).inserted else {
            throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsDuplicate)
          }
        case "custom":
          guard
            tool.object?.keys.allSatisfy({
              ["type", "name", "description", "format", "defer_loading"].contains($0)
            }) == true
          else { throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsMembers) }
          guard custom.insert(key).inserted else {
            throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsDuplicate)
          }
          if let format = tool["format"] {
            if format["type"]?.string == "text" {
              guard format.object?.keys.allSatisfy({ $0 == "type" }) == true else {
                throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsGrammar)
              }
            } else {
              guard format["type"]?.string == "grammar",
                ["lark", "regex"].contains(format["syntax"]?.string ?? ""),
                let definition = format["definition"]?.string, definition.utf8.count <= 65_536,
                format.object?.keys.allSatisfy({ ["type", "syntax", "definition"].contains($0) })
                  == true
              else { throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsGrammar) }
            }
          }
        default: throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsType)
        }
      }
      return (functions, custom)
    }
    (functions, custom) = try declarations(tools, namespace: nil)
    guard functions.isDisjoint(with: custom) else {
      throw GatewayProtocolError(400, "unsupported_tools", detail: .toolsDuplicate)
    }
  }
}
