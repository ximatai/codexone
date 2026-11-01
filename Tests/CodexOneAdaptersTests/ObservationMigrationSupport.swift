/// Build a physical pre-v5 fixture, rather than stamping an incompatible new schema old.
let removeResetCreditSchema = "DROP TABLE reset_credit_events; DROP TABLE account_reset_credits; "

let removeObservationSchema =
  removeResetCreditSchema + """
    DROP INDEX attempts_active_identity; DROP INDEX attempts_retention; DROP INDEX attempts_unknown_since; ALTER TABLE attempts DROP COLUMN closed_unknown_at_epoch; ALTER TABLE attempts DROP COLUMN unknown_since_epoch; DROP INDEX bindings_expiry; ALTER TABLE bindings DROP COLUMN expires_at_epoch; DROP TABLE usage_daily; DROP TABLE account_concurrency;
    DROP INDEX attempts_in_flight;
    DROP TABLE request_diagnostics;
    DROP TABLE account_model_health;
    DROP TABLE health_models;
    DROP TABLE account_health;
    DROP TABLE account_quota;
    DROP INDEX attempts_created;
    DROP INDEX attempts_request;
    ALTER TABLE attempts DROP COLUMN request_id;
    ALTER TABLE attempts DROP COLUMN outcome_json;
    ALTER TABLE attempts DROP COLUMN created_at_epoch;
    """

let removeGovernanceSchema =
  removeResetCreditSchema
  + "DROP INDEX attempts_active_identity; DROP INDEX attempts_retention; DROP INDEX attempts_unknown_since; ALTER TABLE attempts DROP COLUMN closed_unknown_at_epoch; ALTER TABLE attempts DROP COLUMN unknown_since_epoch; DROP INDEX bindings_expiry; ALTER TABLE bindings DROP COLUMN expires_at_epoch; DROP TABLE usage_daily; DROP TABLE account_concurrency; "
