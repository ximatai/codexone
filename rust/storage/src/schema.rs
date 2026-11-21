use rusqlite::Connection;

// Ordered PRAGMA table_info names and the versions that introduced them.
// Swift permits unrelated extra objects during compatibility checks.
pub(crate) const TABLE_COLUMNS: &[(&str, &[(i64, &str)])] = &[
    (
        "attempts",
        &[
            (
                1,
                "id principal key_id namespace identity window_id policy_version pricing_version reserved state admission_json usage_json evidence_floor estimated",
            ),
            (5, "created_at_epoch outcome_json request_id"),
            (10, "unknown_since_epoch closed_unknown_at_epoch"),
            (13, "output_rate_settled_at output_rate"),
        ],
    ),
    (
        "bindings",
        &[
            (1, "principal namespace identity object_type raw_id attempt"),
            (10, "expires_at_epoch"),
        ],
    ),
    ("evidence", &[(1, "attempt revision payload")]),
    ("metadata", &[(1, "id limits_json")]),
    ("managed_keys", &[(2, "id digest metadata_json")]),
    (
        "key_events",
        &[(2, "id key_id revision action at_epoch metadata_json")],
    ),
    (
        "accounts",
        &[
            (
                3,
                "id namespace revision credential_version mode authorization sealed_credential refresh_intent created_at_epoch",
            ),
            (9, "display_name"),
        ],
    ),
    (
        "account_events",
        &[(3, "id account_id revision action metadata_json at_epoch")],
    ),
    ("account_quota", &[(5, "account_id record_json")]),
    (
        "account_health",
        &[(5, "account_id auth_rejected_version last_failure at_epoch")],
    ),
    ("health_models", &[(5, "model")]),
    (
        "account_model_health",
        &[(5, "account_id model until_epoch failure")],
    ),
    (
        "request_diagnostics",
        &[
            (5, "request_id at_epoch key_id model mode failure"),
            (14, "reason"),
            (19, "reasoning_effort"),
        ],
    ),
    ("maintenance_state", &[(7, "id generation restore_json")]),
    (
        "maintenance_events",
        &[(7, "id action record_json at_epoch")],
    ),
    (
        "account_concurrency",
        &[(10, "namespace identity at_epoch peak")],
    ),
    (
        "usage_daily",
        &[
            (
                10,
                "day_epoch key_id model mode outcome failure completeness usage_unknown requests last_used_epoch input_tokens output_tokens cached_tokens images estimated_micros image_input_tokens image_output_tokens image_input_text_tokens image_input_image_tokens",
            ),
            (
                12,
                "svg_input_tokens svg_output_tokens svg_reasoning_tokens price_unknown",
            ),
        ],
    ),
    ("account_quota_priming", &[(11, "account_id record_json")]),
    (
        "quota_priming_events",
        &[(11, "id account_id windows_json model result at_epoch")],
    ),
    ("account_reset_credits", &[(11, "account_id record_json")]),
    (
        "reset_credit_events",
        &[(
            11,
            "id account_id action code automatic credit_hash at_epoch",
        )],
    ),
    (
        "account_credit_samples",
        &[(15, "account_id bucket_epoch at_epoch balance")],
    ),
    ("model_directory", &[(16, "singleton revision document")]),
    (
        "model_directory_routes",
        &[(16, "model account"), (18, "reasoning_efforts")],
    ),
    (
        "account_quota_cycle_samples",
        &[(
            17,
            "account_id kind bucket_epoch at_epoch remaining reset_epoch duration_seconds",
        )],
    ),
];

