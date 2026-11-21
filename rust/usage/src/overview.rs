use std::{collections::BTreeMap, sync::Arc};

use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::{BusinessDay, Context, DAY, Error, Result, Usage, daily_query, summary, validate_now};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OverviewSource {
    System,
    InFlight,
    Daily,
    Keys,
    Accounts,
    Storage,
    Attention,
    Headroom,
}

impl OverviewSource {
    const ALL: [Self; 8] = [
        Self::System,
        Self::InFlight,
        Self::Daily,
        Self::Keys,
        Self::Accounts,
        Self::Storage,
        Self::Attention,
        Self::Headroom,
    ];
    const USAGE: [Self; 4] = [Self::InFlight, Self::Daily, Self::Keys, Self::Headroom];
}

/// Sample once for all viewers. The transport can call this only while subscribed.
impl Usage {
    pub async fn sample_overview(
        &self,
        now: i64,
        context: Arc<Context>,
    ) -> Result<BTreeMap<OverviewSource, Result<Value>>> {
        validate_now(now)?;
        let day = self.day;
        self.reader
            .read(move |db| {
                let flight = activity(db, now, day, &context);
                let daily = daily_query(day, now, 7, None, None, None)
                    .and_then(|query| summary::daily(db, &query, day, now));
                let keys = summary::keys(db, now, day, false);
                let headroom = summary::headroom(db, now, day, &context);
                Ok(BTreeMap::from([
                    (OverviewSource::InFlight, flight),
                    (OverviewSource::Daily, daily),
                    (OverviewSource::Keys, keys),
                    (OverviewSource::Headroom, headroom),
                ]))
            })
            .await
    }
}

impl Usage {
    pub async fn sample_activity(&self, now: i64, context: Arc<Context>) -> Result<Value> {
        validate_now(now)?;
        let day = self.day;
        self.reader
            .read(move |db| activity(db, now, day, &context))
            .await
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OverviewSection {
    version: u64,
    sampled_at_unix_seconds: i64,
    last_success_at: Option<i64>,
    freshness: &'static str,
    code: Option<&'static str>,
    data: Value,
}

/// Per-viewer delivery metadata, without retaining older section payloads.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct OverviewStamp {
    version: u64,
    sampled_at: i64,
    last_success_at: Option<i64>,
    freshness: &'static str,
    code: Option<&'static str>,
}

impl OverviewSection {
    pub fn stamp(&self) -> OverviewStamp {
        OverviewStamp {
            version: self.version,
            sampled_at: self.sampled_at_unix_seconds,
            last_success_at: self.last_success_at,
            freshness: self.freshness,
            code: self.code,
        }
    }

    pub fn update_document(&self, previous: OverviewStamp) -> Result<Option<Value>> {
        if self.stamp() == previous {
            return Ok(None);
        }
        let mut document = serde_json::to_value(self).map_err(|_| Error::Unavailable)?;
        if self.version == previous.version {
            document
                .as_object_mut()
                .expect("section object")
                .remove("data");
        }
        Ok(Some(document))
    }

    fn unavailable(now: i64) -> Self {
        Self {
            version: 0,
            sampled_at_unix_seconds: now,
            last_success_at: None,
            freshness: "unavailable",
            code: Some("source_unavailable"),
            data: Value::Null,
        }
    }
}

/// Cache shared by the management runtime. Connection owners assign sequence
/// numbers when sending so coalescing does not consume a sequence number.
pub struct OverviewState {
    sections: BTreeMap<OverviewSource, OverviewSection>,
}

const MAX_SECTIONS_BYTES: usize = 1_048_000;

impl OverviewState {
    pub fn new(now: i64) -> Self {
        Self {
            sections: OverviewSource::ALL
                .into_iter()
                .map(|source| (source, OverviewSection::unavailable(now)))
                .collect(),
        }
    }

    pub fn snapshot(&self) -> &BTreeMap<OverviewSource, OverviewSection> {
        &self.sections
    }

    pub fn update_usage(
        &mut self,
        now: i64,
        results: Result<BTreeMap<OverviewSource, Result<Value>>>,
    ) -> Result<BTreeMap<OverviewSource, Value>> {
        let results = results.unwrap_or_else(|error| {
            OverviewSource::USAGE
                .into_iter()
                .map(|source| (source, Err(error)))
                .collect()
        });
        self.update(now, results)
    }

