import Foundation

/// Both directory forms use the same effective model set. Metadata does not grant capabilities.
func modelCatalog(
  _ models: [SingleIdentityConfiguration.Model], requireCodexProfile: Bool = false,
  images: [ImageConfiguration.Model] = [], runtimeBudget: JSONValue? = nil,
  upstreamTransport: String? = nil
)
  throws -> JSONValue
{
  let api =
    models.map { model in
      JSONValue.object([
        "id": .string(model.id), "object": .string("model"),
        "owned_by": .string("configured-provider"),
        "vision_input": .bool(model.visionInput == true),
        "image_generation": .bool(model.imageGeneration == true),
      ])
    }
    + images.map {
      .object([
        "id": .string($0.id), "object": .string("model"),
        "owned_by": .string("configured-provider"), "image_generation": .bool(true),
      ])
    }
  guard
    models.allSatisfy({
      if $0.upstream != nil { return true }
      guard let instructions = $0.catalog?.baseInstructions else { return false }
      return !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
  else {
    if requireCodexProfile { throw GatewayProtocolError(503, "model_catalog_unavailable") }
    var result: [String: JSONValue] = ["object": .string("list"), "data": .array(api)]
    result["codexone_execution_budget"] = runtimeBudget
    return .object(result)
  }
  let codex = models.enumerated().map { index, model in
    let metadata = model.catalog
    let context = metadata?.contextWindow ?? 32_768
    var entry: [String: JSONValue] = [
      "slug": .string(model.id), "display_name": .string(metadata?.displayName ?? model.id),
      "description": .string(metadata?.description ?? "Configured text model"),
      // An explicit authoritative profile must not silently clear the client's base guidance.
      "base_instructions": .string(metadata?.baseInstructions ?? ""),
      "supported_reasoning_levels": .array(
        (metadata?.reasoningEfforts ?? []).map { effort in
          .object(["effort": .string(effort), "description": .string(effort)])
        }),
      "shell_type": .string("unified_exec"), "visibility": .string("list"),
      "supported_in_api": .bool(true), "priority": .number(Decimal(index)),
      "support_verbosity": .bool(false), "supports_reasoning_summary_parameter": .bool(true),
      "truncation_policy": .object(["mode": .string("tokens"), "limit": .number(10_000)]),
      "context_window": .number(Decimal(context)),
      "max_context_window": .number(Decimal(metadata?.maxContextWindow ?? context)),
      "auto_compact_token_limit": .number(Decimal(context * 3 / 4)),
      "experimental_supported_tools": .array([]),
      "input_modalities": .array(
        model.visionInput == true ? [.string("text"), .string("image")] : [.string("text")]),
      "supports_search_tool": .bool(false), "include_apps_usage_instructions": .bool(false),
      "include_skills_usage_instructions": .bool(false),
      "include_plugin_usage_instructions": .bool(false),
    ]
    if let upstream = model.upstream?.object {
      entry = upstream
      entry["slug"] = .string(model.id)
      entry["priority"] = .number(Decimal(index))
      if model.visionInput != true, let modalities = entry["input_modalities"]?.array {
        entry["input_modalities"] = .array(modalities.filter { $0 != .string("image") })
      }
      if upstreamTransport != "websocket" { entry["prefer_websockets"] = .bool(false) }
    }
    if let profile = model.profileProvenance {
      entry["codexone_profile"] = .object([
        "source": .string(profile.source), "revision": .string(profile.revision),
        "sha256": .string(profile.sha256),
        "captured_at": .number(Decimal(profile.capturedAtUnixSeconds)),
        "client_versions": .array(profile.clientVersions.map { .string($0) }),
        "overridden": .bool(profile.overridden),
        "stale": .bool(
          profile.capturedAtUnixSeconds < Int64(Date().timeIntervalSince1970) - 2_592_000),
      ])
    }
    if let effort = metadata?.defaultReasoningEffort {
      entry["default_reasoning_level"] = .string(effort)
    }
    return JSONValue.object(entry)
  }
  var result: [String: JSONValue] = [
    "object": .string("list"), "data": .array(api), "models": .array(codex),
  ]
  result["codexone_execution_budget"] = runtimeBudget
  return .object(result)
}
