use codexone_http_upstream::Instant;
use codexone_wire::{JsonObject, JsonValue};

use crate::{metadata, payload::canonical_base64};

const COST_LIMIT: u64 = 1_000_000_000_000;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TokenRates {
    pub input_micros_per_million: u64,
    pub output_micros_per_million: u64,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ImageRates<'a> {
    pub render: TokenRates,
    pub authors: &'a [(&'a str, TokenRates)],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UsageCompleteness {
    Complete,
    Partial,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PriceCompleteness {
    Complete,
    Partial,
    Unavailable,
}

/// Validated native Images ledger fields. No Responses text tokens are attributed here.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UsageEvidence {
    pub revision: u64,
    pub images: u64,
    pub image_input_tokens: Option<u64>,
    pub image_output_tokens: Option<u64>,
    pub image_input_text_tokens: Option<u64>,
    pub image_input_image_tokens: Option<u64>,
    pub svg_input_tokens: Option<u64>,
    pub svg_output_tokens: Option<u64>,
    pub svg_reasoning_tokens: Option<u64>,
    pub svg_author_model: Option<String>,
    pub estimated_micros: u64,
    pub completeness: UsageCompleteness,
    pub price_completeness: PriceCompleteness,
    pub missing_reasons: Vec<&'static str>,
    pub provider_rejected_before_output: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ImageEvidence {
    pub usage: Option<UsageEvidence>,
    pub actual_service_tier: Option<String>,
    /// A parsed provider application document/event arrived.
    pub observed_application: bool,
    /// Parse time of the first SSE application event, or receipt of the complete JSON body.
    pub first_event_at: Option<Instant>,
    /// The upstream body ended with a valid result. Delivery still belongs to the caller.
    pub completed: bool,
    /// The legacy edit compatibility path delivered raw bytes without a valid image result.
    pub invalid_legacy_result: bool,
}

impl ImageEvidence {
    pub(crate) fn record_rejection(&mut self) {
        self.usage = Some(UsageEvidence {
            revision: 1,
            images: 0,
            image_input_tokens: Some(0),
            image_output_tokens: Some(0),
            image_input_text_tokens: Some(0),
            image_input_image_tokens: Some(0),
            svg_input_tokens: None,
            svg_output_tokens: None,
            svg_reasoning_tokens: None,
            svg_author_model: None,
            estimated_micros: 0,
            completeness: UsageCompleteness::Complete,
            price_completeness: PriceCompleteness::Complete,
            missing_reasons: Vec::new(),
            provider_rejected_before_output: true,
        });
    }

    pub(crate) fn observe_tier(&mut self, document: &JsonValue) {
        if let Some(service_tier) = metadata(document.get("service_tier")) {
            self.actual_service_tier = Some(service_tier);
        }
    }
}

pub(crate) struct Pricing<'a> {
    pub rates: ImageRates<'a>,
    pub expects_svg: bool,
}

pub(crate) struct Counters {
    pub images: u64,
    pub has_svg: bool,
    pub settled_status: bool,
}

impl Counters {
    pub(crate) fn read(document: &JsonValue, event: bool) -> (&[JsonValue], Self) {
        let items = document
            .get("data")
            .and_then(JsonValue::as_array)
            .unwrap_or_else(|| {
                if event {
                    std::slice::from_ref(document)
                } else {
                    &[]
                }
            });
        let images = items
            .iter()
            .filter(|item| {
                item.get("b64_json")
                    .and_then(JsonValue::as_str)
                    .is_some_and(canonical_base64)
            })
            .count() as u64;
        let has_svg = is_svg(document) || items.iter().any(is_svg);
        let status = document.get("status");
        let settled_status = status.is_none()
            || matches!(
                status.and_then(JsonValue::as_str),
                Some("completed" | "failed" | "cancelled")
            );
        (
            items,
            Self {
                images,
                has_svg,
                settled_status,
            },
        )
    }

