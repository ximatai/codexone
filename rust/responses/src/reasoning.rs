use crate::{BindingKind, JsonValue, Mode, ProtocolError, Request, text};

const EFFORTS: [&str; 8] = [
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
];

const DENIED: ProtocolError = ProtocolError::new(403, "reasoning_effort_not_allowed");
const CONTEXT_UNAVAILABLE: ProtocolError =
    DENIED.with_detail("reasoning_effort_context_unavailable");
const INVALID_UPDATE: ProtocolError = DENIED.with_detail("reasoning_effort_update_invalid");

/// Complete, bounded facts about a response context. No request items are retained.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ReasoningContext {
    seen: u8,
    baseline: Option<&'static str>,
    last_update: Option<&'static str>,
}

impl ReasoningContext {
    pub fn efforts(self) -> impl Iterator<Item = &'static str> {
        EFFORTS
            .into_iter()
            .enumerate()
            .filter(move |(index, _)| self.seen & (1 << index) != 0)
            .map(|(_, effort)| effort)
    }

    pub fn selected(self) -> Option<&'static str> {
        self.last_update.or(self.baseline)
    }

    fn include(&mut self, value: &str) -> Result<&'static str, ProtocolError> {
        let index = effort_index(value).ok_or(DENIED)?;
        self.seen |= 1 << index;
        Ok(EFFORTS[index])
    }
}

fn effort_index(value: &str) -> Option<usize> {
    EFFORTS.iter().position(|&effort| effort == value)
}

pub(crate) fn evaluate(
    request: &Request,
    previous: Option<ReasoningContext>,
    model_efforts: &[&str],
    model_restricted: bool,
    key_efforts: Option<&[&str]>,
) -> Result<Option<ReasoningContext>, ProtocolError> {
    let facts = context(request, previous);
    if !model_restricted && key_efforts.is_none() {
        return Ok(facts.ok());
    }
    let facts = facts?;
    if facts.efforts().any(|effort| {
        !model_efforts.contains(&effort) || key_efforts.is_some_and(|key| !key.contains(&effort))
    }) {
        return Err(DENIED);
    }
    Ok(Some(facts))
}