    /// Returns changed sections. Metadata-only updates omit the data member.
    pub fn update(
        &mut self,
        now: i64,
        results: BTreeMap<OverviewSource, Result<Value>>,
    ) -> Result<BTreeMap<OverviewSource, Value>> {
        validate_now(now)?;
        let mut next = self.sections.clone();
        let mut updates = BTreeMap::new();
        for (source, sample) in results {
            let old = &self.sections[&source];
            let section = next.get_mut(&source).expect("all sources initialized");
            section.sampled_at_unix_seconds = now;
            match sample {
                Ok(data) => {
                    if section.data != data {
                        section.version += 1;
                        section.data = data;
                    }
                    section.freshness = "fresh";
                    section.last_success_at = Some(now);
                    section.code = None;
                }
                Err(_) => {
                    section.freshness = if old.last_success_at.is_some() {
                        "stale"
                    } else {
                        "unavailable"
                    };
                    section.code = Some("source_unavailable");
                }
            }
            if let Some(document) = section.update_document(old.stamp())? {
                updates.insert(source, document);
            }
        }
        // Gate both documents before publishing a cache revision to any viewer.
        for len in [encoded_len(&next)?, encoded_len(&updates)?] {
            if len > MAX_SECTIONS_BYTES {
                return Err(Error::Capacity);
            }
        }
        self.sections = next;
        Ok(updates)
    }
}

fn encoded_len(value: &impl Serialize) -> Result<usize> {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len())
        .map_err(|_| Error::Unavailable)
}

fn activity(db: &Connection, now: i64, day: BusinessDay, context: &Context) -> Result<Value> {
    if context.clients.len() > 1024 {
        return Err(Error::Capacity);
    }
    let mut document = summary::in_flight(db, now, 200, &context.first_events)?;
    document["rows"]
        .as_array_mut()
        .expect("in-flight rows are an array")
        .sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));

    let hour = now / 3600 * 3600;
    let today = day.start(now);
    let mut hours = Map::new();
    let mut days = Map::new();
    let mut recent = Vec::new();
    for start in (hour - 167 * 3600..=hour).step_by(3600) {
        let mut rates: Vec<_> = samples(db, start, (start + 3600).min(now + 1), 256, None)?
            .into_iter()
            .map(|sample| sample.rate)
            .collect();
        if let Some(value) = median(&mut rates) {
            hours.insert(
                start.to_string(),
                json!({"median": value, "count": rates.len()}),
            );
        }
    }
    for start in (today - 6 * DAY..=today).step_by(DAY as usize) {
        let samples = samples(db, start, (start + DAY).min(now + 1), 4096, Some(now - 59))?;
        recent.extend(
            samples
                .iter()
                .filter(|sample| {
                    now - sample.settled_at < 60
                        && (context
                            .live_output_after
                            .is_some_and(|at| sample.settled_at > at)
                            || sample
                                .attempt
                                .as_ref()
                                .is_some_and(|id| context.live_output_attempts.contains(id)))
                })
                .map(|sample| sample.rate),
        );
        let mut rates: Vec<_> = samples.into_iter().map(|sample| sample.rate).collect();
        if let Some(value) = median(&mut rates) {
            days.insert(start.to_string(), json!(value));
        }
    }
    document["recentlyFinished"] = json!([]);
    document["overflow"] = json!(context.activity_overflow);
    let mut clients = context.clients.clone();
    let mut names = db.prepare_cached(
        "SELECT json_extract(metadata_json,'$.displayName') FROM managed_keys WHERE id=?",
    )?;
    for client in &mut clients {
        client.display_name = names
            .query_row([&client.key_id], |row| row.get(0))
            .optional()?
            .flatten();
    }
    document["clients"] = json!(clients);
    document["recentRequestOutputRateMedian"] = json!(median(&mut recent));
    document["requestOutputRateMediansByDay"] = Value::Object(days);
    document["requestOutputRateByHour"] = json!({
        "endUnixSeconds": hour, "offsetMinutes": day.0, "points": hours,
    });
    Ok(document)
}

struct OutputSample {
    attempt: Option<String>,
    settled_at: i64,
    rate: f64,
}

fn samples(
    db: &Connection,
    start: i64,
    end: i64,
    limit: i64,
    live_since: Option<i64>,
) -> Result<Vec<OutputSample>> {
    let mut statement = db.prepare_cached("
        SELECT output_rate_settled_at,output_rate,
            CASE WHEN output_rate_settled_at>=?4 THEN id END FROM attempts
        WHERE output_rate_settled_at>=?1 AND output_rate_settled_at<?2
          AND CASE WHEN json_valid(usage_json) THEN COALESCE(json_extract(usage_json,'$.images'),0) ELSE 0 END=0
        ORDER BY output_rate_settled_at DESC,rowid DESC LIMIT ?3")?;
    let rows = statement.query_map(params![start, end, limit, live_since], |row| {
        let at: i64 = row.get(0)?;
        let raw: Option<String> = row.get(1)?;
        let rate = raw
            .and_then(|raw| raw.parse::<f64>().ok())
            .filter(|rate| rate.is_finite() && *rate >= 0.0);
        rate.map(|rate| {
            Ok(OutputSample {
                attempt: row.get(2)?,
                settled_at: at,
                rate,
            })
        })
        .transpose()
    })?;
    Ok(rows
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .flatten()
        .collect())
}

fn median(rates: &mut [f64]) -> Option<f64> {
    if rates.is_empty() {
        return None;
    }
    rates.sort_unstable_by(f64::total_cmp);
    let mid = rates.len() / 2;
    Some(if rates.len().is_multiple_of(2) {
        rates[mid - 1] / 2.0 + rates[mid] / 2.0
    } else {
        rates[mid]
    })
}
