/// Build a physical pre-v5 fixture, rather than stamping an incompatible new schema old.
let removeObservationSchema = """
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