const BASE_SCHEMA: &[(i64, &str)] = &[
    (
        1,
        r"
CREATE TABLE attempts (
  id TEXT PRIMARY KEY, principal TEXT NOT NULL, key_id TEXT NOT NULL,
  namespace TEXT NOT NULL, identity TEXT NOT NULL, window_id TEXT NOT NULL,
  policy_version TEXT NOT NULL, pricing_version TEXT NOT NULL,
  reserved INTEGER NOT NULL CHECK(reserved>=0),
  state TEXT NOT NULL CHECK(state IN ('intent','unknown','settled')),
  admission_json TEXT NOT NULL, usage_json TEXT, evidence_floor INTEGER NOT NULL DEFAULT -1,
  estimated INTEGER NOT NULL DEFAULT 0 CHECK(estimated>=0)
);
CREATE INDEX attempts_principal ON attempts(principal,window_id);
CREATE INDEX attempts_identity ON attempts(namespace,identity,window_id);
CREATE INDEX attempts_window ON attempts(window_id);
CREATE TABLE bindings (
  principal TEXT NOT NULL, namespace TEXT NOT NULL, identity TEXT NOT NULL,
  object_type TEXT NOT NULL, raw_id TEXT NOT NULL,
  attempt TEXT NOT NULL REFERENCES attempts(id),
  PRIMARY KEY(principal,namespace,identity,object_type,raw_id)
);
CREATE INDEX bindings_lookup ON bindings(principal,object_type,raw_id);
CREATE TABLE evidence (
  attempt TEXT NOT NULL REFERENCES attempts(id),
  revision INTEGER NOT NULL CHECK(revision>=0), payload TEXT NOT NULL,
  PRIMARY KEY(attempt,revision)
);
CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK(id=1), limits_json TEXT NOT NULL);
",
    ),
    (
        2,
        r"
CREATE TABLE managed_keys (id TEXT PRIMARY KEY, digest TEXT NOT NULL UNIQUE, metadata_json TEXT NOT NULL);
CREATE TABLE key_events (id TEXT PRIMARY KEY, key_id TEXT NOT NULL REFERENCES managed_keys(id),
  revision INTEGER NOT NULL, action TEXT NOT NULL, at_epoch INTEGER NOT NULL, metadata_json TEXT NOT NULL);
CREATE INDEX attempts_key ON attempts(key_id,window_id);
",
    ),
    (
        3,
        r"
CREATE TABLE accounts (id TEXT PRIMARY KEY, namespace TEXT NOT NULL UNIQUE,
  revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 1000000),
  credential_version INTEGER NOT NULL CHECK(credential_version BETWEEN 1 AND 1000000),
  mode TEXT NOT NULL CHECK(mode IN ('enabled','draining','disabled')),
  authorization TEXT NOT NULL CHECK(authorization IN ('ready','refreshing','requires_auth','auth_uncertain')),
  sealed_credential TEXT NOT NULL, refresh_intent TEXT, created_at_epoch INTEGER NOT NULL);
CREATE TABLE account_events (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
  revision INTEGER NOT NULL, action TEXT NOT NULL, metadata_json TEXT NOT NULL, at_epoch INTEGER NOT NULL);
",
    ),
    (
        5,
        r"
ALTER TABLE attempts ADD COLUMN created_at_epoch INTEGER;
ALTER TABLE attempts ADD COLUMN outcome_json TEXT;
ALTER TABLE attempts ADD COLUMN request_id TEXT;
CREATE INDEX attempts_request ON attempts(request_id);
CREATE INDEX attempts_created ON attempts(created_at_epoch,key_id);
CREATE TABLE account_quota (account_id TEXT PRIMARY KEY REFERENCES accounts(id), record_json TEXT NOT NULL CHECK(length(record_json)<=16384));
CREATE TABLE account_health (account_id TEXT PRIMARY KEY REFERENCES accounts(id),
  auth_rejected_version INTEGER, last_failure TEXT NOT NULL, at_epoch INTEGER NOT NULL);
CREATE TABLE health_models (model TEXT PRIMARY KEY);
CREATE TABLE account_model_health (account_id TEXT NOT NULL REFERENCES accounts(id),
  model TEXT NOT NULL REFERENCES health_models(model) ON DELETE CASCADE,
  until_epoch INTEGER NOT NULL, failure TEXT NOT NULL, PRIMARY KEY(account_id,model));
CREATE TABLE request_diagnostics (request_id TEXT PRIMARY KEY, at_epoch INTEGER NOT NULL,
  key_id TEXT NOT NULL, model TEXT, mode TEXT NOT NULL, failure TEXT NOT NULL);
CREATE INDEX diagnostics_created ON request_diagnostics(at_epoch,request_id);
",
    ),
    (
        7,
        r"
CREATE TABLE maintenance_state (id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT NOT NULL, restore_json TEXT);
INSERT INTO maintenance_state VALUES(1, lower(hex(randomblob(16))), NULL);
CREATE TABLE maintenance_events (id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT NOT NULL, record_json TEXT NOT NULL, at_epoch INTEGER NOT NULL);
",
    ),
    (
        9,
        r"
ALTER TABLE accounts ADD COLUMN display_name TEXT;
CREATE INDEX attempts_in_flight ON attempts(created_at_epoch DESC,id DESC) WHERE state='intent';
",
    ),
];