    pub(crate) fn evidence(
        &self,
        revision: u64,
        usage: Option<&JsonObject>,
        author: &AuthorEvidence,
        pricing: &Pricing<'_>,
        provisional: bool,
    ) -> UsageEvidence {
        let input = count(usage.and_then(|usage| usage.get("input_tokens")));
        let output = count(usage.and_then(|usage| usage.get("output_tokens")));
        let details = usage.and_then(|value| value.get("input_tokens_details"));
        let render = cost(input, output, pricing.rates.render);
        let author_cost = if author.present {
            pricing
                .rates
                .authors
                .iter()
                .find(|(id, _)| Some(*id) == author.model.as_deref())
                .and_then(|(_, rates)| cost(author.input, author.output, *rates))
        } else {
            Some(0)
        };
        let sum = render.unwrap_or(0) + author_cost.unwrap_or(0);
        let complete = !provisional
            && input.is_some()
            && output.is_some()
            && author.complete()
            && self.settled_status;
        let price_completeness = if !provisional
            && input.is_some()
            && output.is_some()
            && render.is_some_and(|cost| cost < COST_LIMIT)
            && author.complete()
            && author_cost.is_some_and(|cost| cost < COST_LIMIT)
            && sum <= COST_LIMIT
        {
            PriceCompleteness::Complete
        } else if render.is_some() || (author.present && author_cost.is_some()) {
            PriceCompleteness::Partial
        } else {
            PriceCompleteness::Unavailable
        };
        let mut missing_reasons = Vec::new();
        if author.present && author.input.is_none() {
            missing_reasons.push("svg_input_unavailable");
        }
        if author.present && author.output.is_none() {
            missing_reasons.push("svg_output_unavailable");
        }
        if author.ambiguous {
            missing_reasons.push("svg_usage_ambiguous");
        }
        if !author.consistent_total {
            missing_reasons.push("svg_total_inconsistent");
        }
        if author.present && author_cost.is_none() {
            missing_reasons.push("svg_price_unavailable");
        }
        UsageEvidence {
            revision,
            images: self.images,
            image_input_tokens: input,
            image_output_tokens: output,
            image_input_text_tokens: member(details, "text_tokens"),
            image_input_image_tokens: member(details, "image_tokens"),
            svg_input_tokens: author.input,
            svg_output_tokens: author.output,
            svg_reasoning_tokens: author.reasoning,
            svg_author_model: author.model.clone(),
            estimated_micros: sum.min(COST_LIMIT),
            completeness: if complete {
                UsageCompleteness::Complete
            } else {
                UsageCompleteness::Partial
            },
            price_completeness,
            missing_reasons,
            provider_rejected_before_output: false,
        }
    }
}

fn is_svg(document: &JsonValue) -> bool {
    document.get("output_format").and_then(JsonValue::as_str) == Some("svg")
}

fn member(object: Option<&JsonValue>, key: &str) -> Option<u64> {
    count(object?.get(key))
}

fn count(value: Option<&JsonValue>) -> Option<u64> {
    let value = value?.as_i64()?;
    (0..=1_000_000_000).contains(&value).then_some(value as u64)
}

fn cost(input: Option<u64>, output: Option<u64>, rates: TokenRates) -> Option<u64> {
    if input.is_none() && output.is_none() {
        return None;
    }
    let numerator = u128::from(input.unwrap_or(0)) * u128::from(rates.input_micros_per_million)
        + u128::from(output.unwrap_or(0)) * u128::from(rates.output_micros_per_million);
    Some(numerator.div_ceil(1_000_000).min(u128::from(COST_LIMIT)) as u64)
}

#[derive(Default)]
pub(crate) struct StreamUsage {
    render: JsonObject,
    author: Option<AuthorEvidence>,
    counters: Option<Counters>,
    item_author: Option<AuthorEvidence>,
    item_count: usize,
    revision: u64,
}

