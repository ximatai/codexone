import Foundation

/// Both directory forms use the same effective model set. Metadata does not grant capabilities.
func modelCatalog(_ models: [SingleIdentityConfiguration.Model]) -> JSONValue {
  let api = models.map { model in
    JSONValue.object([
      "id": .string(model.id), "object": .string("model"),
      "owned_by": .string("configured-provider"),
    ])
  }
  let codex = models.enumerated().map { index, model in
    let metadata = model.catalog
    let context = metadata?.contextWindow ?? 32_768
    var entry: [String: JSONValue] = [
      "slug": .string(model.id), "display_name": .string(metadata?.displayName ?? model.id),
      "description": .string(metadata?.description ?? "Configured text model"),
      // The released CLI still requires the legacy catalog field.
      "base_instructions": .string(""),
      "supported_reasoning_levels": .array(
        (metadata?.reasoningEfforts ?? []).map { effort in
          .object(["effort": .string(effort), "description": .string(effort)])
        }),
      "shell_type": .string("unified_exec"), "visibility": .string("list"),
      "supported_in_api": .bool(true), "priority": .number(Decimal(index)),
      "support_verbosity": .bool(false), "supports_reasoning_summary_parameter": .bool(true),
      "truncation_policy": .object(["mode": .string("tokens"), "limit": .number(10_000)]),
      "context_window": .number(Decimal(context)), "max_context_window": .number(Decimal(context)),
      "auto_compact_token_limit": .number(Decimal(context * 3 / 4)),
      "experimental_supported_tools": .array([]), "input_modalities": .array([.string("text")]),
      "supports_search_tool": .bool(false), "include_apps_usage_instructions": .bool(false),
      "include_skills_usage_instructions": .bool(false),
      "include_plugin_usage_instructions": .bool(false),
    ]
    if let effort = metadata?.defaultReasoningEffort {
      entry["default_reasoning_level"] = .string(effort)
    }
    return JSONValue.object(entry)
  }
  return .object(["object": .string("list"), "data": .array(api), "models": .array(codex)])
}
