use std::collections::BTreeSet;

use rusqlite::{Connection, params, types::Value as SqlValue};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

use crate::{
    BusinessDay, Context, DAY, Error, Result, Usage,
    sql::{PRICE, bounded, rows, scalar},
    summary, validate_now,
};

const MAX_ITEMS: usize = 50;
const QUOTA_WARNING: f64 = 90.0;
const QUOTA_CRITICAL: f64 = 98.0;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Item {
    kind: &'static str,
    severity: &'static str,
    subject_type: &'static str,
    #[serde(rename = "subjectID")]
    subject_id: Option<String>,
    subject_name: Option<String>,
    detail: Value,
    since_unix_seconds: Option<i64>,
}

impl Item {
    fn new(kind: &'static str, critical: bool, detail: Value, since: Option<i64>) -> Self {
        Self {
            kind,
            severity: if critical { "critical" } else { "warning" },
            subject_type: "system",
            subject_id: None,
            subject_name: None,
            detail,
            since_unix_seconds: since,
        }
    }

    fn subject(mut self, kind: &'static str, id: &str, name: Option<&str>) -> Self {
        self.subject_type = kind;
        self.subject_id = Some(id.to_owned());
        self.subject_name = name.map(str::to_owned);
        self
    }
}

fn unavailable(source: &str) -> Item {
    Item::new(
        "attention_source_unavailable",
        false,
        json!({"source": source}),
        None,
    )
}

impl Usage {
    pub async fn attention(&self, now: i64, context: Arc<Context>) -> Result<Value> {
        validate_now(now)?;
        let day = self.day;
        let mut items = if context.storage["optionalWorkAllowed"].as_bool() == Some(true) {
            let sampling = context.clone();
            match self
                .reader
                .read(move |db| ledger(db, now, day, &sampling))
                .await
            {
                Ok(items) => items,
                Err(Error::Capacity) => return Err(Error::Capacity),
                Err(_) => unavailable_ledger(),
            }
        } else {
            unavailable_ledger()
        };
        for (name, at) in context.protocol_extensions.names.iter().take(32) {
            if name.is_empty()
                || name.len() > 128
                || !name.bytes().all(|byte| (32..=126).contains(&byte))
            {
                continue;
            }
            let mut item = Item::new(
                "client_protocol_extension",
                false,
                json!({"overflow": context.protocol_extensions.overflow}),
                Some(*at),
            );
            item.subject_type = "protocol";
            item.subject_name = Some(name.clone());
            items.push(item);
        }
        storage_and_backup(&mut items, &context.storage, now);
        items.sort_by(|a, b| {
            (
                a.severity,
                a.since_unix_seconds.unwrap_or(i64::MAX),
                a.kind,
                &a.subject_id,
                &a.subject_name,
            )
                .cmp(&(
                    b.severity,
                    b.since_unix_seconds.unwrap_or(i64::MAX),
                    b.kind,
                    &b.subject_id,
                    &b.subject_name,
                ))
        });
        items.truncate(MAX_ITEMS);
        Ok(json!({"items": items, "generatedAtUnixSeconds": now}))
    }
}

fn unavailable_ledger() -> Vec<Item> {
    ["accounts", "keys", "executions"]
        .into_iter()
        .map(unavailable)
        .collect()
}

fn ledger(db: &Connection, now: i64, day: BusinessDay, context: &Context) -> Result<Vec<Item>> {
    let mut items = Vec::new();
    for (source, result) in [
        ("accounts", accounts(db, now)),
        ("keys", keys(db, now, day)),
        ("executions", executions(db, now)),
        ("capacity", capacity(db, now, day, context)),
    ] {
        match result {
            Ok(found) => items.extend(found),
            Err(Error::Capacity) => return Err(Error::Capacity),
            Err(_) => items.push(unavailable(source)),
        }
    }
    Ok(items)
}

