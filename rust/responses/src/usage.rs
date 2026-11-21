use crate::{JsonValue, ProtocolError, same_text, text};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rates {
    pub input_micros_per_million: i64,
    pub output_micros_per_million: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Completeness {
    Complete,
    Partial,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PriceCompleteness {
    Complete,
    Partial,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UsageEvidence {
    pub revision: u8,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cached_tokens: i64,
    pub images: i64,
    pub estimated_micros: i64,
    pub completeness: Completeness,
    pub image_input_tokens: Option<i64>,
    pub image_output_tokens: Option<i64>,
    pub image_input_text_tokens: Option<i64>,
    pub image_input_image_tokens: Option<i64>,
    pub svg_input_tokens: Option<i64>,
    pub svg_output_tokens: Option<i64>,
    pub svg_reasoning_tokens: Option<i64>,
    pub svg_author_model: Option<String>,
    pub price_completeness: Option<PriceCompleteness>,
    pub usage_missing_reasons: Vec<&'static str>,
    pub provider_rejected_before_output: bool,
}

impl UsageEvidence {
    fn host(
        input_tokens: i64,
        output_tokens: i64,
        cached_tokens: i64,
        estimated_micros: i64,
        completeness: Completeness,
    ) -> Self {
        Self {
            revision: 1,
            input_tokens,
            output_tokens,
            cached_tokens,
            images: 0,
            estimated_micros,
            completeness,
            image_input_tokens: None,
            image_output_tokens: None,
            image_input_text_tokens: None,
            image_input_image_tokens: None,
            svg_input_tokens: None,
            svg_output_tokens: None,
            svg_reasoning_tokens: None,
            svg_author_model: None,
            price_completeness: None,
            usage_missing_reasons: vec![],
            provider_rejected_before_output: false,
        }
    }

    /// Zero usage for an explicitly rejected request with no possible provider processing.
    pub fn provider_rejection(images: bool) -> Self {
        let image_zero = images.then_some(0);
        Self {
            provider_rejected_before_output: true,
            image_input_tokens: image_zero,
            image_output_tokens: image_zero,
            image_input_text_tokens: image_zero,
            image_input_image_tokens: image_zero,
            ..Self::host(0, 0, 0, 0, Completeness::Complete)
        }
    }
}

fn count(value: Option<&JsonValue>) -> Option<i64> {
    value?.as_i64().filter(|n| (0..=1_000_000_000).contains(n))
}

pub fn text_usage(value: Option<&JsonValue>, rates: Rates) -> Option<UsageEvidence> {
    let usage = value?;
    let input = count(usage.get("input_tokens"));
    let output = count(usage.get("output_tokens"));
    let cached = count(
        usage
            .get("input_tokens_details")
            .and_then(|v| v.get("cached_tokens")),
    )
    .filter(|&cached| input.is_none_or(|input| cached <= input));
    if input.is_none() && output.is_none() && cached.is_none() {
        return None;
    }
    let input_tokens = input.unwrap_or_default().max(cached.unwrap_or_default());
    let output_tokens = output.unwrap_or_default();
    let raw_cost = input_tokens
        .checked_mul(rates.input_micros_per_million)?
        .checked_add(output_tokens.checked_mul(rates.output_micros_per_million)?)?;
    Some(UsageEvidence::host(
        input_tokens,
        output_tokens,
        cached.unwrap_or_default(),
        ceil_micros(raw_cost),
        if input.is_some() && output.is_some() && cached.is_some() {
            Completeness::Complete
        } else {
            Completeness::Partial
        },
    ))
}

#[derive(Clone, Copy, Debug)]
pub struct ImageUsageConfig<'a> {
    pub rates: Rates,
    pub expects_svg: bool,
    pub author_rates: &'a [(&'a str, Rates)],
}

#[derive(Clone, Copy, Debug, Default)]
pub struct UsageConfig<'a> {
    pub host: Rates,
    pub image: Option<ImageUsageConfig<'a>>,
}

