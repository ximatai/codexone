// Ordered PRAGMA table_info names from SQLiteConnection at schema 19.
// Unrelated extra objects are permitted, as in the Swift compatibility check.
pub(crate) const TABLE_COLUMNS: &[(&str, &str)] = &[
    (
        "attempts",
        "id principal key_id namespace identity window_id policy_version pricing_version reserved state admission_json usage_json evidence_floor estimated created_at_epoch outcome_json request_id unknown_since_epoch closed_unknown_at_epoch output_rate_settled_at output_rate",
    ),
    (
        "bindings",
        "principal namespace identity object_type raw_id attempt expires_at_epoch",
    ),
    ("evidence", "attempt revision payload"),
    ("metadata", "id limits_json"),
    ("managed_keys", "id digest metadata_json"),
    (
        "key_events",
        "id key_id revision action at_epoch metadata_json",
    ),
    (
        "accounts",
        "id namespace revision credential_version mode authorization sealed_credential refresh_intent created_at_epoch display_name",
    ),
    (
        "account_events",
        "id account_id revision action metadata_json at_epoch",
    ),
    ("account_quota", "account_id record_json"),
    (
        "account_health",
        "account_id auth_rejected_version last_failure at_epoch",
    ),
    ("health_models", "model"),
    (
        "account_model_health",
        "account_id model until_epoch failure",
    ),
    (
        "request_diagnostics",
        "request_id at_epoch key_id model mode failure reason reasoning_effort",
    ),
    ("maintenance_state", "id generation restore_json"),
    ("maintenance_events", "id action record_json at_epoch"),
    ("account_concurrency", "namespace identity at_epoch peak"),
    (
        "usage_daily",
        "day_epoch key_id model mode outcome failure completeness usage_unknown requests last_used_epoch input_tokens output_tokens cached_tokens images estimated_micros image_input_tokens image_output_tokens image_input_text_tokens image_input_image_tokens svg_input_tokens svg_output_tokens svg_reasoning_tokens price_unknown",
    ),
    ("account_quota_priming", "account_id record_json"),
    (
        "quota_priming_events",
        "id account_id windows_json model result at_epoch",
    ),
    ("account_reset_credits", "account_id record_json"),
    (
        "reset_credit_events",
        "id account_id action code automatic credit_hash at_epoch",
    ),
    (
        "account_credit_samples",
        "account_id bucket_epoch at_epoch balance",
    ),
    ("model_directory", "singleton revision document"),
    ("model_directory_routes", "model account reasoning_efforts"),
    (
        "account_quota_cycle_samples",
        "account_id kind bucket_epoch at_epoch remaining reset_epoch duration_seconds",
    ),
];