const LATER_SCHEMA: &[(i64, &str)] = &[
    (
        11,
        r"
CREATE TABLE account_quota_priming(account_id TEXT PRIMARY KEY REFERENCES accounts(id),record_json TEXT NOT NULL CHECK(length(record_json)<=8192));
CREATE TABLE quota_priming_events(id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),windows_json TEXT NOT NULL,model TEXT NOT NULL,result TEXT NOT NULL,at_epoch INTEGER NOT NULL);
CREATE TABLE account_reset_credits(account_id TEXT PRIMARY KEY REFERENCES accounts(id),record_json TEXT NOT NULL CHECK(length(record_json)<=4096));
CREATE TABLE reset_credit_events(id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),action TEXT NOT NULL,code TEXT NOT NULL,automatic INTEGER NOT NULL,credit_hash TEXT,at_epoch INTEGER NOT NULL);
",
    ),
    (
        12,
        r"
ALTER TABLE usage_daily ADD COLUMN svg_input_tokens INTEGER;
ALTER TABLE usage_daily ADD COLUMN svg_output_tokens INTEGER;
ALTER TABLE usage_daily ADD COLUMN svg_reasoning_tokens INTEGER;
ALTER TABLE usage_daily ADD COLUMN price_unknown INTEGER NOT NULL DEFAULT 0;
UPDATE usage_daily SET price_unknown=CASE WHEN completeness='complete' THEN 0 ELSE requests END;
",
    ),
    (
        13,
        r"
ALTER TABLE attempts ADD COLUMN output_rate_settled_at INTEGER;
ALTER TABLE attempts ADD COLUMN output_rate TEXT;
CREATE INDEX attempts_output_rate ON attempts(output_rate_settled_at)
  WHERE output_rate_settled_at IS NOT NULL;
",
    ),
    (
        14,
        r"
ALTER TABLE request_diagnostics ADD COLUMN reason TEXT;
",
    ),
    (
        15,
        r"
CREATE TABLE account_credit_samples (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  bucket_epoch INTEGER NOT NULL,
  at_epoch INTEGER NOT NULL CHECK(at_epoch BETWEEN 1 AND 1000000000000 AND at_epoch / 300 = bucket_epoch),
  balance TEXT NOT NULL CHECK(length(balance) BETWEEN 1 AND 37),
  PRIMARY KEY(account_id, bucket_epoch)
);
CREATE INDEX account_credit_samples_retention ON account_credit_samples(at_epoch);
",
    ),
    (
        16,
        r"
CREATE TABLE model_directory(
  singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL, document TEXT NOT NULL);
CREATE TABLE model_directory_routes(model TEXT PRIMARY KEY, account TEXT);
",
    ),
    (
        17,
        r"
CREATE TABLE account_quota_cycle_samples (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind INTEGER NOT NULL CHECK(kind IN (0,1)),
  bucket_epoch INTEGER NOT NULL,
  at_epoch INTEGER NOT NULL CHECK(at_epoch BETWEEN 1 AND 1000000000000 AND at_epoch / 300 = bucket_epoch),
  remaining TEXT NOT NULL CHECK(length(remaining) BETWEEN 1 AND 32),
  reset_epoch INTEGER NOT NULL CHECK(reset_epoch BETWEEN 1 AND 1000000000000),
  duration_seconds INTEGER NOT NULL CHECK(duration_seconds BETWEEN 1 AND 31536000),
  PRIMARY KEY(account_id, kind, bucket_epoch)
);
",
    ),
    (
        18,
        r"
ALTER TABLE model_directory_routes ADD COLUMN reasoning_efforts TEXT;
",
    ),
    (
        19,
        r"
ALTER TABLE request_diagnostics ADD COLUMN reasoning_effort TEXT;
",
    ),
];