impl StreamUsage {
    pub(crate) fn observe(
        &mut self,
        event: &JsonValue,
        duplicate: bool,
        pricing: &Pricing<'_>,
    ) -> UsageEvidence {
        self.revision += 1;
        let (items, mut counters) = Counters::read(event, true);
        let previous = self.counters.as_ref();
        counters.images =
            previous.map_or(0, |state| state.images) + if duplicate { 0 } else { counters.images };
        counters.has_svg |= previous.is_some_and(|state| state.has_svg);
        merge_render(
            &mut self.render,
            event.get("usage").and_then(JsonValue::as_object),
        );
        if let Some(root) = event
            .get("svg_usage")
            .filter(|value| **value != JsonValue::Null)
        {
            let author = AuthorEvidence::read(Some(root), &[], true);
            if let Some(previous) = &mut self.author {
                previous.merge(author);
            } else {
                self.author = Some(author.into_snapshot());
            }
        } else if self.author.is_none() {
            if !duplicate {
                self.item_count += items.len();
            }
            let next = AuthorEvidence::read(None, items, false);
            if next.present {
                if let Some(previous) = &mut self.item_author {
                    previous.merge_items(next);
                } else {
                    self.item_author = Some(next);
                }
            }
            if let Some(previous) = &mut self.item_author {
                previous.ambiguous |= self.item_count > 1;
            }
        }
        self.counters = Some(counters);
        self.evidence(pricing, true)
            .expect("completion evidence exists")
    }

    pub(crate) fn finish(&mut self, pricing: &Pricing<'_>) -> Option<UsageEvidence> {
        self.revision += 1;
        self.evidence(pricing, false)
    }

    pub(crate) fn take_render(&mut self) -> Option<JsonValue> {
        (!self.render.is_empty()).then(|| JsonValue::Object(std::mem::take(&mut self.render)))
    }

    fn evidence(&self, pricing: &Pricing<'_>, provisional: bool) -> Option<UsageEvidence> {
        let counters = self.counters.as_ref()?;
        let missing = AuthorEvidence::read(None, &[], pricing.expects_svg || counters.has_svg);
        let author = self
            .author
            .as_ref()
            .or(self.item_author.as_ref())
            .unwrap_or(&missing);
        Some(counters.evidence(
            self.revision,
            Some(&self.render),
            author,
            pricing,
            provisional,
        ))
    }
}

fn merge_render(previous: &mut JsonObject, next: Option<&JsonObject>) {
    let Some(next) = next else {
        return;
    };
    merge_fields(
        previous,
        next,
        &["input_tokens", "output_tokens"],
        Some("input_tokens_details"),
    );
    if let Some(value) = next.get("input_tokens_details") {
        if previous.get("input_tokens_details").is_none() {
            previous.insert("input_tokens_details", JsonValue::Object(JsonObject::new()));
        }
        let details = previous
            .get_mut("input_tokens_details")
            .and_then(JsonValue::as_object_mut)
            .expect("merged input details are an object");
        if let Some(new) = value.as_object() {
            merge_fields(details, new, &["text_tokens", "image_tokens"], None);
        }
    }
}

fn merge_fields(
    previous: &mut JsonObject,
    next: &JsonObject,
    counters: &[&str],
    nested: Option<&str>,
) {
    for (key, value) in next.iter() {
        if !counters.contains(&key) && nested != Some(key) {
            previous.insert(key, value.clone());
        }
    }
    for &key in counters {
        if let Some(value) = next
            .get(key)
            .and_then(JsonValue::as_i64)
            .filter(|count| (0..=1_000_000_000).contains(count))
        {
            let old = previous.get(key).and_then(JsonValue::as_i64).unwrap_or(0);
            previous.insert(key, JsonValue::Number(value.max(old).into()));
        }
    }
}

