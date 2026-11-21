use codexone_config::{Model, ResponsesConfiguration};
use codexone_responses::ProtocolError;
use http::Uri;
use serde_json::{Value, json};

pub fn document(config: &ResponsesConfiguration, uri: &Uri) -> Result<Value, ProtocolError> {
    let mut data: Vec<_> = config
        .models
        .iter()
        .map(|model| {
            json!({
                "id": model.id, "object": "model", "owned_by": "configured-provider",
                "vision_input": model.vision_input == Some(true),
                "image_generation": model.image_generation == Some(true),
            })
        })
        .collect();
    if let Some(images) = &config.image_generation {
        data.extend(images.models.iter().map(|image| {
            json!({
                "id": image.id, "object": "model", "owned_by": "configured-provider",
                "image_generation": true,
            })
        }));
    }
    let mut result = json!({"object": "list", "data": data});
    let profiles: Option<Vec<_>> = config
        .models
        .iter()
        .enumerate()
        .map(|(index, model)| profile(index, model))
        .collect();
    if let Some(profiles) = profiles {
        result["models"] = Value::Array(profiles);
    } else if requires_profile(uri) {
        return Err(ProtocolError::new(503, "model_catalog_unavailable"));
    }
    Ok(result)
}

fn requires_profile(uri: &Uri) -> bool {
    uri.query().is_some_and(|query| {
        query.split('&').any(|item| {
            let name = item.split_once('=').map_or(item, |(name, _)| name);
            percent_encoding::percent_decode_str(name)
                .decode_utf8()
                .is_ok_and(|name| name == "client_version")
        })
    })
}

fn profile(index: usize, model: &Model) -> Option<Value> {
    let vision = model.vision_input == Some(true);
    let mut entry = if let Some(profile) = &model.upstream {
        let mut entry = profile.clone();
        if !vision
            && let Some(modalities) = entry
                .get_mut("input_modalities")
                .and_then(Value::as_array_mut)
        {
            modalities.retain(|modality| modality != "image");
        }
        entry["prefer_websockets"] = json!(false);
        entry
    } else {
        let metadata = model.catalog.as_ref()?;
        let instructions = metadata.base_instructions.as_deref()?;
        let context = metadata.context_window.unwrap_or(32_768);
        let levels: Vec<_> = metadata
            .reasoning_efforts
            .iter()
            .flatten()
            .map(|effort| json!({"effort": effort, "description": effort}))
            .collect();
        let mut entry = json!({
            "display_name": metadata.display_name.as_deref().unwrap_or(&model.id),
            "description": metadata.description.as_deref().unwrap_or("Configured text model"),
            "base_instructions": instructions,
            "supported_reasoning_levels": levels,
            "shell_type": "unified_exec",
            "visibility": "list",
            "supported_in_api": true,
            "support_verbosity": false,
            "supports_reasoning_summary_parameter": true,
            "truncation_policy": {"mode": "tokens", "limit": 10_000},
            "context_window": context,
            "max_context_window": metadata.max_context_window.unwrap_or(context),
            "auto_compact_token_limit": context * 3 / 4,
            "experimental_supported_tools": [],
            "input_modalities": if vision { json!(["text", "image"]) } else { json!(["text"]) },
            "supports_search_tool": false,
            "include_apps_usage_instructions": false,
            "include_skills_usage_instructions": false,
            "include_plugin_usage_instructions": false,
        });
        if let Some(effort) = &metadata.default_reasoning_effort {
            entry["default_reasoning_level"] = json!(effort);
        }
        entry
    };
    entry["slug"] = json!(model.id);
    entry["priority"] = json!(index);
    if let Some(provenance) = &model.profile_provenance {
        entry["codexone_profile"] = json!({
            "source": provenance.source, "revision": provenance.revision,
            "sha256": format!("{:02x}", sha2::digest::Output::<sha2::Sha256>::from(provenance.sha256)),
            "captured_at": provenance.captured_at_unix_seconds,
            "client_versions": provenance.client_versions,
            "overridden": provenance.overridden,
            "stale": provenance.captured_at_unix_seconds < crate::unix_time() - 2_592_000,
        });
    }
    Some(entry)
}
