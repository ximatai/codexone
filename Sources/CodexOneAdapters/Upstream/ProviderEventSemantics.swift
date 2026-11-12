/// Narrow provider facts, independent of the document forwarded to the client.
/// Unknown events grant no facts, but may still indicate processing and forbid replay.
struct ProviderEventSemantics {
  enum Progress { case none, acknowledgement, activity }
  let known: Bool
  /// Name recognition is diagnostic only; it grants no execution or correlation facts.
  let recognizedType: Bool
  let lifecycle: Bool
  let terminal: Bool
  let carriesItem: Bool
  let carriesItemID: Bool
  let progress: Progress
  let connectionMetadata: Bool

  static let lifecycleEvents: Set<String> = [
    "response.created", "response.queued", "response.in_progress", "response.completed",
    "response.failed", "response.incomplete",
  ]
  static let terminalEvents: Set<String> = [
    "response.completed", "response.failed", "response.incomplete",
  ]
  private static let itemEvents: Set<String> = [
    "response.output_item.added", "response.output_item.done",
  ]
  private static let partEvents: Set<String> = [
    "response.content_part.added", "response.content_part.done",
    "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
    "response.output_text.annotation.added", "response.output_text.done",
    "response.function_call_arguments.done", "response.custom_tool_call_input.done",
    "response.reasoning_text.done", "response.reasoning_summary_text.done", "response.refusal.done",
    "response.image_generation_call.in_progress", "response.image_generation_call.generating",
    "response.image_generation_call.completed", "response.image_generation_call.partial_image",
    "response.web_search_call.in_progress", "response.web_search_call.searching",
    "response.web_search_call.completed", "response.file_search_call.in_progress",
    "response.file_search_call.searching", "response.file_search_call.completed",
    "response.code_interpreter_call.in_progress", "response.code_interpreter_call.interpreting",
    "response.code_interpreter_call.completed", "response.code_interpreter_call_code.done",
  ]
  private static let deltaEvents: Set<String> = [
    "response.output_text.delta", "response.function_call_arguments.delta",
    "response.custom_tool_call_input.delta", "response.reasoning_text.delta",
    "response.reasoning_summary_text.delta", "response.refusal.delta",
    "response.code_interpreter_call_code.delta",
  ]

  /// Native Images has a different envelope; do not infer progress from arbitrary JSON.
  static func nativeImageProgress(_ event: JSONValue) -> Progress {
    switch event["type"]?.string {
    case "image_generation.completed", "image_edit.completed": return .activity
    case "image_generation.partial_image", "image_edit.partial_image":
      return event["b64_json"]?.string?.isEmpty == false ? .activity : .none
    default: return .none
    }
  }

  init(_ event: JSONValue) {
    let type = event["type"]?.string ?? ""
    lifecycle = Self.lifecycleEvents.contains(type)
    terminal = Self.terminalEvents.contains(type)
    carriesItem = Self.itemEvents.contains(type)
    carriesItemID = Self.partEvents.contains(type) || Self.deltaEvents.contains(type)
    connectionMetadata =
      ["response.metadata", "codex.response.metadata", "rate_limits.updated", "codex.rate_limits"]
      .contains(type)
      && ["response", "response_id", "item", "item_id", "delta", "output"].allSatisfy {
        event[$0] == nil
      }
    known = lifecycle || carriesItem || carriesItemID || connectionMetadata || type == "error"
    recognizedType =
      known
      || [
        "response.metadata", "codex.response.metadata", "responsesapi.websocket_timing",
        "response.output_item.interrupted",
      ].contains(type)
    if terminal || carriesItem || Self.partEvents.contains(type) {
      progress = .activity
    } else if Self.deltaEvents.contains(type), event["delta"]?.string?.isEmpty == false {
      progress = .activity
    } else if lifecycle {
      progress = .acknowledgement
    } else {
      progress = .none
    }
  }
}
