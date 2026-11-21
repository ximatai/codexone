-- v19 initialization from SQLiteConnection.swift at Swift baseline 3c82d71f47b1.
-- The time arguments of the governance migration are synthetic.
PRAGMA auto_vacuum=INCREMENTAL;
PRAGMA foreign_keys=ON;

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

CREATE TABLE managed_keys (id TEXT PRIMARY KEY, digest TEXT NOT NULL UNIQUE, metadata_json TEXT NOT NULL);
CREATE TABLE key_events (id TEXT PRIMARY KEY, key_id TEXT NOT NULL REFERENCES managed_keys(id),
  revision INTEGER NOT NULL, action TEXT NOT NULL, at_epoch INTEGER NOT NULL, metadata_json TEXT NOT NULL);
CREATE INDEX attempts_key ON attempts(key_id,window_id);

CREATE TABLE accounts (id TEXT PRIMARY KEY, namespace TEXT NOT NULL UNIQUE,
  revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 1000000),
  credential_version INTEGER NOT NULL CHECK(credential_version BETWEEN 1 AND 1000000),
  mode TEXT NOT NULL CHECK(mode IN ('enabled','draining','disabled')),
  authorization TEXT NOT NULL CHECK(authorization IN ('ready','refreshing','requires_auth','auth_uncertain')),
  sealed_credential TEXT NOT NULL, refresh_intent TEXT, created_at_epoch INTEGER NOT NULL);
CREATE TABLE account_events (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
  revision INTEGER NOT NULL, action TEXT NOT NULL, metadata_json TEXT NOT NULL, at_epoch INTEGER NOT NULL);

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

CREATE TABLE maintenance_state (id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT NOT NULL, restore_json TEXT);
INSERT INTO maintenance_state VALUES(1, lower(hex(randomblob(16))), NULL);
CREATE TABLE maintenance_events (id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT NOT NULL, record_json TEXT NOT NULL, at_epoch INTEGER NOT NULL);

ALTER TABLE accounts ADD COLUMN display_name TEXT;
CREATE INDEX attempts_in_flight ON attempts(created_at_epoch DESC,id DESC) WHERE state='intent';

ALTER TABLE attempts ADD COLUMN unknown_since_epoch INTEGER;
ALTER TABLE attempts ADD COLUMN closed_unknown_at_epoch INTEGER;
UPDATE attempts SET unknown_since_epoch=COALESCE(json_extract(outcome_json,'$.atUnixSeconds'),created_at_epoch,1728000000) WHERE state='unknown';
UPDATE attempts SET closed_unknown_at_epoch=COALESCE(created_at_epoch,1728000000) WHERE state='settled' AND COALESCE(json_extract(usage_json,'$.completeness'),'')!='complete';
ALTER TABLE bindings ADD COLUMN expires_at_epoch INTEGER;
UPDATE bindings SET expires_at_epoch=1728000000+2592000;
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

CREATE TABLE account_quota_priming(account_id TEXT PRIMARY KEY REFERENCES accounts(id),record_json TEXT NOT NULL CHECK(length(record_json)<=8192));
CREATE TABLE quota_priming_events(id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),windows_json TEXT NOT NULL,model TEXT NOT NULL,result TEXT NOT NULL,at_epoch INTEGER NOT NULL);
CREATE TABLE account_reset_credits(account_id TEXT PRIMARY KEY REFERENCES accounts(id),record_json TEXT NOT NULL CHECK(length(record_json)<=4096));
CREATE TABLE reset_credit_events(id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),action TEXT NOT NULL,code TEXT NOT NULL,automatic INTEGER NOT NULL,credit_hash TEXT,at_epoch INTEGER NOT NULL);

ALTER TABLE usage_daily ADD COLUMN svg_input_tokens INTEGER;
ALTER TABLE usage_daily ADD COLUMN svg_output_tokens INTEGER;
ALTER TABLE usage_daily ADD COLUMN svg_reasoning_tokens INTEGER;
ALTER TABLE usage_daily ADD COLUMN price_unknown INTEGER NOT NULL DEFAULT 0;
UPDATE usage_daily SET price_unknown=CASE WHEN completeness='complete' THEN 0 ELSE requests END;

ALTER TABLE attempts ADD COLUMN output_rate_settled_at INTEGER;
ALTER TABLE attempts ADD COLUMN output_rate TEXT;
CREATE INDEX attempts_output_rate ON attempts(output_rate_settled_at)
  WHERE output_rate_settled_at IS NOT NULL;

ALTER TABLE request_diagnostics ADD COLUMN reason TEXT;

CREATE TABLE account_credit_samples (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  bucket_epoch INTEGER NOT NULL,
  at_epoch INTEGER NOT NULL CHECK(at_epoch BETWEEN 1 AND 1000000000000 AND at_epoch / 300 = bucket_epoch),
  balance TEXT NOT NULL CHECK(length(balance) BETWEEN 1 AND 37),
  PRIMARY KEY(account_id, bucket_epoch)
);
CREATE INDEX account_credit_samples_retention ON account_credit_samples(at_epoch);

CREATE TABLE model_directory(
  singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL, document TEXT NOT NULL);
CREATE TABLE model_directory_routes(model TEXT PRIMARY KEY, account TEXT);

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

ALTER TABLE model_directory_routes ADD COLUMN reasoning_efforts TEXT;

ALTER TABLE request_diagnostics ADD COLUMN reasoning_effort TEXT;

PRAGMA user_version=19;