fn storage_and_backup(items: &mut Vec<Item>, storage: &Value, now: i64) {
    let pressure = storage["pressure"].as_str().unwrap_or("unknown");
    let sampled = storage["sampledUnixSeconds"].as_i64().filter(|&at| at > 0);
    if pressure == "unknown" || storage["coreAvailable"].as_bool() != Some(true) {
        items.push(unavailable("storage"));
    }
    if matches!(pressure, "blocked" | "degraded") {
        items.push(Item::new(
            "storage_pressure",
            true,
            json!({"pressure": pressure}),
            sampled,
        ));
    }

    let backup = &storage["backup"];
    if backup["enabled"].as_bool() != Some(true) {
        items.push(Item::new("backup_disabled", false, json!({}), None));
        return;
    }
    let last = backup["lastSuccessUnixSeconds"]
        .as_i64()
        .or_else(|| backup["enabledUnixSeconds"].as_i64());
    if let Some(last) = last.filter(|at| now.saturating_sub(*at) > 36 * 3600) {
        items.push(Item::new(
            "backup_stale",
            now.saturating_sub(last) > 72 * 3600,
            json!({}),
            Some(last),
        ));
    }
    let total = backup["totalBytes"].as_u64().unwrap_or(0);
    let largest = backup["largestBundleBytes"].as_u64().unwrap_or(0);
    if total > 5 * 1024 * 1024 * 1024 || largest > 768 * 1024 * 1024 {
        items.push(Item::new(
            "backup_size",
            false,
            json!({"totalBytes": total, "largestBundleBytes": largest}),
            None,
        ));
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuotaObservation {
    attempted_at_unix_seconds: Option<i64>,
    observed_at_unix_seconds: Option<i64>,
    quota: Option<Quota>,
    failure: Option<String>,
}

#[derive(Deserialize)]
struct Quota {
    limits: Vec<Limit>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Limit {
    id: String,
    allowed: Option<bool>,
    limit_reached: Option<bool>,
    primary: Option<Window>,
    secondary: Option<Window>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Window {
    used_percent: Option<f64>,
    duration_seconds: Option<i64>,
    resets_at_unix_seconds: Option<i64>,
    reset_after_seconds: Option<i64>,
}

impl Window {
    fn valid(&self) -> bool {
        self.used_percent
            .is_none_or(|n| (0.0..=10_000.0).contains(&n))
            && self
                .duration_seconds
                .is_none_or(|n| (1..=31_536_000).contains(&n))
            && self
                .resets_at_unix_seconds
                .is_none_or(|n| (1..=1_000_000_000_000).contains(&n))
            && self
                .reset_after_seconds
                .is_none_or(|n| (0..=31_536_000).contains(&n))
    }
}

impl QuotaObservation {
    fn limits(&self) -> Result<&[Limit]> {
        if self.observed_at_unix_seconds.is_some() != self.quota.is_some()
            || self.failure.is_some() && self.attempted_at_unix_seconds.is_none()
            || [
                self.attempted_at_unix_seconds,
                self.observed_at_unix_seconds,
            ]
            .into_iter()
            .flatten()
            .any(|n| !(1..=1_000_000_000_000).contains(&n))
        {
            return Err(Error::Unavailable);
        }
        let limits = self.quota.as_ref().map_or(&[][..], |q| q.limits.as_slice());
        let mut ids = BTreeSet::new();
        if limits.len() > 17
            || limits.iter().filter(|limit| limit.id != "codex").count() > 16
            || !limits.iter().all(|limit| {
                !limit.id.is_empty()
                    && limit.id.len() <= 128
                    && limit.id.bytes().all(|b| (33..=126).contains(&b))
                    && ids.insert(limit.id.as_str())
                    && [&limit.primary, &limit.secondary]
                        .into_iter()
                        .flatten()
                        .all(Window::valid)
            })
        {
            return Err(Error::Unavailable);
        }
        Ok(limits)
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Reset {
    #[serde(default)]
    settings: ResetSettings,
    intent: Option<ResetIntent>,
    #[serde(default)]
    failures: i64,
    last_attempt_at: Option<i64>,
    last_auto_reset_at: Option<i64>,
    last_failure_at: Option<i64>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResetSettings {
    retry_count: Option<i64>,
}

#[derive(Deserialize)]
struct ResetIntent {
    automatic: bool,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Priming {
    attention: Option<String>,
    last_attempt_at: Option<i64>,
}

fn decode<T: for<'de> Deserialize<'de> + Default>(record: Option<&str>) -> Result<T> {
    record.map_or_else(
        || Ok(T::default()),
        |raw| serde_json::from_str(raw).map_err(|_| Error::Unavailable),
    )
}

struct AccountEvidence {
    id: String,
    name: Option<String>,
    authorization: String,
    quota: Option<String>,
    cooldowns: i64,
    failure_at: Option<i64>,
    reset: Option<String>,
    priming: Option<String>,
}

fn accounts(db: &Connection, now: i64) -> Result<Vec<Item>> {
    let accounts = bounded(
        rows(
            db,
            "
        SELECT a.id,a.display_name,a.authorization,q.record_json,
          (SELECT COUNT(*) FROM account_model_health m WHERE m.account_id=a.id AND m.until_epoch>?),
          h.at_epoch,r.record_json,p.record_json
        FROM accounts a LEFT JOIN account_quota q ON q.account_id=a.id
        LEFT JOIN account_health h ON h.account_id=a.id
        LEFT JOIN account_reset_credits r ON r.account_id=a.id
        LEFT JOIN account_quota_priming p ON p.account_id=a.id
        ORDER BY a.id LIMIT 65",
            &[now.into()],
            |row| {
                Ok(AccountEvidence {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    authorization: row.get(2)?,
                    quota: row.get(3)?,
                    cooldowns: row.get(4)?,
                    failure_at: row.get(5)?,
                    reset: row.get(6)?,
                    priming: row.get(7)?,
                })
            },
        )?,
        64,
    )?;
    let mut items = Vec::new();
    for account in accounts {
        let mut add = |kind, critical, detail, since| {
            items.push(Item::new(kind, critical, detail, since).subject(
                "account",
                &account.id,
                account.name.as_deref(),
            ));
        };
        match account.authorization.as_str() {
            "requires_auth" => add("account_requires_auth", true, json!({}), None),
            "auth_uncertain" => add("account_auth_uncertain", true, json!({}), None),
            "ready" | "refreshing" => {}
            _ => return Err(Error::Unavailable),
        }
        if account.cooldowns > 0 {
            add(
                "account_cooldown",
                false,
                json!({"count": account.cooldowns}),
                account.failure_at,
            );
        }
        let quota: QuotaObservation = decode(account.quota.as_deref())?;
        let limits = quota.limits()?;
        let fresh = quota
            .observed_at_unix_seconds
            .is_some_and(|at| (0..300).contains(&(now - at)));
        let observed = limits.iter().any(|limit| {
            limit.allowed.is_some()
                || limit.limit_reached.is_some()
                || limit.primary.is_some()
                || limit.secondary.is_some()
        });
        if quota.failure.is_some() || !observed || !fresh {
            let (reason, since) = if quota.failure.is_some() {
                ("failed", quota.attempted_at_unix_seconds)
            } else {
                (
                    if observed { "stale" } else { "unavailable" },
                    quota.observed_at_unix_seconds,
                )
            };
            add("quota_stale", false, json!({"reason": reason}), since);
        }
        let maximum = limits
            .iter()
            .flat_map(|limit| [&limit.primary, &limit.secondary])
            .flatten()
            .filter_map(|window| window.used_percent)
            .max_by(f64::total_cmp);
        if let Some(maximum) = maximum.filter(|n| fresh && *n >= QUOTA_WARNING) {
            add(
                "quota_high",
                maximum >= QUOTA_CRITICAL,
                json!({"usedPercent": maximum, "keyRanking": ranking(db, &account.id, now)?}),
                quota.observed_at_unix_seconds,
            );
        }

        let reset: Reset = decode(account.reset.as_deref())?;
        let automatic = reset.intent.as_ref().is_none_or(|intent| intent.automatic);
        let retry_count = reset.settings.retry_count.unwrap_or(3);
        if !(0..=5).contains(&retry_count) || !(0..=1_000_000).contains(&reset.failures) {
            return Err(Error::Unavailable);
        }
        let exhausted = reset.failures >= if automatic { retry_count + 1 } else { 3 };
        let pending = reset.intent.is_some();
        if pending
            || exhausted
            || reset
                .last_auto_reset_at
                .is_some_and(|at| (0..DAY).contains(&now.saturating_sub(at)))
        {
            let (code, since) = if exhausted && automatic {
                (
                    "repeated_failure",
                    if pending {
                        reset.last_attempt_at
                    } else {
                        reset.last_failure_at
                    },
                )
            } else if pending {
                ("unknown", reset.last_attempt_at)
            } else {
                (
                    "reset",
                    if exhausted {
                        reset.last_failure_at
                    } else {
                        reset.last_auto_reset_at
                    },
                )
            };
            add(
                "reset_credits",
                pending,
                json!({"code": code, "attempts": reset.failures}),
                since,
            );
        }
        let priming: Priming = decode(account.priming.as_deref())?;
        if let Some(code) = priming.attention.as_deref() {
            if !matches!(code, "repeated_failure" | "model_removed") {
                return Err(Error::Unavailable);
            }
            add(
                "quota_priming",
                false,
                json!({"code": code}),
                priming.last_attempt_at,
            );
        }
    }
    Ok(items)
}

fn ranking(db: &Connection, id: &str, now: i64) -> Result<String> {
    let query = format!("
        SELECT COALESCE(json_extract(k.metadata_json,'$.displayName'),json_extract(k.metadata_json,'$.principal'),a.key_id),
          SUM({PRICE}),COUNT(*),COALESCE(SUM(a.usage_json IS NULL OR
            COALESCE(json_extract(a.usage_json,'$.priceCompleteness'),json_extract(a.usage_json,'$.completeness'))!='complete'),0)
        FROM attempts a LEFT JOIN managed_keys k ON k.id=a.key_id
        WHERE a.identity=? AND a.created_at_epoch>=? AND a.created_at_epoch<=?
        GROUP BY a.key_id ORDER BY 2 DESC,a.key_id LIMIT 5");
    let accounts = rows(
        db,
        &query,
        &[id.to_owned().into(), (now - 5 * 3600).into(), now.into()],
        |row| {
            let name: String = row.get(0)?;
            let price: Option<i64> = row.get(1)?;
            let count: i64 = row.get(2)?;
            let incomplete: i64 = row.get(3)?;
            let price = price.map_or_else(
                || "费用未知".to_owned(),
                |p| format!("${:.6}", p as f64 / 1_000_000.0),
            );
            Ok(format!(
                "{name}：{price}，请求 {count}，证据不完整 {incomplete}"
            ))
        },
    )?;
    Ok(accounts.join(" | "))
}

fn keys(db: &Connection, now: i64, day: BusinessDay) -> Result<Vec<Item>> {
    let keys = bounded(rows(db, "
        SELECT id,json_extract(metadata_json,'$.principal'),json_extract(metadata_json,'$.displayName'),
          json_extract(metadata_json,'$.enabled'),json_extract(metadata_json,'$.archivedAtUnixSeconds'),
          json_extract(metadata_json,'$.expiresAtUnixSeconds'),json_extract(metadata_json,'$.policy.limits.tokens')
        FROM managed_keys ORDER BY id LIMIT 257", &[], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, Option<String>>(2)?,
            row.get::<_, bool>(3)?, row.get::<_, Option<i64>>(4)?, row.get::<_, Option<i64>>(5)?,
            row.get::<_, Option<i64>>(6)?))
    })?, 256)?;
    let tokens = summary::key_token_usages(db, day.start(now), day)?;
    let mut items = Vec::new();
    for (id, principal, name, enabled, archived, expires, limit) in keys {
        if !enabled || archived.is_some() {
            continue;
        }
        let name = name.as_deref().unwrap_or(&principal);
        if let Some(expires) = expires.filter(|at| *at <= now + 7 * DAY) {
            items.push(
                Item::new(
                    "key_expiring",
                    false,
                    json!({"expiresAtUnixSeconds": expires}),
                    Some(expires),
                )
                .subject("key", &id, Some(name)),
            );
        }
        if let Some(limit) = limit {
            if limit <= 0 {
                return Err(Error::Unavailable);
            }
            if let Some(used) = tokens
                .get(&id)
                .and_then(|value| value["tokens"].as_str())
                .and_then(|value| value.parse::<i64>().ok())
            {
                let percent = used as f64 * 100.0 / limit as f64;
                if percent >= QUOTA_WARNING {
                    items.push(
                        Item::new(
                            "key_limit_near",
                            false,
                            json!({"metric": "tokens", "usedPercent": percent}),
                            None,
                        )
                        .subject("key", &id, Some(name)),
                    );
                }
            }
        }
    }
    Ok(items)
}

fn executions(db: &Connection, now: i64) -> Result<Vec<Item>> {
    let since = now - 3600;
    let (admitted, failed, unknown): (i64, i64, i64) = db.query_row(
        "SELECT COUNT(*),COALESCE(SUM(json_extract(outcome_json,'$.kind')='failed'
          AND COALESCE(json_extract(outcome_json,'$.failure'),'')!='client_cancelled'),0),
          COALESCE(SUM((state='unknown' OR closed_unknown_at_epoch IS NOT NULL)
          AND COALESCE(json_extract(outcome_json,'$.failure'),'')!='client_cancelled'),0)
         FROM attempts WHERE created_at_epoch>=? AND created_at_epoch<=?",
        params![since, now],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    let mut items = Vec::new();
    if unknown >= 10 && admitted > 0 && unknown * 5 >= admitted {
        items.push(Item::new("observation_quality", false,
            json!({"count": unknown, "admitted": admitted, "percent": unknown as f64 * 100.0 / admitted as f64}), Some(since)));
    }
    if admitted >= 20 && failed * 10 >= admitted {
        items.push(Item::new("error_rate_high", true,
            json!({"admitted": admitted, "failed": failed, "percent": failed as f64 * 100.0 / admitted as f64}), None));
    }
    Ok(items)
}

fn capacity(db: &Connection, now: i64, day: BusinessDay, context: &Context) -> Result<Vec<Item>> {
    let headroom = summary::headroom(db, now, day, context)?;
    let mut items = Vec::new();
    for counter in headroom["capacities"].as_array().into_iter().flatten() {
        let current = counter["current"]
            .as_str()
            .and_then(|value| value.parse::<i64>().ok());
        let limit = counter["limit"]
            .as_str()
            .and_then(|value| value.parse::<i64>().ok());
        if let (Some(current), Some(limit)) = (current, limit)
            && limit > 0
            && current as i128 * 5 >= limit as i128 * 4
        {
            items.push(Item::new("capacity_reference", false, json!({
                "metric": counter["name"], "current": counter["current"], "limit": counter["limit"],
                "exceeded": current > limit,
            }), None));
        }
    }
    for account in headroom["accounts"].as_array().into_iter().flatten() {
        let id = account["id"].as_str().ok_or(Error::Unavailable)?;
        let peak = account["peak24Hours"].as_i64().ok_or(Error::Unavailable)?;
        let limit = account["limit"].as_i64().ok_or(Error::Unavailable)?;
        if peak * 5 >= limit * 4 {
            items.push(
                Item::new(
                    "account_concurrency_high",
                    false,
                    json!({"peak": peak, "limit": limit}),
                    None,
                )
                .subject("account", id, None),
            );
        }
        let count = |end: i64| {
            scalar(
                db,
                "SELECT COUNT(*) FROM attempts WHERE identity=? AND created_at_epoch>=? AND created_at_epoch<?",
                &[
                    SqlValue::Text(id.to_owned()),
                    (end - 600).into(),
                    end.into(),
                ],
            )
        };
        let recent = count(now)?;
        if recent >= 60 {
            let mut baseline = (1..=7)
                .map(|n| count(now - n * DAY))
                .collect::<Result<Vec<_>>>()?;
            baseline.sort_unstable();
            if recent >= baseline[3] * 5 {
                items.push(
                    Item::new(
                        "account_rate_surge",
                        false,
                        json!({"count": recent, "median": baseline[3]}),
                        None,
                    )
                    .subject("account", id, None),
                );
            }
        }
    }
    Ok(items)
}
