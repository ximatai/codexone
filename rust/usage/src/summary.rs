use std::collections::{BTreeMap, HashMap};

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use crate::{
    BusinessDay, DAY, Result,
    history::required_enum,
    query::{FAILURES, MODES, Query, safe_metadata},
    sql::{PRICE, Predicate, bounded, metric, metric_columns, metrics, rows},
};

pub(crate) fn options(
    db: &Connection,
    day: BusinessDay,
    defaults: &BTreeMap<String, String>,
) -> Result<Value> {
    let keys = bounded(rows(db, "
        SELECT ids.id,json_extract(k.metadata_json,'$.principal'),json_extract(k.metadata_json,'$.displayName'),
          json_extract(k.metadata_json,'$.archivedAtUnixSeconds') IS NOT NULL
        FROM (SELECT id FROM managed_keys UNION SELECT key_id FROM attempts UNION SELECT key_id FROM usage_daily
              UNION SELECT key_id FROM request_diagnostics) ids
        LEFT JOIN managed_keys k ON k.id=ids.id ORDER BY ids.id LIMIT 257", &[], |row| {
        let id: String = row.get(0)?;
        let details = json!({
            "id": id, "principal": row.get::<_, Option<String>>(1)?,
            "displayName": row.get::<_, Option<String>>(2)?, "archived": row.get::<_, bool>(3)?,
        });
        Ok((id, details))
    })?, 256)?;
    let (ids, key_options): (Vec<_>, Vec<_>) = keys.into_iter().unzip();
    let models = bounded(
        rows(
            db,
            "SELECT model FROM health_models ORDER BY model LIMIT 49",
            &[],
            |row| row.get::<_, String>(0),
        )?,
        48,
    )?;
    let defaults: BTreeMap<_, _> = defaults
        .iter()
        .map(|(id, effort)| (id, safe_metadata(effort)))
        .collect();
    Ok(json!({
        "businessDay": day.document(), "timezone": day.timezone(), "keys": ids,
        "keyOptions": key_options, "models": models, "defaultReasoningEfforts": defaults, "failures": FAILURES,
    }))
}