impl UsageConfig<'_> {
    pub(crate) fn observe(
        self,
        document: Option<&JsonValue>,
        evidence: &mut Vec<UsageEvidence>,
    ) -> Result<(), ProtocolError> {
        let host = text_usage(document.and_then(|v| v.get("usage")), self.host);
        let Some(image) = self.image else {
            evidence.extend(host);
            return Ok(());
        };
        if let Some(host) = &host {
            evidence.push(UsageEvidence {
                revision: 0,
                completeness: Completeness::Partial,
                ..host.clone()
            });
        }
        evidence.push(combined_usage(document, host, image)?);
        Ok(())
    }
}

fn combined_usage(
    document: Option<&JsonValue>,
    host: Option<UsageEvidence>,
    configuration: ImageUsageConfig<'_>,
) -> Result<UsageEvidence, ProtocolError> {
    let output = document
        .and_then(|v| v.get("output"))
        .and_then(JsonValue::as_array);
    let items: Vec<_> = output
        .into_iter()
        .flatten()
        .filter(|item| text(item, "type") == Some("image_generation_call"))
        .take(17)
        .collect();
    if items.len() > 16 {
        return Err(ProtocolError::new(502, "upstream_output_too_large"));
    }
    let known_items = output.is_some_and(|items| {
        items.iter().all(|item| {
            matches!(
                text(item, "type"),
                Some(
                    "message"
                        | "reasoning"
                        | "function_call"
                        | "custom_tool_call"
                        | "image_generation_call"
                )
            )
        })
    }) && (!items.is_empty()
        || document.and_then(|v| text(v, "status")) == Some("completed"));
    let expected_svg = !items.is_empty()
        && (configuration.expects_svg
            || document.and_then(|v| text(v, "output_format")) == Some("svg")
            || items
                .iter()
                .any(|item| text(item, "output_format") == Some("svg")));
    let author = svg_usage(document, &items, expected_svg, configuration.author_rates);
    let mut image_input = (known_items && items.is_empty()).then_some(0);
    let mut image_output = image_input;
    let mut complete_input = known_items;
    let mut complete_output = known_items;
    let mut images = 0;
    for item in &items {
        let usage = item.get("usage");
        let input = count(usage.and_then(|usage| usage.get("input_tokens")));
        let output = count(usage.and_then(|usage| usage.get("output_tokens")));
        if let Some(input) = input {
            *image_input.get_or_insert(0) += input;
        }
        if let Some(output) = output {
            *image_output.get_or_insert(0) += output;
        }
        complete_input &= input.is_some();
        complete_output &= output.is_some();
        if text(item, "status") == Some("completed") && text(item, "result").is_some() {
            images += 1;
        }
    }
    let rendering = image_cost(image_input, image_output, configuration.rates);
    let complete_usage = complete_input
        && complete_output
        && host
            .as_ref()
            .is_some_and(|usage| usage.completeness == Completeness::Complete)
        && author.complete;
    let total = host
        .as_ref()
        .map_or(0, |usage| usage.estimated_micros)
        .saturating_add(rendering.unwrap_or_default())
        .saturating_add(author.cost.unwrap_or_default());
    let complete_price = complete_usage
        && total <= MAX_COST
        && rendering.is_some_and(|cost| cost < MAX_COST)
        && author.cost.is_some_and(|cost| cost < MAX_COST);
    let price = if complete_price {
        PriceCompleteness::Complete
    } else if host.is_some() || rendering.is_some() || (author.present && author.cost.is_some()) {
        PriceCompleteness::Partial
    } else {
        PriceCompleteness::Unavailable
    };
    Ok(UsageEvidence {
        completeness: if complete_usage && images as usize == items.len() {
            Completeness::Complete
        } else {
            Completeness::Partial
        },
        estimated_micros: total.min(MAX_COST),
        images,
        image_input_tokens: image_input,
        image_output_tokens: image_output,
        svg_input_tokens: author.input,
        svg_output_tokens: author.output,
        svg_reasoning_tokens: author.reasoning,
        svg_author_model: author.model,
        price_completeness: Some(price),
        usage_missing_reasons: author.reasons,
        ..host.unwrap_or_else(|| UsageEvidence::host(0, 0, 0, 0, Completeness::Partial))
    })
}

