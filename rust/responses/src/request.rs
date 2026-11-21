use crate::{
    BindingKind, JsonValue, ObjectBinding, ProtocolError, image_payload::validate_mask, metadata,
    object, opaque_context, same_text, text, valid_id,
};

pub const MAX_REQUEST_BYTES: usize = 64 * 1024 * 1024;
pub const RESPONSES_LITE_HEADER: &str = "x-openai-internal-codex-responses-lite";
const LITE_METADATA: &str = "ws_request_header_x_openai_internal_codex_responses_lite";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Mode {
    Generation,
    Compact,
    Warmup,
    Priming,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Contract {
    Responses,
    CodexSubscription,
}

/// The deployment model list, before Key authorization.
#[derive(Clone, Copy, Debug)]
pub struct ImageModels<'a> {
    pub default_model: &'a str,
    pub allowed_models: &'a [&'a str],
}

pub struct PreviousTools<'a> {
    pub model: &'a str,
    pub response_id: &'a str,
    pub uses_responses_lite: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub model: String,
    pub stream: bool,
    pub mode: Mode,
    pub stream_compaction: bool,
    pub uses_responses_lite: bool,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
    pub vision_input: bool,
    pub image_model: Option<String>,
    pub expects_svg: bool,
    pub references: Vec<ObjectBinding>,
    pub affinity_hints: Vec<ObjectBinding>,
    document: JsonValue,
}

pub fn validate_request_media_type(
    content_types: &[&str],
    content_encodings: &[&str],
) -> Result<(), ProtocolError> {
    if let [content_type] = content_types
        && content_type
            .to_ascii_lowercase()
            .starts_with("application/json")
        && content_encodings.is_empty()
    {
        return Ok(());
    }
    Err(ProtocolError::new(415, "unsupported_content_type"))
}

impl Request {
    pub fn parse(
        bytes: &[u8],
        mode: Mode,
        images: Option<ImageModels<'_>>,
    ) -> Result<Self, ProtocolError> {
        Self::parse_with_previous_tools(bytes, mode, images, None)
    }