fn context(
    request: &Request,
    previous: Option<ReasoningContext>,
) -> Result<ReasoningContext, ProtocolError> {
    let document = request.document();
    if document.get("reasoning_effort").is_some() {
        return Err(DENIED);
    }
    let top = match document.get("reasoning") {
        None | Some(JsonValue::Null) => None,
        Some(JsonValue::Object(reasoning)) => reasoning.get("effort"),
        _ => return Err(DENIED),
    };
    let top = match top {
        Some(value) => Some(value.as_str().ok_or(DENIED)?),
        None if request.mode == Mode::Warmup && request.reasoning_effort.is_none() => None,
        None => return Err(DENIED),
    };
    if request
        .references
        .iter()
        .any(|reference| reference.kind != BindingKind::Response)
    {
        return Err(CONTEXT_UNAVAILABLE);
    }
    let mut facts = if request.previous_response_id().is_some() {
        previous.ok_or(CONTEXT_UNAVAILABLE)?
    } else {
        ReasoningContext::default()
    };
    facts.baseline = top.map(|top| facts.include(top)).transpose()?;
    let items = match document.get("input") {
        Some(JsonValue::Array(items)) => items.as_slice(),
        Some(JsonValue::String(_)) => &[],
        _ => return Err(CONTEXT_UNAVAILABLE),
    };
    for item in items {
        match text(item, "type") {
            Some("configuration_update") => {
                let item = item.as_object().ok_or(INVALID_UPDATE)?;
                let reasoning = item
                    .get("reasoning")
                    .and_then(JsonValue::as_object)
                    .ok_or(INVALID_UPDATE)?;
                if item.len() != 2 || reasoning.len() != 1 {
                    return Err(INVALID_UPDATE);
                }
                let effort = reasoning
                    .get("effort")
                    .and_then(JsonValue::as_str)
                    .ok_or(INVALID_UPDATE)?;
                facts.last_update = Some(facts.include(effort).map_err(|_| INVALID_UPDATE)?);
            }
            Some("compaction") => {
                return Err(CONTEXT_UNAVAILABLE);
            }
            _ => {}
        }
    }
    Ok(facts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ModelPolicy;

    const ALL: &[&str] = &["low", "medium", "high"];

    fn policy<'a>(allowed: Option<&'a [&'a str]>) -> ModelPolicy<'a> {
        ModelPolicy {
            id: "synthetic",
            vision_input: false,
            image_generation: false,
            effective_image_models: &[],
            effective_reasoning_efforts: ALL,
            restrict_reasoning_effort: false,
            key_reasoning_efforts: allowed,
        }
    }

    fn request(top: &str, input: &str, previous: bool, mode: Mode) -> Request {
        let top = if top.is_empty() {
            String::new()
        } else {
            format!(r#","reasoning":{{"effort":"{top}"}}"#)
        };
        let previous = if previous {
            r#","previous_response_id":"synthetic-response""#
        } else {
            ""
        };
        let body = format!(r#"{{"model":"synthetic","input":{input}{top}{previous}}}"#);
        Request::parse(body.as_bytes(), mode, None).unwrap()
    }

    #[test]
    fn ordered_updates_and_retained_history_require_current_authorization() {
        let first = request(
            "low",
            r#"[
            {"type":"configuration_update","reasoning":{"effort":"high"}},
            {"type":"configuration_update","reasoning":{"effort":"medium"}}
        ]"#,
            false,
            Mode::Generation,
        );
        let facts = policy(Some(ALL)).validate(&first, None).unwrap().unwrap();
        assert_eq!(facts.selected(), Some("medium"));
        assert_eq!(facts.efforts().collect::<Vec<_>>(), ALL);
        let reduced = policy(Some(&["low", "medium"]));
        assert_eq!(reduced.validate(&first, None), Err(DENIED));

        let continuation = request("low", "[]", true, Mode::Generation);
        let inherited = policy(Some(ALL))
            .validate(&continuation, Some(facts))
            .unwrap()
            .unwrap();
        assert_eq!(inherited.selected(), Some("medium"));
        assert_eq!(reduced.validate(&continuation, Some(facts)), Err(DENIED));
        assert_eq!(
            reduced.validate(&continuation, None).unwrap_err().detail,
            Some("reasoning_effort_context_unavailable")
        );

        let fresh = request("low", r#""synthetic""#, false, Mode::Generation);
        let facts = reduced.validate(&fresh, Some(facts)).unwrap().unwrap();
        assert_eq!(facts.selected(), Some("low"));
        assert_eq!(facts.efforts().collect::<Vec<_>>(), ["low"]);
    }

    #[test]
    fn restricted_turns_fail_closed_on_incomplete_or_unrecognized_facts() {
        let restricted = policy(Some(ALL));
        for input in [
            r#"[{"type":"configuration_update","reasoning":{"effort":"low"},"unknown":true}]"#,
            r#"[{"type":"configuration_update","reasoning":{"effort":"unknown"}}]"#,
            r#"[{"type":"configuration_update","reasoning":{"effort":null}}]"#,
            r#"[{"type":"item_reference","id":"synthetic-item"}]"#,
            r#"[{"type":"compaction","encrypted_content":"synthetic"}]"#,
        ] {
            let request = request("low", input, false, Mode::Generation);
            let original = request.document().clone();
            assert_eq!(
                restricted.validate(&request, None).unwrap_err().code,
                DENIED.code
            );
            assert_eq!(policy(None).validate(&request, None), Ok(None));
            assert_eq!(request.document(), &original);
        }
        let extension = request(
            "low",
            r#"[{"type":"synthetic_extension","unknown":true}]"#,
            false,
            Mode::Generation,
        );
        assert!(restricted.validate(&extension, None).unwrap().is_some());
        let missing = request("", "[]", false, Mode::Generation);
        assert_eq!(restricted.validate(&missing, None), Err(DENIED));

        let explicit_directory = ModelPolicy {
            restrict_reasoning_effort: true,
            ..policy(None)
        };
        let wrong_level = request("xhigh", "[]", false, Mode::Generation);
        assert_eq!(explicit_directory.validate(&wrong_level, None), Err(DENIED));
    }

    #[test]
    fn warmup_can_establish_empty_facts_but_cannot_skip_the_effort_policy() {
        let policy = policy(Some(&["low"]));
        let prewarm = request("", "[]", false, Mode::Warmup);
        let facts = policy.validate(&prewarm, None).unwrap().unwrap();
        assert_eq!(facts.efforts().count(), 0);
        let next = request("low", "[]", true, Mode::Generation);
        assert_eq!(
            policy
                .validate(&next, Some(facts))
                .unwrap()
                .unwrap()
                .selected(),
            Some("low")
        );

        let update = request(
            "",
            r#"[{"type":"configuration_update","reasoning":{"effort":"high"}}]"#,
            false,
            Mode::Warmup,
        );
        assert_eq!(policy.validate(&update, None), Err(DENIED));
        let explicit = request("high", "[]", false, Mode::Warmup);
        assert_eq!(policy.validate(&explicit, None), Err(DENIED));
    }
}