struct SvgEvidence {
    input: Option<i64>,
    output: Option<i64>,
    reasoning: Option<i64>,
    model: Option<String>,
    cost: Option<i64>,
    reasons: Vec<&'static str>,
    present: bool,
    complete: bool,
}

fn svg_usage(
    response: Option<&JsonValue>,
    items: &[&JsonValue],
    expected: bool,
    models: &[(&str, Rates)],
) -> SvgEvidence {
    let root = response
        .and_then(|v| v.get("svg_usage"))
        .filter(|&v| v != &JsonValue::Null);
    let entries: Vec<_> = if let Some(root) = root {
        vec![root]
    } else {
        items
            .iter()
            .filter_map(|item| item.get("svg_usage"))
            .filter(|&v| v != &JsonValue::Null)
            .collect()
    };
    let present = expected || !entries.is_empty();
    let ambiguous = entries.len() > 1
        || (root.is_none() && items.len() > 1 && !entries.is_empty())
        || entries
            .iter()
            .any(|v| v.get("_ambiguous") == Some(&JsonValue::Bool(true)));
    let max = |name| {
        entries
            .iter()
            .filter_map(|entry| count(entry.get(name)))
            .max()
    };
    let input = max("input_tokens");
    let output = max("output_tokens");
    let reasoning = max("reasoning_tokens").filter(|n| output.is_some_and(|o| *n <= o));
    let mut names = entries
        .iter()
        .filter_map(|entry| text(entry, "model"))
        .filter(|name| {
            (1..=128).contains(&name.len())
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-./:_".contains(&b))
        });
    let model = names
        .next()
        .filter(|first| names.all(|name| name == *first));
    let consistent = entries.iter().all(|entry| {
        let Some(total) = entry.get("total_tokens").filter(|&v| v != &JsonValue::Null) else {
            return true;
        };
        match (
            count(entry.get("input_tokens")),
            count(entry.get("output_tokens")),
        ) {
            (Some(i), Some(o)) => total.as_i64() == Some(i + o),
            _ => false,
        }
    });
    let cost = if !present {
        Some(0)
    } else {
        model
            .and_then(|name| models.iter().find(|(id, _)| same_text(name, id)))
            .and_then(|(_, rates)| image_cost(input, output, *rates))
    };
    let reasons = [
        (present && input.is_none(), "svg_input_unavailable"),
        (present && output.is_none(), "svg_output_unavailable"),
        (ambiguous, "svg_usage_ambiguous"),
        (!consistent, "svg_total_inconsistent"),
        (present && cost.is_none(), "svg_price_unavailable"),
    ]
    .into_iter()
    .filter_map(|(missing, reason)| missing.then_some(reason))
    .collect();
    SvgEvidence {
        input,
        output,
        reasoning,
        model: model.map(str::to_owned),
        cost,
        reasons,
        present,
        complete: !present
            || (entries.len() == 1
                && !ambiguous
                && input.is_some()
                && output.is_some()
                && consistent),
    }
}

const MAX_COST: i64 = 1_000_000_000_000;

fn ceil_micros(raw: i64) -> i64 {
    raw / 1_000_000 + i64::from(raw % 1_000_000 != 0)
}

fn image_cost(input: Option<i64>, output: Option<i64>, rates: Rates) -> Option<i64> {
    if input.is_none() && output.is_none() {
        return None;
    }
    let raw = i128::from(input.unwrap_or_default()) * i128::from(rates.input_micros_per_million)
        + i128::from(output.unwrap_or_default()) * i128::from(rates.output_micros_per_million);
    let rounded = raw / 1_000_000 + i128::from(raw % 1_000_000 > 0);
    (rounded >= 0).then(|| rounded.min(i128::from(MAX_COST)) as i64)
}