pub(crate) fn daily(db: &Connection, query: &Query, day: BusinessDay, now: i64) -> Result<Value> {
    let offset = day.seconds();
    let day_start = "((created_at_epoch+?1)/86400*86400-?1)";
    let predicate = Predicate::usage(query, false, true, now);
    let source = format!("
        FROM (
          SELECT created_at_epoch,key_id,admission_json,outcome_json,usage_json,1 record_count,
            state='unknown' OR closed_unknown_at_epoch IS NOT NULL usage_unknown FROM attempts
          UNION ALL
          SELECT day_epoch-?1,key_id,json_object('model',NULLIF(model,''),'mode',mode),
            json_object('kind',NULLIF(outcome,''),'failure',NULLIF(failure,'')),
            json_object('inputTokens',input_tokens,'outputTokens',output_tokens,'cachedTokens',cached_tokens,
              'images',images,'estimatedMicros',estimated_micros,'imageInputTokens',image_input_tokens,
              'imageOutputTokens',image_output_tokens,'imageInputTextTokens',image_input_text_tokens,
              'imageInputImageTokens',image_input_image_tokens,'svgInputTokens',svg_input_tokens,
              'svgOutputTokens',svg_output_tokens,'svgReasoningTokens',svg_reasoning_tokens,
              'priceCompleteness',CASE WHEN price_unknown=0 THEN 'complete' ELSE 'partial' END),
            requests,usage_unknown FROM usage_daily
        ) WHERE {}", predicate.sql());
    let mut values = vec![offset.into()];
    values.extend(predicate.values);
    let mut daily: BTreeMap<i64, Value> = rows(db, &format!(
        "SELECT {day_start},SUM(record_count),
         COALESCE(SUM(CASE WHEN json_extract(outcome_json,'$.kind')='succeeded' THEN record_count ELSE 0 END),0),
         COALESCE(SUM(CASE WHEN json_extract(outcome_json,'$.kind')='failed' THEN record_count ELSE 0 END),0),
         COALESCE(SUM(CASE WHEN json_extract(outcome_json,'$.kind')='cancelled' THEN record_count ELSE 0 END),0),
         {} {source} GROUP BY 1", metric_columns(true)), &values, |row| {
        let at: i64 = row.get(0)?;
        Ok((at, json!({
            "atUnixSeconds": at, "requests": row.get::<_, i64>(1)?, "succeeded": row.get::<_, i64>(2)?,
            "failed": row.get::<_, i64>(3)?, "cancelled": row.get::<_, i64>(4)?, "metrics": metrics(Some(row), 5)?,
            "failures": {}, "unknownReasons": {}, "usageUnknown": 0, "recordedRejections": 0,
        })))
    })?.into_iter().collect();
    for (at, reason, count, unknown) in rows(
        db,
        &format!(
            "SELECT {day_start},json_extract(outcome_json,'$.failure'),SUM(record_count),
         COALESCE(SUM(CASE WHEN usage_unknown THEN record_count ELSE 0 END),0)
         {source} GROUP BY 1,2"
        ),
        &values,
        |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
            ))
        },
    )? {
        if let Some(bucket) = daily.get_mut(&at) {
            if let Some(reason) = reason.as_ref() {
                bucket["failures"][reason] = json!(count);
            }
            if unknown > 0 {
                let reason = reason.as_deref().unwrap_or("unspecified");
                let reasons = &mut bucket["unknownReasons"];
                reasons[reason] = json!(reasons[reason].as_i64().unwrap_or(0) + unknown);
                bucket["usageUnknown"] =
                    json!(bucket["usageUnknown"].as_i64().unwrap_or(0) + unknown);
            }
        }
    }
    let rejected = Predicate::usage(query, true, true, now);
    let mut values = vec![offset.into()];
    let sql = rejected.sql();
    values.extend(rejected.values);
    let rejections: BTreeMap<i64, i64> = rows(db, &format!(
        "SELECT ((at_epoch+?1)/86400*86400-?1),COUNT(*) FROM request_diagnostics WHERE {sql} GROUP BY 1"),
        &values, |row| Ok((row.get(0)?, row.get(1)?)))?.into_iter().collect();
    let empty = metrics(None, 0)?;
    let buckets: Vec<_> = (query.start..query.end).step_by(DAY as usize).map(|at| {
        let mut value = daily.remove(&at).unwrap_or_else(|| json!({
            "atUnixSeconds": at, "requests": 0, "succeeded": 0, "failed": 0,
            "cancelled": 0, "failures": {}, "unknownReasons": {}, "usageUnknown": 0, "metrics": empty,
        }));
        value["recordedRejections"] = json!(rejections.get(&at).copied().unwrap_or(0));
        value
    }).collect();
    Ok(json!({
        "businessDay": day.document(), "timezone": day.timezone(),
        "days": (query.end - query.start) / DAY, "buckets": buckets,
    }))
}