    pub fn parse_with_previous_tools(
        bytes: &[u8],
        mode: Mode,
        images: Option<ImageModels<'_>>,
        previous_tools: Option<PreviousTools<'_>>,
    ) -> Result<Self, ProtocolError> {
        if bytes.len() > MAX_REQUEST_BYTES {
            return Err(ProtocolError::new(413, "request_too_large"));
        }
        let document = JsonValue::decode(bytes).map_err(|_| invalid("invalid_json"))?;
        let JsonValue::Object(mut fields) = document else {
            return Err(invalid("invalid_request"));
        };
        let model = fields
            .get("model")
            .and_then(JsonValue::as_str)
            .filter(|s| !s.is_empty() && s.len() <= 128)
            .ok_or(invalid("unsupported_request"))?
            .to_owned();
        for name in ["store", "stream", "background"] {
            if let Some(value) = fields.get(name)
                && !matches!(value, JsonValue::Null | JsonValue::Bool(_))
            {
                return Err(invalid("invalid_request"));
            }
        }
        if fields.get("background") == Some(&JsonValue::Bool(true)) {
            return Err(invalid("unsupported_background"));
        }
        if ["conversation", "prompt", "generate"].iter().any(|name| {
            fields
                .get(name)
                .is_some_and(|value| value != &JsonValue::Null)
        }) {
            return Err(invalid("unsupported_request"));
        }

        let stream = fields.get("stream") == Some(&JsonValue::Bool(true));
        let reasoning_effort = metadata(fields.get("reasoning").and_then(|v| v.get("effort")));
        let service_tier = metadata(fields.get("service_tier"));
        let previous_id = fields
            .get("previous_response_id")
            .filter(|&value| value != &JsonValue::Null)
            .map(|value| valid_id(value).ok_or(invalid("invalid_reference")))
            .transpose()?
            .map(str::to_owned);
        for (parent, members) in [
            ("reasoning", &["effort", "summary", "context"][..]),
            ("text", &["verbosity", "format"][..]),
        ] {
            if let Some(object) = fields.get_mut(parent).and_then(JsonValue::as_object_mut) {
                object.retain(|key, value| !members.contains(&key) || value != &JsonValue::Null);
            }
        }
        fields.retain(|key, value| {
            !["tool_choice", "parallel_tool_calls"].contains(&key) || value != &JsonValue::Null
        });
        let input = fields
            .get("input")
            .filter(|&value| value != &JsonValue::Null)
            .ok_or(invalid("invalid_input"))?;
        let items = input.as_array().unwrap_or_default();
        let tools = fields
            .get("tools")
            .and_then(JsonValue::as_array)
            .unwrap_or_default();
        let packages = items
            .iter()
            .filter(|item| text(item, "type") == Some("additional_tools"));
        let has_packages = packages.clone().next().is_some();
        let mut image_tools = tools
            .iter()
            .enumerate()
            .filter(|(_, tool)| text(tool, "type") == Some("image_generation"));
        let image_tool = image_tools.next();
        if image_tools.next().is_some()
            || tools
                .iter()
                .any(|tool| text(tool, "type") == Some("namespace") && contains_image_tool(tool))
            || packages.clone().any(contains_image_tool)
        {
            return Err(invalid("unsupported_tools").with_detail("tools_image"));
        }
        let image_model = image_tool
            .map(|(_, tool)| select_image_model(tool, images))
            .transpose()?;
        let expects_svg =
            image_tool.is_some_and(|(_, tool)| text(tool, "output_format") == Some("svg"));
        let inherits_lite = fields.get("tools").is_none()
            && !has_packages
            && previous_tools.is_some_and(|previous| {
                previous.uses_responses_lite
                    && same_text(previous.model, &model)
                    && previous_id
                        .as_deref()
                        .is_some_and(|id| same_text(previous.response_id, id))
            });
        let uses_responses_lite = has_packages
            || inherits_lite
            || fields
                .get("client_metadata")
                .and_then(|v| text(v, LITE_METADATA))
                == Some("true");
        let mut vision_input = false;
        let mut first_image_url = None;
        scan_images(input, &mut vision_input, &mut first_image_url);

        let mut references = Vec::new();
        if let Some(id) = previous_id {
            references.push(ObjectBinding::new(BindingKind::Response, id));
        }
        let mut affinity_hints = Vec::new();
        let mut stream_compaction = false;
        for (index, item) in items.iter().enumerate() {
            let Some(fields) = item.as_object() else {
                continue;
            };
            let item_type = text(item, "type").unwrap_or("message");
            let id = item.get("id").and_then(valid_id);
            if item_type == "compaction_trigger" {
                if mode != Mode::Generation
                    || stream_compaction
                    || index + 1 != items.len()
                    || fields.len() != 1
                {
                    return Err(invalid("unsupported_compaction_trigger"));
                }
                stream_compaction = true;
            }
            let reads_state = item_type == "item_reference"
                || (item_type == "image_generation_call" && text(item, "result").is_none())
                || (item_type == "reasoning" && text(item, "encrypted_content").is_none());
            if reads_state && let Some(id) = id {
                let reference = ObjectBinding::new(BindingKind::Item, id);
                // Preserve validation precedence while bounding the distinct references retained.
                if references.len() <= 32 && !references.contains(&reference) {
                    references.push(reference);
                }
                continue;
            }
            if item_type == "item_reference" {
                return Err(invalid("invalid_reference"));
            }
            if let Some(call) = item.get("call_id").and_then(valid_id) {
                push_hint(
                    &mut affinity_hints,
                    ObjectBinding::new(BindingKind::FunctionCall, call),
                );
            }
            if let Some(context) = item
                .get("encrypted_content")
                .and_then(|v| opaque_context(item_type, v))
            {
                push_hint(&mut affinity_hints, context);
            } else if let Some(id) = id
                && !local_label(item_type)
            {
                push_hint(
                    &mut affinity_hints,
                    ObjectBinding::new(BindingKind::Item, id),
                );
            }
        }
        if references.len() > 32 {
            return Err(invalid("too_many_references"));
        }
        affinity_hints.retain(|hint| !references.contains(hint));
        if let Some(mask) = image_tool.and_then(|(_, tool)| tool.get("input_image_mask")) {
            let mask_url = text(mask, "image_url")
                .filter(|_| mask.as_object().is_some_and(|o| o.len() == 1))
                .ok_or(invalid("invalid_mask"))?;
            validate_mask(first_image_url.ok_or(invalid("invalid_mask"))?, mask_url)?;
        }
        let image_index = image_tool.map(|(index, _)| index);
        if let Some(JsonValue::Array(items)) = fields.get_mut("input") {
            for item in items {
                let Some(fields) = item.as_object_mut() else {
                    continue;
                };
                let item_type = fields
                    .get("type")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("message");
                if local_label(item_type)
                    || (matches!(item_type, "reasoning" | "compaction")
                        && fields
                            .get("encrypted_content")
                            .and_then(JsonValue::as_str)
                            .is_some())
                {
                    fields.remove("id");
                }
            }
        }
        if let (Some(index), Some(model), Some(JsonValue::Array(tools))) =
            (image_index, &image_model, fields.get_mut("tools"))
        {
            tools[index]
                .as_object_mut()
                .expect("selected image tool")
                .insert("model", JsonValue::String(model.clone()));
        }
        Ok(Self {
            model,
            stream,
            mode: if stream_compaction {
                Mode::Compact
            } else {
                mode
            },
            stream_compaction,
            uses_responses_lite,
            reasoning_effort,
            service_tier,
            vision_input,
            image_model,
            expects_svg,
            references,
            affinity_hints,
            document: JsonValue::Object(fields),
        })
    }

