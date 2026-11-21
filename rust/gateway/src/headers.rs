use codexone_config::{ClientFingerprint, Model};
use codexone_responses::{JsonValue, ProtocolError, request_turn_state};
use http::{HeaderMap, HeaderValue, header};

pub fn values<'a>(headers: &'a HeaderMap, name: &str) -> Vec<&'a str> {
    // Keep invalid or repeated fields visible to validators that require one field.
    headers
        .get_all(name)
        .iter()
        .map(|value| value.to_str().unwrap_or_default())
        .collect()
}

pub(crate) fn hop_by_hop(headers: &HeaderMap, name: &str) -> bool {
    values(headers, "connection")
        .into_iter()
        .flat_map(|value| value.split(','))
        .any(|field| field.trim().eq_ignore_ascii_case(name))
}

pub fn client(
    headers: &HeaderMap,
    document: &JsonValue,
    fingerprint: &ClientFingerprint,
    models: &[Model],
) -> Result<HeaderMap, ProtocolError> {
    const ALLOWED: &[&str] = &[
        "user-agent",
        "originator",
        "version",
        "session_id",
        "x-session-id",
        "conversation_id",
        "x-conversation-id",
        "session-id",
        "thread-id",
        "openai-beta",
        "x-openai-subagent",
        "x-openai-memgen-request",
    ];
    const NATIVE_AGENTS: &[&str] = &[
        "codex_cli_rs",
        "codex-tui",
        "codex_exec",
        "codex_sdk_ts",
        "codex_vscode",
        "Codex Desktop",
        "Codex ",
    ];
    const NATIVE_ORIGINATORS: &[&str] = &[
        "codex_cli_rs",
        "codex_vscode",
        "codex_sdk_ts",
        "codex_exec",
        "codex_chatgpt_desktop",
        "Codex Desktop",
    ];

    let mut result = HeaderMap::new();
    let turn_states = values(headers, "x-codex-turn-state");
    request_turn_state(&turn_states, &values(headers, "connection"), document)?;
    let mut codex_count = turn_states.len();
    if let Some(state) = headers.get("x-codex-turn-state") {
        result.insert("x-codex-turn-state", state.clone());
    }
    for (name, value) in headers {
        let codex = name.as_str().starts_with("x-codex-");
        if name == "x-codex-turn-state"
            || !(codex || ALLOWED.contains(&name.as_str()))
            || value.len() > 8192
            || hop_by_hop(headers, name.as_str())
            || (codex && codex_count >= 32)
        {
            continue;
        }
        codex_count += usize::from(codex);
        result.append(name.clone(), value.clone());
    }

    let native = values(headers, "user-agent")
        .into_iter()
        .any(|agent| NATIVE_AGENTS.iter().any(|prefix| agent.starts_with(prefix)))
        || values(headers, "originator")
            .into_iter()
            .any(|originator| NATIVE_ORIGINATORS.contains(&originator));
    if !native {
        let version = fingerprint.version.as_deref().unwrap_or_else(|| {
            models
                .iter()
                .filter_map(|model| model.profile_provenance.as_ref())
                .flat_map(|profile| &profile.client_versions)
                .max_by_key(|version| {
                    version
                        .split('.')
                        .map(|field| field.parse::<u64>().unwrap_or(0))
                        .collect::<Vec<_>>()
                })
                .map_or("0.163.0", String::as_str)
        });
        let agent = format!(
            "codex_cli_rs/{version} ({}; {}) {}",
            fingerprint.os.as_deref().unwrap_or("Mac OS 26.5.0"),
            fingerprint.arch.as_deref().unwrap_or("arm64"),
            fingerprint
                .terminal
                .as_deref()
                .unwrap_or("iTerm.app/3.6.10"),
        );
        let bad_fingerprint = |_| ProtocolError::new(503, "execution_indeterminate");
        result.insert(header::USER_AGENT, agent.parse().map_err(bad_fingerprint)?);
        result.insert("originator", HeaderValue::from_static("codex_cli_rs"));
        result.insert("version", version.parse().map_err(bad_fingerprint)?);
    }
    Ok(result)
}

pub fn provider(headers: &HeaderMap, include_model: bool) -> HeaderMap {
    let mut result = HeaderMap::new();
    if !hop_by_hop(headers, "x-codex-turn-state")
        && let Some(value) = headers.get("x-codex-turn-state")
        && let Ok(state) = value.to_str()
        && request_turn_state(&[state], &[], &JsonValue::Null).is_ok()
    {
        result.insert("x-codex-turn-state", value.clone());
    }
    if include_model
        && !hop_by_hop(headers, "openai-model")
        && let [model] = values(headers, "openai-model").as_slice()
        && (1..=128).contains(&model.len())
        && model
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte))
    {
        result.insert("openai-model", headers["openai-model"].clone());
    }
    result
}