#[derive(Clone)]
pub(crate) struct AuthorEvidence {
    input: Option<u64>,
    output: Option<u64>,
    raw_reasoning: Option<u64>,
    reasoning: Option<u64>,
    model: Option<String>,
    present: bool,
    ambiguous: bool,
    consistent_total: bool,
    model_conflict: bool,
}

impl AuthorEvidence {
    pub(crate) fn read(root: Option<&JsonValue>, items: &[JsonValue], expected: bool) -> Self {
        let root = root.filter(|value| **value != JsonValue::Null);
        let mut entries = items
            .iter()
            .filter_map(|item| item.get("svg_usage"))
            .filter(|usage| **usage != JsonValue::Null);
        let mut author = Self {
            input: None,
            output: None,
            raw_reasoning: None,
            reasoning: None,
            model: None,
            present: expected,
            ambiguous: false,
            consistent_total: true,
            model_conflict: false,
        };
        let mut seen = false;
        let mut next = || if root.is_some() { None } else { entries.next() };
        let mut entry = root.or_else(&mut next);
        while let Some(usage) = entry {
            author.present = true;
            author.ambiguous |= seen
                || (root.is_none() && items.len() > 1)
                || usage.get("_ambiguous").and_then(JsonValue::as_bool) == Some(true);
            seen = true;
            let input = member(Some(usage), "input_tokens");
            let output = member(Some(usage), "output_tokens");
            author.input = author.input.max(input);
            author.output = author.output.max(output);
            author.raw_reasoning = author
                .raw_reasoning
                .max(member(Some(usage), "reasoning_tokens"));
            if let Some(name) = usage
                .get("model")
                .and_then(JsonValue::as_str)
                .filter(|name| {
                    (1..=128).contains(&name.len())
                        && name
                            .bytes()
                            .all(|byte| byte.is_ascii_alphanumeric() || b"-./:_".contains(&byte))
                })
            {
                author.model_conflict |= author
                    .model
                    .as_deref()
                    .is_some_and(|previous| previous != name);
                author.model.get_or_insert_with(|| name.to_owned());
            }
            if let Some(total) = usage
                .get("total_tokens")
                .filter(|total| **total != JsonValue::Null)
            {
                author.consistent_total &= input
                    .zip(output)
                    .is_some_and(|(i, o)| total.as_i64() == Some((i + o) as i64));
            }
            entry = next();
        }
        if author.model_conflict {
            author.model = None;
        }
        author.reasoning = author
            .raw_reasoning
            .filter(|reasoning| author.output.is_some_and(|output| *reasoning <= output));
        author
    }

    fn into_snapshot(mut self) -> Self {
        self.ambiguous |= !self.consistent_total;
        self.consistent_total = true;
        self.raw_reasoning = self.reasoning;
        self
    }

    fn merge(&mut self, next: Self) {
        if self.model.is_some() && next.model.is_some() && self.model != next.model {
            self.ambiguous = true;
            return;
        }
        self.input = self.input.max(next.input);
        self.output = self.output.max(next.output);
        self.reasoning = self.reasoning.max(next.reasoning);
        if self.model.is_none() {
            self.model = next.model;
        }
        self.ambiguous |= !next.consistent_total;
    }

    fn merge_items(&mut self, next: Self) {
        self.input = self.input.max(next.input);
        self.output = self.output.max(next.output);
        self.raw_reasoning = self.raw_reasoning.max(next.raw_reasoning);
        self.reasoning = self
            .raw_reasoning
            .filter(|value| self.output.is_some_and(|output| *value <= output));
        self.consistent_total &= next.consistent_total;
        self.ambiguous |= next.ambiguous;
        self.model_conflict |= next.model_conflict
            || (self.model.is_some() && next.model.is_some() && self.model != next.model);
        self.model = if self.model_conflict {
            None
        } else {
            self.model.take().or(next.model)
        };
    }

    fn complete(&self) -> bool {
        !self.present
            || (!self.ambiguous
                && self.input.is_some()
                && self.output.is_some()
                && self.consistent_total)
    }
}