pub(crate) fn in_flight(
    db: &Connection,
    now: i64,
    limit: i64,
    first_events: &HashMap<String, bool>,
) -> Result<Value> {
    let rows = rows(db, "
        SELECT a.id,a.key_id,COALESCE(json_extract(k.metadata_json,'$.principal'),
            CASE WHEN json_extract(a.admission_json,'$.mode')='priming' THEN a.principal END),
          json_extract(a.admission_json,'$.model'),COALESCE(json_extract(a.admission_json,'$.mode'),'generation'),
          a.identity,c.display_name,a.created_at_epoch,json_extract(k.metadata_json,'$.displayName'),
          json_extract(a.admission_json,'$.reasoningEffort'),json_extract(a.admission_json,'$.requestMetadataRecorded')
        FROM attempts a LEFT JOIN managed_keys k ON k.id=a.key_id LEFT JOIN accounts c ON c.id=a.identity
        WHERE a.state='intent' ORDER BY a.created_at_epoch DESC,a.id DESC LIMIT ?", &[limit.into()], |row| {
        let id: String = row.get(0)?;
        let start: Option<i64> = row.get(7)?;
        let mut record = json!({
            "id": id, "keyID": row.get::<_, String>(1)?, "mode": required_enum(row, 4, MODES)?,
            "accountID": row.get::<_, String>(5)?, "displayName": row.get::<_, Option<String>>(8)?,
        });
        if let Some(start) = start {
            record["startedAtUnixSeconds"] = json!(start);
            record["elapsedSeconds"] = json!(now.saturating_sub(start).max(0));
        }
        if let Some(first_event) = first_events.get(&id) {
            record["hasFirstEvent"] = json!(first_event);
        }
        for (index, field) in [(2, "principal"), (3, "model"), (6, "accountDisplayName")] {
            if let Some(value) = row.get::<_, Option<String>>(index)? {
                record[field] = json!(value);
            }
        }
        if let Some(effort) = row.get::<_, Option<String>>(9)? {
            record["reasoningEffort"] = json!(safe_metadata(&effort));
        }
        if let Some(recorded) = row.get::<_, Option<bool>>(10)? {
            record["requestMetadataRecorded"] = json!(recorded);
        }
        Ok(record)
    })?;
    Ok(json!({"rows": rows}))
}