    pub fn document(&self) -> &JsonValue {
        &self.document
    }

    /// Check the selected contract before admission when the request must remain available.
    pub fn validate_contract(
        &self,
        contract: Contract,
        native_websocket: bool,
    ) -> Result<(), ProtocolError> {
        if !self.rewrite_subscription(contract) {
            return Ok(());
        }
        let document = &self.document;
        let image = self.image_model.is_some();
        if !image {
            for (key, reason) in BACKEND_PARAMETERS {
                if document
                    .get(key)
                    .is_some_and(|value| value != &JsonValue::Null)
                {
                    return Err(invalid("unsupported_backend_parameter").with_detail(reason));
                }
            }
        }
        if document.get("store") == Some(&JsonValue::Bool(true)) {
            return Err(
                invalid("unsupported_backend_parameter").with_detail("backend_parameter_store")
            );
        }
        if !native_websocket
            && !image
            && document
                .get("previous_response_id")
                .is_some_and(|value| value != &JsonValue::Null)
        {
            return Err(invalid("unsupported_backend_parameter")
                .with_detail("backend_parameter_previous_response_id"));
        }
        Ok(())
    }

    /// Consume the request to avoid a second in-memory copy of large inline content.
    pub fn into_upstream_document(
        mut self,
        contract: Contract,
        native_websocket: bool,
    ) -> Result<JsonValue, ProtocolError> {
        self.validate_contract(contract, native_websocket)?;
        if self.rewrite_subscription(contract) {
            let image = self.image_model.is_some();
            let fields = self
                .document
                .as_object_mut()
                .expect("parsed request object");
            fields.retain(|key, value| {
                value != &JsonValue::Null
                    || !(["service_tier", "previous_response_id"].contains(&key)
                        || (!image && BACKEND_PARAMETERS.iter().any(|(name, _)| *name == key)))
            });
            fields.insert("store", JsonValue::Bool(false));
            fields.insert("stream", JsonValue::Bool(true));
            if let Some(input @ JsonValue::String(_)) = fields.get_mut("input") {
                let content = std::mem::replace(input, JsonValue::Null);
                *input = JsonValue::Array(vec![object([
                    ("role", JsonValue::String("user".into())),
                    ("content", content),
                ])]);
            }
        }
        Ok(self.document)
    }

    fn rewrite_subscription(&self, contract: Contract) -> bool {
        contract == Contract::CodexSubscription
            && (self.mode != Mode::Compact || self.stream_compaction)
    }
}

const BACKEND_PARAMETERS: [(&str, &str); 6] = [
    ("max_output_tokens", "backend_parameter_max_output_tokens"),
    ("temperature", "backend_parameter_temperature"),
    ("top_p", "backend_parameter_top_p"),
    ("truncation", "backend_parameter_truncation"),
    (
        "prompt_cache_retention",
        "backend_parameter_prompt_cache_retention",
    ),
    ("metadata", "backend_parameter_metadata"),
];

fn invalid(code: &'static str) -> ProtocolError {
    ProtocolError::new(400, code)
}

fn select_image_model(
    tool: &JsonValue,
    images: Option<ImageModels<'_>>,
) -> Result<String, ProtocolError> {
    let denied = ProtocolError::new(403, "model_not_allowed");
    let images = images.ok_or(denied)?;
    let requested = tool
        .get("model")
        .map_or(Some(images.default_model), JsonValue::as_str)
        .ok_or(denied)?;
    let model = images
        .allowed_models
        .iter()
        .find(|id| same_text(id, requested))
        .ok_or(denied)?;
    if tool
        .get("svg")
        .is_some_and(|value| value != &JsonValue::Null)
    {
        return Err(invalid("unsupported_svg_model_selection"));
    }
    Ok((*model).to_owned())
}

