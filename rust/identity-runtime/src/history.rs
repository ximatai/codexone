//! Read-only projections of the observation owner's Swift-compatible history tables.

use codexone_governance::{CreditHistoryRange, Error, Result};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

use crate::{
    quota::{WindowTrend, valid_balance},
    runtime::validate_id,
    store::{load_quota, require_account},
};

const DAY: i64 = 86_400;
const MAX_CYCLE_SAMPLES: usize = 105_122;
const MAX_SEGMENTS: usize = 1024;
type QuotaSample = (i64, f64);

#[derive(Serialize)]
pub struct QuotaHistory {
    #[serde(skip_serializing_if = "Option::is_none")]
    primary: Option<Cycle>,
    #[serde(skip_serializing_if = "Option::is_none")]
    secondary: Option<Cycle>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Cycle {
    reset: i64,
    duration: i64,
    samples: Vec<QuotaSample>,
    #[serde(skip_serializing_if = "Option::is_none")]
    history_segments: Option<Vec<Vec<QuotaSample>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    history_sampled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    history_omitted: Option<bool>,
}

/// Call inside a read transaction so metadata, current-cycle rows and the legacy
/// fallback all refer to the same observation.
pub fn quota_trend(db: &Connection, id: &str) -> Result<QuotaHistory> {
    validate_id(id)?;
    require_account(db, id)?;
    let legacy = load_quota(db, id)?.trend.unwrap_or_default();
    Ok(QuotaHistory {
        primary: cycle(db, id, 0, legacy.primary)?,
        secondary: cycle(db, id, 1, legacy.secondary)?,
    })
}

fn cycle(
    db: &Connection,
    id: &str,
    kind: i64,
    legacy: Option<WindowTrend>,
) -> Result<Option<Cycle>> {
    let meta = db
        .query_row(
            "SELECT reset_epoch, duration_seconds FROM account_quota_cycle_samples
             WHERE account_id=? AND kind=? ORDER BY bucket_epoch DESC LIMIT 1",
            params![id, kind],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let (reset, duration, samples) = if let Some((reset, duration)) = meta {
        let mut statement = db.prepare(
            "SELECT at_epoch, remaining FROM account_quota_cycle_samples
             WHERE account_id=? AND kind=? ORDER BY bucket_epoch LIMIT ?",
        )?;
        let mut rows = statement.query(params![id, kind, MAX_CYCLE_SAMPLES as i64 + 1])?;
        let mut samples = Vec::new();
        while let Some(row) = rows.next()? {
            if samples.len() == MAX_CYCLE_SAMPLES {
                return Err(Error::QuotaTrendCapacity);
            }
            let remaining = row
                .get_ref(1)?
                .as_str()
                .ok()
                .and_then(|text| text.parse::<f64>().ok())
                .filter(|value| (0.0..=100.0).contains(value))
                .ok_or(Error::Unavailable)?;
            samples.push((row.get(0)?, remaining));
        }
        (reset, duration, samples)
    } else if let Some(legacy) = legacy {
        (legacy.reset, legacy.duration, legacy.samples)
    } else {
        return Ok(None);
    };
    let mut cycle = Cycle {
        reset,
        duration,
        samples: Vec::new(),
        history_segments: None,
        history_sampled: None,
        history_omitted: None,
    };
    if let Some(&(last, _)) = samples.last() {
        cycle.samples = samples
            .iter()
            .copied()
            .filter(|&(at, _)| at >= last - DAY)
            .collect();
        let (segments, sampled, omitted) = chart_samples(&samples, duration);
        cycle.history_segments = Some(segments);
        cycle.history_sampled = Some(sampled);
        cycle.history_omitted = Some(omitted);
    }
    Ok(Some(cycle))
}

fn chart_samples(samples: &[QuotaSample], duration: i64) -> (Vec<Vec<QuotaSample>>, bool, bool) {
    let width = 300.max((duration + 511) / 512);
    let mut segments = Vec::new();
    let mut sampled = false;
    for segment in samples.chunk_by(|left, right| right.0 - left.0 <= 900) {
        let mut points = Vec::new();
        for bucket in segment.chunk_by(|left, right| left.0 / width == right.0 / width) {
            points.push(bucket[0]);
            if bucket.len() > 1 {
                points.push(bucket[bucket.len() - 1]);
            }
            sampled |= bucket.len() > 2;
        }
        segments.push(points);
    }
    let omitted = segments.len() > MAX_SEGMENTS;
    if omitted {
        let last = segments.len() - 1;
        let mut indexed = segments.into_iter().enumerate();
        segments = (0..MAX_SEGMENTS)
            .map(|i| {
                let index = i * last / (MAX_SEGMENTS - 1);
                indexed
                    .find(|(position, _)| *position == index)
                    .expect("segment index")
                    .1
            })
            .collect();
    }
    (segments, sampled, omitted)
}

#[derive(Serialize)]
pub struct CreditHistory {
    from: i64,
    through: i64,
    segments: Vec<Vec<CreditSample>>,
}

#[derive(Serialize)]
struct CreditSample {
    at: i64,
    balance: String,
}

pub fn credit_history(
    db: &Connection,
    id: &str,
    range: CreditHistoryRange,
    through: i64,
) -> Result<CreditHistory> {
    validate_id(id)?;
    require_account(db, id)?;
    let from = (through
        - match range {
            CreditHistoryRange::Day => DAY,
            CreditHistoryRange::Week => 7 * DAY,
        })
    .max(1);
    let mut statement = db.prepare(
        "SELECT at_epoch, balance FROM account_credit_samples
         WHERE account_id=? AND bucket_epoch BETWEEN ? AND ? AND at_epoch BETWEEN ? AND ?
         ORDER BY bucket_epoch",
    )?;
    let mut rows = statement.query(params![id, from / 300, through / 300, from, through])?;
    let mut segments: Vec<Vec<CreditSample>> = Vec::new();
    let mut previous_bucket = None;
    while let Some(row) = rows.next()? {
        let sample = CreditSample {
            at: row.get(0)?,
            balance: row.get(1)?,
        };
        if !valid_balance(&sample.balance) {
            return Err(Error::Unavailable);
        }
        let bucket = sample.at / 300;
        if previous_bucket == Some(bucket - 1) {
            let segment = segments.last_mut().expect("previous credit sample");
            if sample.at < through - DAY
                && segment.len() > 1
                && segment
                    .last()
                    .is_some_and(|last| last.at / 3600 == sample.at / 3600)
            {
                segment.pop();
            }
            segment.push(sample);
        } else {
            segments.push(vec![sample]);
        }
        previous_bucket = Some(bucket);
    }
    Ok(CreditHistory {
        from,
        through,
        segments,
    })
}
