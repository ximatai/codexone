use std::collections::BTreeMap;

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use percent_encoding::percent_decode_str;
use serde::{Deserialize, Serialize};

use crate::{DAY, Error, Result};

pub const FAILURES: &[&str] = &[
    "authentication_rejected",
    "rate_limited",
    "upstream_unavailable",
    "upstream_rejected",
    "invalid_upstream_response",
    "deadline_exceeded",
    "client_cancelled",
    "key_rejected",
    "model_not_allowed",
    "object_unavailable",
    "object_ambiguous",
    "local_capacity",
    "account_unavailable",
    "storage_unavailable",
    "invalid_request",
    "indeterminate",
];
pub const MODES: &[&str] = &["generation", "warmup", "compact", "priming"];
pub const STATES: &[&str] = &["intent", "unknown", "settled", "closed_unknown"];
pub const OUTCOMES: &[&str] = &["succeeded", "failed", "cancelled"];
pub const INCOMPLETE: &[&str] = &[
    "max_output_tokens",
    "max_messages",
    "content_filter",
    "steered",
    "unspecified",
];

pub fn rejection_stage(reason: &str) -> Option<&'static str> {
    Some(match reason {
        "account_cooldown"
        | "account_dispatch_unavailable"
        | "account_refresh_required"
        | "account_authorization_required"
        | "account_refresh_capacity"
        | "account_state_changed"
        | "account_refresh_unavailable"
        | "continuation_owner_unavailable" => "routing",
        "backend_parameter_max_output_tokens"
        | "backend_parameter_temperature"
        | "backend_parameter_top_p"
        | "backend_parameter_truncation"
        | "backend_parameter_prompt_cache_retention"
        | "backend_parameter_metadata"
        | "backend_parameter_store"
        | "backend_parameter_previous_response_id"
        | "invalid_request"
        | "conversation_too_large"
        | "invalid_turn_state"
        | "conflicting_turn_state"
        | "invalid_client_metadata"
        | "model_not_allowed"
        | "reasoning_effort_not_allowed"
        | "reasoning_effort_missing"
        | "reasoning_effort_invalid"
        | "reasoning_effort_legacy_field" => "validation",
        _ => return None,
    })
}

pub fn safe_metadata(value: &str) -> &str {
    if (1..=32).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
    {
        value
    } else {
        "other"
    }
}

pub type Parameters = BTreeMap<String, String>;

pub fn parameters(query: Option<&str>, allowed: &[&str]) -> Result<Parameters> {
    let mut parameters = Parameters::new();
    for entry in query
        .filter(|query| !query.is_empty())
        .into_iter()
        .flat_map(|q| q.split('&'))
    {
        let (key, value) = entry.split_once('=').ok_or(Error::Invalid)?;
        let key = percent_decode_str(key)
            .decode_utf8()
            .map_err(|_| Error::Invalid)?;
        let value = percent_decode_str(value)
            .decode_utf8()
            .map_err(|_| Error::Invalid)?;
        if !allowed.contains(&key.as_ref())
            || parameters
                .insert(key.into_owned(), value.into_owned())
                .is_some()
        {
            return Err(Error::Invalid);
        }
    }
    Ok(parameters)
}

pub fn number(values: &Parameters, name: &str) -> Result<Option<i64>> {
    values
        .get(name)
        .map(|value| value.parse().map_err(|_| Error::Invalid))
        .transpose()
}