// DDL and backfills follow the SQLiteConnection compatibility baseline, including
// the original column order, partial indexes, defaults, and foreign keys.
pub(crate) fn apply_migrations(
    connection: &Connection,
    from: i64,
    to: i64,
    now: i64,
) -> rusqlite::Result<()> {
    for &(version, ddl) in BASE_SCHEMA {
        if from < version && version <= to {
            connection.execute_batch(ddl)?;
        }
    }
    if from < 10 && to >= 10 {
        apply_governance(connection, now)?;
    }
    for &(version, ddl) in LATER_SCHEMA {
        if from < version && version <= to {
            connection.execute_batch(ddl)?;
        }
    }
    connection.pragma_update(None, "user_version", to)
}

fn apply_governance(connection: &Connection, now: i64) -> rusqlite::Result<()> {
    connection.execute_batch(
        "ALTER TABLE attempts ADD COLUMN unknown_since_epoch INTEGER;
         ALTER TABLE attempts ADD COLUMN closed_unknown_at_epoch INTEGER;
         ALTER TABLE bindings ADD COLUMN expires_at_epoch INTEGER;",
    )?;
    connection.execute(
        "UPDATE attempts SET unknown_since_epoch=COALESCE(json_extract(outcome_json,'$.atUnixSeconds'),created_at_epoch,?1)
         WHERE state='unknown'",
        [now],
    )?;
    connection.execute(
        "UPDATE attempts SET closed_unknown_at_epoch=COALESCE(created_at_epoch,?1)
         WHERE state='settled' AND COALESCE(json_extract(usage_json,'$.completeness'),'')!='complete'",
        [now],
    )?;
    connection.execute(
        "UPDATE bindings SET expires_at_epoch=?1",
        [now + 30 * 86400],
    )?;
    connection.execute_batch(r"
CREATE INDEX bindings_expiry ON bindings(expires_at_epoch);
CREATE INDEX attempts_active_identity ON attempts(namespace,identity) WHERE state='intent';
CREATE INDEX attempts_retention ON attempts(created_at_epoch,id) WHERE state='settled';
CREATE INDEX attempts_unknown_since ON attempts(unknown_since_epoch,id) WHERE state='unknown';
CREATE TABLE account_concurrency(namespace TEXT NOT NULL,identity TEXT NOT NULL,at_epoch INTEGER NOT NULL,peak INTEGER NOT NULL,PRIMARY KEY(namespace,identity,at_epoch));
CREATE TABLE usage_daily(
  day_epoch INTEGER NOT NULL,key_id TEXT NOT NULL,model TEXT NOT NULL,mode TEXT NOT NULL,
  outcome TEXT NOT NULL,failure TEXT NOT NULL,completeness TEXT NOT NULL,usage_unknown INTEGER NOT NULL,
  requests INTEGER NOT NULL,last_used_epoch INTEGER NOT NULL,
  input_tokens INTEGER,output_tokens INTEGER,cached_tokens INTEGER,images INTEGER,estimated_micros INTEGER,
  image_input_tokens INTEGER,image_output_tokens INTEGER,image_input_text_tokens INTEGER,image_input_image_tokens INTEGER,
  PRIMARY KEY(day_epoch,key_id,model,mode,outcome,failure,completeness,usage_unknown));
CREATE INDEX usage_daily_key ON usage_daily(key_id,last_used_epoch);
")
}