pub(crate) fn keys(
    db: &Connection,
    now: i64,
    day: BusinessDay,
    include_archived: bool,
) -> Result<Value> {
    let start = day.start(now);
    let end = start + DAY;
    let mapped_day = start + day.seconds();
    let covering_day = start.div_euclid(DAY) * DAY;
    let token_usages: BTreeMap<String, Value> = rows(db, "
        SELECT key_id,COALESCE(SUM(input_count),0)+COALESCE(SUM(output_count),0),SUM(missing),
          SUM(input_count),SUM(output_count)
        FROM (
          SELECT key_id,
            COALESCE((CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN json_extract(usage_json,'$.imageInputTokens')
                ELSE json_extract(usage_json,'$.inputTokens') END)+COALESCE(json_extract(usage_json,'$.svgInputTokens'),0),
                json_extract(usage_json,'$.svgInputTokens')) AS input_count,
            COALESCE((CASE WHEN json_extract(usage_json,'$.nativeImages')=1 THEN json_extract(usage_json,'$.imageOutputTokens')
                ELSE json_extract(usage_json,'$.outputTokens') END)+COALESCE(json_extract(usage_json,'$.svgOutputTokens'),0),
                json_extract(usage_json,'$.svgOutputTokens')) AS output_count,
            CASE WHEN usage_json IS NULL OR json_extract(usage_json,'$.completeness')!='complete'
              OR (json_extract(usage_json,'$.nativeImages')=1 AND (json_extract(usage_json,'$.imageInputTokens') IS NULL
              OR json_extract(usage_json,'$.imageOutputTokens') IS NULL)) THEN 1 ELSE 0 END AS missing
          FROM attempts WHERE created_at_epoch>=?1 AND created_at_epoch<?2
          UNION ALL
          SELECT key_id,COALESCE(COALESCE(input_tokens,image_input_tokens)+COALESCE(svg_input_tokens,0),svg_input_tokens),
            COALESCE(COALESCE(output_tokens,image_output_tokens)+COALESCE(svg_output_tokens,0),svg_output_tokens),
            CASE WHEN completeness!='complete' OR usage_unknown=1 OR COALESCE(input_tokens,image_input_tokens) IS NULL
              OR COALESCE(output_tokens,image_output_tokens) IS NULL THEN 1 ELSE 0 END
          FROM usage_daily WHERE day_epoch=?3 OR day_epoch=?4
        ) GROUP BY key_id", &[start.into(), end.into(), mapped_day.into(), covering_day.into()], |row| {
        Ok((row.get(0)?, json!({"tokens": metric(row, 1)?, "incomplete": row.get::<_, i64>(2)? > 0,
            "breakdown": {"input": metric(row, 3)?, "output": metric(row, 4)?}})))
    })?.into_iter().collect();

    let today = "a.created_at_epoch>=?1 AND a.created_at_epoch<?2";
    let outcome = "json_extract(a.outcome_json,'$.kind')";
    let active = "COALESCE(json_extract(a.usage_json,'$.nativeImages'),0)!=1";
    let lifetime_rollup = "(SELECT MAX(last_used_epoch) FROM usage_daily d WHERE d.key_id=k.id)";
    let document = rows(db, &format!("
        SELECT k.id,json_extract(k.metadata_json,'$.principal'), json_extract(k.metadata_json,'$.displayName'),
          json_extract(k.metadata_json,'$.enabled'),
          COUNT(CASE WHEN {today} THEN 1 END),
          COUNT(CASE WHEN {today} AND {outcome}='failed' THEN 1 END),
          COUNT(CASE WHEN {today} AND {outcome}='succeeded' THEN 1 END),
          COUNT(CASE WHEN {today} AND {outcome}='cancelled' THEN 1 END),
          COUNT(CASE WHEN {today} AND a.state!='settled' THEN 1 END),
          COUNT(CASE WHEN {today} AND a.state='intent' THEN 1 END),
          SUM(CASE WHEN {today} THEN {PRICE} END),
          COUNT(CASE WHEN {today} AND COALESCE(json_extract(a.usage_json,'$.priceCompleteness'),
            json_extract(a.usage_json,'$.completeness'),'unavailable')='complete' THEN {PRICE} END),
          SUM(CASE WHEN {today} AND {active} THEN json_extract(a.usage_json,'$.inputTokens') END),
          SUM(CASE WHEN {today} AND {active} THEN json_extract(a.usage_json,'$.cachedTokens') END),
          COUNT(CASE WHEN {today} AND (a.usage_json IS NULL OR json_extract(a.usage_json,'$.nativeImages')=1
             OR json_extract(a.usage_json,'$.completeness')!='complete') THEN 1 END),
          SUM(CASE WHEN {today} THEN json_extract(a.usage_json,'$.images') END),
          MIN(CASE WHEN {today} THEN a.created_at_epoch END),MAX(CASE WHEN {today} THEN a.created_at_epoch END),
          CASE WHEN MAX(a.created_at_epoch) IS NULL THEN {lifetime_rollup}
            WHEN {lifetime_rollup} IS NULL THEN MAX(a.created_at_epoch)
            ELSE MAX(MAX(a.created_at_epoch),{lifetime_rollup}) END
        FROM managed_keys k LEFT JOIN attempts a ON a.key_id=k.id
        WHERE ?3 OR json_extract(k.metadata_json,'$.archivedAtUnixSeconds') IS NULL
        GROUP BY k.id ORDER BY k.id LIMIT 257"), &[start.into(), end.into(), i64::from(include_archived).into()], |row| {
        let id: String = row.get(0)?;
        let token = token_usages.get(&id);
        let admitted = row.get::<_, i64>(4)?;
        let estimated = metric(row, 10)?;
        let complete_prices = row.get::<_, i64>(11)?;
        Ok(json!({
            "keyID": id, "principal": row.get::<_, Option<String>>(1)?, "displayName": row.get::<_, Option<String>>(2)?,
            "enabled": row.get::<_, bool>(3)?, "admitted": admitted, "failed": row.get::<_, i64>(5)?,
            "succeeded": row.get::<_, i64>(6)?, "cancelled": row.get::<_, i64>(7)?,
            "pending": row.get::<_, i64>(8)?, "inFlight": row.get::<_, i64>(9)?,
            "tokens": token.and_then(|v| v["tokens"].as_str()).unwrap_or("0"),
            "tokenBreakdown": token.map(|v| v["breakdown"].clone()).unwrap_or_else(|| json!({"input": null, "output": null})),
            "tokenUsageIncomplete": token.and_then(|v| v["incomplete"].as_bool()).unwrap_or(false),
            "estimatedMicros": estimated, "priceUsageIncomplete": estimated.as_ref().map(|_| complete_prices < admitted),
            "inputTokens": metric(row, 12)?, "cachedTokens": metric(row, 13)?,
            "cacheUsageIncomplete": row.get::<_, i64>(14)? > 0, "images": metric(row, 15)?,
            "firstUsedTodayAtUnixSeconds": row.get::<_, Option<i64>>(16)?,
            "lastUsedTodayAtUnixSeconds": row.get::<_, Option<i64>>(17)?,
            "lastUsedAtUnixSeconds": row.get::<_, Option<i64>>(18)?,
        }))
    })?;
    Ok(json!({
        "startUnixSeconds": start, "endUnixSeconds": end, "businessDay": day.document(),
        "timezone": day.timezone(), "keys": bounded(document, 256)?,
    }))
}