fn contains_image_tool(namespace: &JsonValue) -> bool {
    namespace
        .get("tools")
        .and_then(JsonValue::as_array)
        .unwrap_or_default()
        .iter()
        .any(|tool| match text(tool, "type") {
            Some("image_generation") => true,
            Some("namespace") => contains_image_tool(tool),
            _ => false,
        })
}

fn scan_images<'a>(value: &'a JsonValue, vision: &mut bool, first_url: &mut Option<&'a str>) {
    match value {
        JsonValue::Object(object) => {
            if text(value, "type") == Some("input_image") {
                *vision = true;
                if first_url.is_none() {
                    *first_url = text(value, "image_url");
                }
            }
            for (_, child) in object.iter() {
                scan_images(child, vision, first_url);
            }
        }
        JsonValue::Array(items) => {
            for child in items {
                scan_images(child, vision, first_url);
            }
        }
        _ => {}
    }
}

fn local_label(item_type: &str) -> bool {
    matches!(
        item_type,
        "message" | "function_call_output" | "custom_tool_call_output" | "additional_tools"
    )
}

fn push_hint(hints: &mut Vec<ObjectBinding>, hint: ObjectBinding) {
    hints.retain(|existing| existing != &hint);
    if hints.len() == 64 {
        hints.remove(0);
    }
    hints.push(hint);
}

/// An explicit state constrains routing. Only the caller can verify its owner.
pub fn request_turn_state<'a>(
    headers: &[&'a str],
    connection: &[&str],
    document: &'a JsonValue,
) -> Result<Option<&'a str>, ProtocolError> {
    if headers.len() > 1 {
        return Err(invalid("conflicting_turn_state"));
    }
    let header = headers.first().copied();
    if header.is_some_and(|header| {
        !valid_turn_state(header)
            || connection
                .iter()
                .flat_map(|value| value.split(','))
                .any(|value| value.trim().eq_ignore_ascii_case("x-codex-turn-state"))
    }) {
        return Err(invalid("invalid_turn_state"));
    }
    let metadata = document
        .get("client_metadata")
        .filter(|&value| value != &JsonValue::Null);
    if header.is_some() && metadata.is_some_and(|value| value.as_object().is_none()) {
        return Err(invalid("invalid_client_metadata"));
    }
    let message = metadata
        .and_then(|value| value.get("x-codex-turn-state"))
        .filter(|&value| value != &JsonValue::Null)
        .map(|value| {
            value
                .as_str()
                .filter(|s| valid_turn_state(s))
                .ok_or(invalid("invalid_turn_state"))
        })
        .transpose()?;
    if let (Some(header), Some(message)) = (header, message)
        && !same_text(header, message)
    {
        return Err(invalid("conflicting_turn_state"));
    }
    Ok(message.or(header))
}

pub(crate) fn valid_turn_state(value: &str) -> bool {
    (1..=8192).contains(&value.len()) && value.bytes().all(|b| b == b'\t' || (b >= 32 && b != 127))
}

/// The model policy describes the already-selected model and the key's available image models.
/// The execution coordinator still authorizes the request and resolves every hard reference.
pub struct ModelPolicy<'a> {
    pub id: &'a str,
    pub vision_input: bool,
    pub image_generation: bool,
    pub effective_image_models: &'a [&'a str],
    pub effective_reasoning_efforts: &'a [&'a str],
    pub restrict_reasoning_effort: bool,
    pub key_reasoning_efforts: Option<&'a [&'a str]>,
}

impl ModelPolicy<'_> {
    pub fn validate(&self, request: &Request) -> Result<(), ProtocolError> {
        if !same_text(self.id, &request.model)
            || (request.vision_input && !self.vision_input)
            || request.image_model.as_deref().is_some_and(|image| {
                !self.image_generation
                    || !self
                        .effective_image_models
                        .iter()
                        .any(|model| same_text(image, model))
            })
        {
            return Err(ProtocolError::new(403, "model_not_allowed"));
        }
        if request.mode == Mode::Warmup
            || !(self.restrict_reasoning_effort || self.key_reasoning_efforts.is_some())
        {
            return Ok(());
        }
        let effort = request
            .document
            .get("reasoning")
            .and_then(|value| text(value, "effort"));
        let allowed =
            |effort: &str, options: &[&str]| options.iter().any(|option| same_text(effort, option));
        if request.document.get("reasoning_effort").is_some()
            || !effort.is_some_and(|effort| {
                allowed(effort, self.effective_reasoning_efforts)
                    && self
                        .key_reasoning_efforts
                        .is_none_or(|options| allowed(effort, options))
            })
        {
            return Err(ProtocolError::new(403, "reasoning_effort_not_allowed"));
        }
        Ok(())
    }
}
