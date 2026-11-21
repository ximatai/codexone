use std::collections::BTreeMap;

use rusqlite::{Connection, Row, params_from_iter, types::Value as SqlValue};
use serde_json::{Value, json};

use crate::{
    BusinessDay, Result,
    query::{Cursor, FAILURES, INCOMPLETE, MODES, OUTCOMES, Query, STATES, rejection_stage},
    sql::{Predicate, TEXT_INPUT, TEXT_OUTPUT, metric, metric_columns, metrics, rows, scalar},
};

type Counts = BTreeMap<String, i64>;

pub(crate) fn report(db: &Connection, query: &Query, day: BusinessDay, now: i64) -> Result<Value> {
    let admitted = Predicate::usage(query, false, true, now);
    let rejected = Predicate::usage(query, true, true, now);
    let historical = Predicate::usage(query, false, false, now);
    let a = admitted.sql();
    let r = rejected.sql();
    let lifetime = db.query_row(
        &format!(
            "SELECT COALESCE(SUM(state='intent'),0),COALESCE(SUM(state='unknown'),0),
            COALESCE(SUM(CASE WHEN state!='settled' THEN MAX(reserved,estimated) ELSE 0 END),0)
            FROM attempts {}",
            if query.key.is_some() {
                "WHERE key_id=?"
            } else {
                ""
            }
        ),
        params_from_iter(query.key.iter()),
        |row| {
            Ok(json!({
                "keyID": query.key, "inFlight": row.get::<_, i64>(0)?,
                "unknown": row.get::<_, i64>(1)?, "exposureMicros": metric(row, 2)?,
                "scope": "key_only_all_time",
            }))
        },
    )?;
    let historical_count = scalar(
        db,
        &format!(
            "SELECT COUNT(*) FROM attempts WHERE created_at_epoch IS NULL AND {}",
            historical.sql()
        ),
        &historical.values,
    )?;
    let rejection_count = scalar(
        db,
        &format!("SELECT COUNT(*) FROM request_diagnostics WHERE {r}"),
        &rejected.values,
    )?;
    let unknown: Counts = rows(db, &format!(
        "SELECT COALESCE(json_extract(outcome_json,'$.failure'),'unspecified'),COUNT(*)
         FROM attempts WHERE {a} AND (state='unknown' OR closed_unknown_at_epoch IS NOT NULL) GROUP BY 1"
    ), &admitted.values, |row| Ok((row.get(0)?, row.get(1)?)))?.into_iter().collect();
    let first_event = "json_extract(outcome_json,'$.firstEventMilliseconds')";
    let (mut totals, sample_count) = db.query_row(&format!(
        "SELECT COUNT(*),COALESCE(SUM(state='intent'),0),COALESCE(SUM(state='unknown'),0),
            COALESCE(SUM(json_extract(usage_json,'$.completeness')='complete'),0),
            COALESCE(SUM(json_extract(usage_json,'$.completeness')='partial' AND state!='settled'),0),
            COALESCE(SUM(usage_json IS NULL OR (state='settled' AND json_extract(usage_json,'$.completeness')='partial')),0),
            COALESCE(SUM(json_extract(outcome_json,'$.kind')='failed'),0),
            COALESCE(SUM(json_extract(outcome_json,'$.kind')='cancelled'),0),
            COALESCE(SUM(CASE WHEN state!='settled' THEN MAX(reserved,estimated) ELSE 0 END),0),
            {},AVG({first_event}),AVG(json_extract(outcome_json,'$.totalMilliseconds')),COUNT({first_event})
            FROM attempts WHERE {a}", metric_columns(true)), params_from_iter(&admitted.values), |row| {
        Ok((json!({
            "admitted": row.get::<_, i64>(0)?, "recordedRejections": rejection_count,
            "inFlight": row.get::<_, i64>(1)?, "unknown": row.get::<_, i64>(2)?,
            "complete": row.get::<_, i64>(3)?, "partial": row.get::<_, i64>(4)?,
            "unavailable": row.get::<_, i64>(5)?, "failed": row.get::<_, i64>(6)?,
            "cancelled": row.get::<_, i64>(7)?, "unresolvedExposureMicros": metric(row, 8)?,
            "metrics": metrics(Some(row), 9)?, "historicalWithoutTime": historical_count,
            "usageUnknown": unknown.values().sum::<i64>(), "unknownReasons": unknown,
            "averageFirstEventMilliseconds": row.get::<_, Option<f64>>(22)?,
            "averageTotalMilliseconds": row.get::<_, Option<f64>>(23)?,
        }), row.get::<_, i64>(24)?))
    })?;
    let p95 = if sample_count == 0 {
        None
    } else {
        let mut values = admitted.values.clone();
        values.push(((sample_count * 95 + 99) / 100 - 1).into());
        Some(scalar(
            db,
            &format!(
                "SELECT {first_event} FROM attempts WHERE {a} AND {first_event} IS NOT NULL
            ORDER BY {first_event} LIMIT 1 OFFSET ?"
            ),
            &values,
        )?)
    };
    totals["p95FirstEventMilliseconds"] = json!(p95);
    let activity: BTreeMap<i64, (i64, i64)> = rows(db, &format!(
        "SELECT created_at_epoch/3600*3600,COUNT(*),SUM(state!='settled') FROM attempts WHERE {a} GROUP BY 1"
    ), &admitted.values, |row| Ok((row.get(0)?, (row.get(1)?, row.get(2)?))))?.into_iter().collect();
    let refusals: BTreeMap<i64, i64> = rows(
        db,
        &format!(
            "SELECT at_epoch/3600*3600,COUNT(*) FROM request_diagnostics WHERE {r} GROUP BY 1"
        ),
        &rejected.values,
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?
    .into_iter()
    .collect();
    let buckets: Vec<_> = (query.start..query.end)
        .step_by(3600)
        .map(|at| {
            let (admitted, unresolved) = activity.get(&at).copied().unwrap_or_default();
            json!({"atUnixSeconds": at, "admitted": admitted, "unresolved": unresolved,
               "recordedRejections": refusals.get(&at).copied().unwrap_or_default()})
        })
        .collect();

    let (records, next_cursor) = page(db, query, &admitted, &rejected)?;
    let rejection_counts = if query.rejected_only {
        rows(
            db,
            &format!(
                "SELECT failure,reason,COUNT(*) FROM request_diagnostics WHERE {r}
            GROUP BY 1,2 ORDER BY COUNT(*) DESC,1,2"
            ),
            &rejected.values,
            |row| {
                Ok(json!({
                    "failure": required_enum(row, 0, FAILURES)?,
                    "reason": row.get::<_, Option<String>>(1)?.filter(|value| rejection_stage(value).is_some()),
                    "count": row.get::<_, i64>(2)?,
                }))
            },
        )?
    } else {
        Vec::new()
    };
    let key_tokens = if query.key.is_none() && !query.rejected_only {
        let keys = rows(
            db,
            &format!(
                "SELECT key_id,SUM({TEXT_INPUT}),SUM({TEXT_OUTPUT}),
            MAX(COALESCE(json_extract(usage_json,'$.completeness'),'unavailable')!='complete')
            FROM attempts WHERE {a} GROUP BY key_id ORDER BY key_id LIMIT 257"
            ),
            &admitted.values,
            |row| {
                Ok(
                    json!({"keyID": row.get::<_, String>(0)?, "inputTokens": metric(row, 1)?,
                "outputTokens": metric(row, 2)?, "incomplete": row.get::<_, bool>(3)?}),
                )
            },
        )?;
        (keys.len() <= 256).then_some(keys)
    } else {
        None
    };
    Ok(json!({
        "startUnixSeconds": query.start, "endUnixSeconds": query.end,
        "businessDay": day.document(), "timezone": day.timezone(),
        "totals": totals, "lifetimeGovernance": lifetime, "detailRetentionDays": 90,
        "diagnosticsPolicy": {"days": 30, "maximum": 10000, "mayOmitUnderLoad": true},
        "buckets": buckets, "rejectionCounts": rejection_counts, "keyTokens": key_tokens,
        "rows": records, "nextCursor": next_cursor,
    }))
}

fn page(
    db: &Connection,
    query: &Query,
    admitted: &Predicate,
    rejected: &Predicate,
) -> Result<(Vec<Value>, Option<String>)> {
    let mut sql = format!(
        "SELECT h.*,COALESCE(json_extract(k.metadata_json,'$.principal'),CASE WHEN h.mode='priming' THEN 'internal:quota-priming' END),
          json_extract(k.metadata_json,'$.displayName') FROM (
        SELECT 'admitted' kind,'a:'||id cursor_id,id,created_at_epoch at_epoch,key_id,
          json_extract(admission_json,'$.model'),COALESCE(json_extract(admission_json,'$.mode'),'generation') mode,
          identity,request_id,CASE WHEN closed_unknown_at_epoch IS NOT NULL THEN 'closed_unknown' ELSE state END,
          json_extract(outcome_json,'$.kind'),json_extract(outcome_json,'$.failure'),
          CASE WHEN state='settled' AND json_extract(usage_json,'$.completeness')='partial' THEN NULL ELSE json_extract(usage_json,'$.completeness') END,
          {},
          json_extract(outcome_json,'$.firstEventMilliseconds'),json_extract(outcome_json,'$.totalMilliseconds'),
          json_extract(admission_json,'$.reasoningEffort'),json_extract(admission_json,'$.serviceTier'),
          json_extract(outcome_json,'$.actualServiceTier'),COALESCE(json_extract(admission_json,'$.requestMetadataRecorded'),0),
          json_extract(usage_json,'$.svgAuthorModel'),json_extract(usage_json,'$.usageMissingReasons'),
          json_extract(outcome_json,'$.upstreamIncompleteReason'),NULL
         FROM attempts WHERE {}
        UNION ALL
        SELECT 'rejected','r:'||request_id,request_id,at_epoch,key_id,model,mode,NULL,request_id,NULL,'failed',failure,NULL,
          NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
          reasoning_effort,NULL,NULL,0,NULL,NULL,NULL,reason
         FROM request_diagnostics WHERE {}) h
        LEFT JOIN managed_keys k ON k.id=h.key_id",
        metric_columns(false), admitted.sql(), rejected.sql(),
    );
    let mut values: Vec<SqlValue> = admitted
        .values
        .iter()
        .chain(&rejected.values)
        .cloned()
        .collect();
    if let Some(cursor) = &query.cursor {
        sql.push_str(" WHERE (at_epoch,cursor_id)<(?,?)");
        values.extend([cursor.at.into(), cursor.id.clone().into()]);
    }
    sql.push_str(" ORDER BY at_epoch DESC,cursor_id DESC LIMIT ?");
    values.push((query.limit as i64 + 1).into());
    let mut records = rows(db, &sql, &values, record)?;
    let more = records.len() > query.limit;
    if more {
        records.pop();
    }
    let next = if more {
        records.last().map(|(_, cursor)| cursor.encode())
    } else {
        None
    };
    Ok((
        records.into_iter().map(|(record, _)| record).collect(),
        next,
    ))
}

fn record(row: &Row<'_>) -> rusqlite::Result<(Value, Cursor)> {
    let text = |index| row.get::<_, Option<String>>(index);
    let count = |index| row.get::<_, Option<i64>>(index);
    let reason = text(35)?.filter(|value| rejection_stage(value).is_some());
    let missing = text(33)?
        .map(|raw| serde_json::from_str::<Vec<String>>(&raw))
        .transpose()
        .map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                33,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?
        .unwrap_or_default();
    let cursor = Cursor {
        at: row.get(3)?,
        id: row.get(1)?,
    };
    if !(3..=260).contains(&cursor.id.len()) || cursor.id.contains('\0') {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let value = json!({
        "kind": row.get::<_, String>(0)?, "id": row.get::<_, String>(2)?,
        "atUnixSeconds": cursor.at, "keyID": row.get::<_, String>(4)?, "model": text(5)?,
        "mode": required_enum(row, 6, MODES)?, "accountID": text(7)?, "requestID": text(8)?,
        "state": optional_enum(row, 9, STATES)?, "outcome": optional_enum(row, 10, OUTCOMES)?,
        "failure": optional_enum(row, 11, FAILURES)?,
        "completeness": optional_enum(row, 12, &["complete", "partial"])?,
        "metrics": metrics(Some(row), 13)?, "firstEventMilliseconds": count(26)?,
        "totalMilliseconds": count(27)?, "reasoningEffort": text(28)?, "serviceTier": text(29)?,
        "actualServiceTier": text(30)?, "requestMetadataRecorded": row.get::<_, i64>(31)? == 1,
        "svgAuthorModel": text(32)?, "usageMissingReasons": missing,
        "upstreamIncompleteReason": text(34)?.filter(|value| INCOMPLETE.contains(&value.as_str())),
        "rejectionStage": reason.as_deref().and_then(rejection_stage), "rejectionReason": reason,
        "principal": text(36)?, "displayName": text(37)?,
    });
    Ok((value, cursor))
}

pub(crate) fn required_enum(
    row: &Row<'_>,
    index: usize,
    valid: &[&str],
) -> rusqlite::Result<String> {
    optional_enum(row, index, valid)?.ok_or(rusqlite::Error::InvalidQuery)
}

fn optional_enum(row: &Row<'_>, index: usize, valid: &[&str]) -> rusqlite::Result<Option<String>> {
    let text: Option<String> = row.get(index)?;
    if text.as_deref().is_some_and(|value| !valid.contains(&value)) {
        return Err(rusqlite::Error::InvalidQuery);
    }
    Ok(text)
}