pub(crate) fn headroom(
    db: &Connection,
    now: i64,
    day: BusinessDay,
    context: &crate::Context,
) -> Result<Value> {
    let start = day.start(now);
    let mut capacities = Vec::new();
    if context.daily_requests.is_some() || context.daily_budget_micros.is_some() {
        let (requests, estimated) = db.query_row(
            "SELECT COUNT(*),SUM(CASE WHEN json_extract(usage_json,'$.nativeImages')=1
              AND json_extract(usage_json,'$.imageInputTokens') IS NULL AND json_extract(usage_json,'$.imageOutputTokens') IS NULL
              THEN NULL ELSE json_extract(usage_json,'$.estimatedMicros') END)
              FROM attempts WHERE created_at_epoch>=? AND created_at_epoch<?",
            params![start, start + DAY], |row| Ok((metric(row, 0)?, metric(row, 1)?)),
        )?;
        for (name, current, limit) in [
            ("daily_requests", requests, context.daily_requests),
            (
                "daily_estimated_micros",
                estimated,
                context.daily_budget_micros,
            ),
        ] {
            if let Some(limit) = limit {
                capacities.push(json!({"name": name, "current": current, "limit": limit.to_string(), "blocking": false}));
            }
        }
    }
    let detail: i64 = db.query_row("SELECT COUNT(*) FROM attempts", [], |row| row.get(0))?;
    capacities.push(json!({"name": "detail_rows", "current": detail.to_string(), "limit": "100000", "blocking": false}));
    let accounts = bounded(rows(db, "
        SELECT ids.id,
          (SELECT COUNT(*) FROM attempts a WHERE a.identity=ids.id AND a.namespace=ids.namespace AND a.state='intent'),
          (SELECT COALESCE(MAX(peak),0) FROM account_concurrency c WHERE c.identity=ids.id AND c.namespace=ids.namespace
            AND c.at_epoch>=? AND c.at_epoch<=?)
        FROM (SELECT id,namespace FROM accounts UNION SELECT DISTINCT identity,namespace FROM attempts) ids
        ORDER BY ids.id LIMIT 65", &[(now - DAY).into(), now.into()], |row| {
        let current: i64 = row.get(1)?;
        Ok(json!({"id": row.get::<_, String>(0)?, "current": current,
            "peak24Hours": current.max(row.get(2)?), "limit": 16, "blocking": true}))
    })?, 64)?;
    let unknown: i64 = db.query_row(
        "SELECT COUNT(*) FROM attempts WHERE state='unknown' AND created_at_epoch<?",
        [now],
        |row| row.get(0),
    )?;
    Ok(json!({
        "generatedAtUnixSeconds": now, "unknownReconciliation": {
            "count": unknown, "beforeUnixSeconds": now, "periodSeconds": DAY,
        }, "capacities": capacities, "accounts": accounts,
        "storage": context.storage, "storageLimits": {
            "stopAvailableBytes": context.stop_available_bytes, "stopWALBytes": context.stop_wal_bytes,
        },
    }))
}
