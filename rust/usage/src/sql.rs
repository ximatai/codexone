use rusqlite::{Connection, Row, params_from_iter, types::Value as SqlValue};
use serde_json::{Map, Value, json};

use crate::{DAY, Error, Result, query::Query};

pub const TEXT_INPUT: &str = "CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.inputTokens') END";
pub const TEXT_OUTPUT: &str = "CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.outputTokens') END";
const TEXT_CACHE: &str = "CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN NULL ELSE json_extract(usage_json,'$.cachedTokens') END";
pub const PRICE: &str = "CASE WHEN json_extract(usage_json,'$.priceCompleteness')='unavailable' THEN NULL
    WHEN json_extract(usage_json,'$.nativeImages')=1 AND json_extract(usage_json,'$.imageInputTokens') IS NULL
    AND json_extract(usage_json,'$.imageOutputTokens') IS NULL AND json_extract(usage_json,'$.svgInputTokens') IS NULL
    AND json_extract(usage_json,'$.svgOutputTokens') IS NULL THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END";
pub const PRICE_INCOMPLETE: &str = "CASE WHEN COALESCE(json_extract(usage_json,'$.priceCompleteness'),json_extract(usage_json,'$.completeness'),'unavailable')='complete' THEN 0 ELSE 1 END";

const METRIC_KEYS: [&str; 12] = [
    "inputTokens",
    "outputTokens",
    "cachedTokens",
    "images",
    "estimatedMicros",
    "imageInputTokens",
    "imageOutputTokens",
    "imageInputTextTokens",
    "imageInputImageTokens",
    "svgInputTokens",
    "svgOutputTokens",
    "svgReasoningTokens",
];

pub fn metric_columns(sum: bool) -> String {
    let mut fields: Vec<String> = METRIC_KEYS
        .iter()
        .map(|key| format!("json_extract(usage_json,'$.{key}')"))
        .collect();
    for (index, expression) in [
        (0, TEXT_INPUT),
        (1, TEXT_OUTPUT),
        (2, TEXT_CACHE),
        (4, PRICE),
    ] {
        fields[index] = expression.to_owned();
    }
    fields.push(PRICE_INCOMPLETE.to_owned());
    if sum {
        for field in &mut fields {
            *field = format!("SUM({field})");
        }
    }
    fields.join(",")
}

pub fn metrics(row: Option<&Row<'_>>, offset: usize) -> rusqlite::Result<Value> {
    let mut result = Map::new();
    for (index, key) in METRIC_KEYS.iter().enumerate() {
        result.insert(
            (*key).to_owned(),
            match row {
                Some(row) => json!(metric(row, offset + index)?),
                None => Value::Null,
            },
        );
    }
    let completeness = match row {
        None => None,
        Some(_) if result["estimatedMicros"].is_null() => Some("unavailable"),
        Some(row)
            if row
                .get::<_, Option<i64>>(offset + METRIC_KEYS.len())?
                .unwrap_or(0)
                > 0 =>
        {
            Some("partial")
        }
        Some(_) => Some("complete"),
    };
    result.insert("priceCompleteness".into(), json!(completeness));
    Ok(Value::Object(result))
}

pub fn metric(row: &Row<'_>, index: usize) -> rusqlite::Result<Option<String>> {
    let value: Option<i64> = row.get(index)?;
    if value.is_some_and(|value| value < 0) {
        return Err(rusqlite::Error::IntegralValueOutOfRange(
            index,
            value.unwrap(),
        ));
    }
    Ok(value.map(|value| value.to_string()))
}

pub fn rows<T>(
    db: &Connection,
    sql: &str,
    values: &[SqlValue],
    map: impl FnMut(&Row<'_>) -> rusqlite::Result<T>,
) -> Result<Vec<T>> {
    let mut statement = db.prepare(sql)?;
    Ok(statement
        .query_map(params_from_iter(values), map)?
        .collect::<rusqlite::Result<_>>()?)
}

#[derive(Default)]
pub struct Predicate {
    terms: Vec<&'static str>,
    pub values: Vec<SqlValue>,
}

impl Predicate {
    pub fn bind(&mut self, term: &'static str, value: impl Into<SqlValue>) {
        self.terms.push(term);
        self.values.push(value.into());
    }

    pub fn sql(&self) -> String {
        if self.terms.is_empty() {
            "1".into()
        } else {
            self.terms.join(" AND ")
        }
    }

    pub fn usage(query: &Query, diagnostic: bool, timed: bool, now: i64) -> Self {
        let mut p = Self::default();
        if diagnostic {
            p.bind("at_epoch>=?", now - 30 * DAY);
        } else if query.rejected_only {
            p.terms.push("0");
        }
        if timed {
            p.bind(
                if diagnostic {
                    "at_epoch>=?"
                } else {
                    "created_at_epoch>=?"
                },
                query.start,
            );
            p.bind(
                if diagnostic {
                    "at_epoch<?"
                } else {
                    "created_at_epoch<?"
                },
                query.end,
            );
        }
        for (value, admitted, rejected) in [
            (&query.key, "key_id=?", "key_id=?"),
            (
                &query.model,
                "json_extract(admission_json,'$.model')=?",
                "model=?",
            ),
            (
                &query.effort,
                "json_extract(admission_json,'$.reasoningEffort')=?",
                "reasoning_effort=?",
            ),
            (
                &query.mode,
                "COALESCE(json_extract(admission_json,'$.mode'),'generation')=?",
                "mode=?",
            ),
            (
                &query.failure,
                "json_extract(outcome_json,'$.failure')=?",
                "failure=?",
            ),
        ] {
            if let Some(value) = value {
                p.bind(if diagnostic { rejected } else { admitted }, value.clone());
            }
        }
        if diagnostic {
            if let Some((failure, reason)) = &query.rejection_group {
                p.bind("failure=?", failure.clone());
                if let Some(reason) = reason {
                    p.bind("reason=?", reason.clone());
                } else {
                    p.terms.push("reason IS NULL");
                }
            }
            if query.failed_outcome || query.state.is_some() {
                p.terms.push("0");
            }
        } else {
            if query.failed_outcome {
                p.terms.push("json_extract(outcome_json,'$.kind')='failed'");
            }
            if query.failed_only {
                p.terms
                    .push("json_extract(outcome_json,'$.failure') IS NOT NULL");
            }
            match query.state.as_deref() {
                Some("closed_unknown") => p.terms.push("closed_unknown_at_epoch IS NOT NULL"),
                Some(state) => {
                    p.bind("state=?", state.to_owned());
                    if state == "settled" {
                        p.terms.push("closed_unknown_at_epoch IS NULL");
                    }
                }
                None => {}
            }
        }
        p
    }
}

pub fn scalar(db: &Connection, sql: &str, values: &[SqlValue]) -> Result<i64> {
    Ok(db.query_row(sql, params_from_iter(values), |row| row.get(0))?)
}

pub fn bounded<T>(rows: Vec<T>, max: usize) -> Result<Vec<T>> {
    if rows.len() > max {
        Err(Error::Capacity)
    } else {
        Ok(rows)
    }
}