pub fn boolean(values: &Parameters, name: &str, default: bool) -> Result<bool> {
    match values.get(name).map(String::as_str) {
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        None => Ok(default),
        _ => Err(Error::Invalid),
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Cursor {
    pub at: i64,
    pub id: String,
}

impl Cursor {
    pub fn encode(&self) -> String {
        // Foundation JSONEncoder escapes slashes, including in historical IDs.
        let json = serde_json::to_string(self).expect("cursor consists of an integer and string");
        URL_SAFE_NO_PAD.encode(json.replace('/', r"\/"))
    }

    fn parse(raw: &str) -> Result<Self> {
        if raw.is_empty() || raw.len() > 512 {
            return Err(Error::Invalid);
        }
        let bytes = URL_SAFE_NO_PAD.decode(raw).map_err(|_| Error::Invalid)?;
        let cursor: Self = serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)?;
        if !(3..=260).contains(&cursor.id.len())
            || !(cursor.id.starts_with("a:") || cursor.id.starts_with("r:"))
            || cursor.id.contains('\0')
            || cursor.encode() != raw
        {
            return Err(Error::Invalid);
        }
        Ok(cursor)
    }
}

#[derive(Default)]
pub(crate) struct Query {
    pub start: i64,
    pub end: i64,
    pub key: Option<String>,
    pub model: Option<String>,
    pub mode: Option<String>,
    pub failure: Option<String>,
    pub state: Option<String>,
    pub effort: Option<String>,
    pub failed_only: bool,
    pub rejected_only: bool,
    pub failed_outcome: bool,
    pub rejection_group: Option<(String, Option<String>)>,
    pub cursor: Option<Cursor>,
    pub limit: usize,
}

impl Query {
    pub fn window(
        start: i64,
        end: i64,
        key: Option<String>,
        model: Option<String>,
    ) -> Result<Self> {
        let valid_identifier =
            |value: &str, max| !value.is_empty() && value.len() <= max && !value.contains('\0');
        if start < 0
            || end <= start
            || end > 1_000_000_000_000
            || end - start > 31 * DAY
            || start % 3600 != 0
            || end % 3600 != 0
            || key
                .as_deref()
                .is_some_and(|value| !valid_identifier(value, 256))
            || model
                .as_deref()
                .is_some_and(|value| !valid_identifier(value, 128))
        {
            return Err(Error::Invalid);
        }
        Ok(Self {
            start,
            end,
            key,
            model,
            ..Self::default()
        })
    }

    pub fn parse(query: Option<&str>) -> Result<Self> {
        let mut values = parameters(
            query,
            &[
                "start",
                "end",
                "key",
                "model",
                "mode",
                "failure",
                "failedOnly",
                "state",
                "after",
                "limit",
                "reasoningEffort",
                "outcome",
                "rejectedOnly",
                "rejectionGroup",
            ],
        )?;
        let mut query = Self::window(
            number(&values, "start")?.ok_or(Error::Invalid)?,
            number(&values, "end")?.ok_or(Error::Invalid)?,
            values.remove("key"),
            values.remove("model"),
        )?;
        let mut checked = |key: &str, allowed: &[&str]| {
            let value = values.remove(key);
            if value
                .as_deref()
                .is_some_and(|value| !allowed.contains(&value))
            {
                return Err(Error::Invalid);
            }
            Ok(value)
        };
        query.mode = checked("mode", MODES)?;
        query.failure = checked("failure", FAILURES)?;
        query.state = checked("state", STATES)?;
        query.failed_outcome = checked("outcome", &["failed"])?.is_some();
        query.failed_only = boolean(&values, "failedOnly", false)?;
        query.rejected_only = boolean(&values, "rejectedOnly", false)?;
        query.effort = values.remove("reasoningEffort");
        if query
            .effort
            .as_deref()
            .is_some_and(|value| safe_metadata(value) != value)
        {
            return Err(Error::Invalid);
        }
        if let Some(group) = values.remove("rejectionGroup") {
            let (failure, reason) = group.split_once(':').ok_or(Error::Invalid)?;
            if !query.rejected_only
                || !FAILURES.contains(&failure)
                || (reason != "unrecorded" && rejection_stage(reason).is_none())
            {
                return Err(Error::Invalid);
            }
            query.rejection_group = Some((
                failure.to_owned(),
                (reason != "unrecorded").then(|| reason.to_owned()),
            ));
        }
        let limit = number(&values, "limit")?.unwrap_or(50);
        if !(1..=100).contains(&limit) {
            return Err(Error::Invalid);
        }
        query.limit = limit as usize;
        query.cursor = values
            .get("after")
            .map(|raw| Cursor::parse(raw))
            .transpose()?;
        if query
            .cursor
            .as_ref()
            .is_some_and(|cursor| !(query.start..query.end).contains(&cursor.at))
        {
            return Err(Error::Invalid);
        }
        Ok(query)
    }
}
