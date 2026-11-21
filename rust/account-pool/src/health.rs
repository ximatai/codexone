use std::{collections::HashMap, time::Duration};

use rusqlite::{OptionalExtension, Transaction, params};

use crate::{
    Error, Identity, MAX_TIME, MICROS_PER_SECOND, Result, routing::Candidate, unix_seconds,
    valid_field,
};

const STEP_SECONDS: [i64; 5] = [1, 2, 4, 8, 15];
const OVERLOADED: &str = "upstream_unavailable";
const RATE_LIMITED: &str = "rate_limited";
const REJECTED: &str = "authentication_rejected";

/// The writer's process-local pacing state. Recreate it on restart; SQLite retains deadlines.
#[derive(Default)]
pub struct Health {
    pacing: HashMap<Identity, HashMap<String, Pacing>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HealthOutcome {
    Succeeded,
    AuthenticationRejected,
    RateLimited { cooldown_seconds: Option<i64> },
    UpstreamUnavailable { cooldown_seconds: Option<i64> },
}

pub struct HealthObservation<'a> {
    pub identity: &'a Identity,
    pub credential_version: i64,
    pub model: Option<&'a str>,
    pub outcome: HealthOutcome,
    pub at_unix_seconds: i64,
}

#[derive(Clone, Copy)]
struct Pacing {
    failures: usize,
    until_micros: i64,
}

impl Pacing {
    fn persisted_until(self) -> i64 {
        (self.until_micros + MICROS_PER_SECOND - 1) / MICROS_PER_SECOND
    }
}

/// Apply this mutation only after its SQLite transaction commits. Drop it on rollback.
#[must_use]
pub struct HealthUpdate(Option<(Identity, String, Option<Pacing>)>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Availability {
    Ready,
    Blocked,
    Pacing(Duration),
}

impl Health {
    fn pacing(&self, identity: &Identity, model: &str, persisted_until: i64) -> Pacing {
        let state = self
            .pacing
            .get(identity)
            .and_then(|models| models.get(model));
        Pacing {
            failures: state.map_or(0, |value| value.failures),
            until_micros: state
                .filter(|value| value.persisted_until() == persisted_until)
                .map_or(persisted_until * MICROS_PER_SECOND, |value| {
                    value.until_micros
                }),
        }
    }

    pub(crate) fn availability(
        &self,
        tx: &Transaction<'_>,
        candidate: &Candidate,
        model: &str,
        now_micros: i64,
    ) -> Result<Availability> {
        let rejected: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM account_health WHERE account_id=?1 AND auth_rejected_version=?2)",
            params![candidate.identity.id, candidate.credential_version], |row| row.get(0),
        )?;
        if rejected {
            return Ok(Availability::Blocked);
        }
        let cooldown: Option<(i64, String)> = tx.query_row(
            "SELECT until_epoch,failure FROM account_model_health WHERE account_id=?1 AND model=?2 AND until_epoch>?3",
            params![candidate.identity.id, model, unix_seconds(now_micros)?],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?;
        let Some((until, failure)) = cooldown else {
            return Ok(Availability::Ready);
        };
        match failure.as_str() {
            RATE_LIMITED if valid_deadline(until) => Ok(Availability::Blocked),
            OVERLOADED if valid_deadline(until) => {
                let exact = self.pacing(&candidate.identity, model, until).until_micros;
                if exact <= now_micros {
                    Ok(Availability::Ready)
                } else {
                    Ok(Availability::Pacing(Duration::from_micros(
                        (exact - now_micros) as u64,
                    )))
                }
            }
            _ => Err(Error::StorageUnavailable),
        }
    }

    /// Stage a trusted terminal outcome after the ledger's idempotence check, inside its
    /// finalization transaction. Call only for the first durable outcome of an attempt.
    pub fn record(
        &self,
        tx: &Transaction<'_>,
        observation: HealthObservation<'_>,
        now_micros: i64,
    ) -> Result<HealthUpdate> {
        let HealthObservation {
            identity,
            credential_version,
            model,
            outcome,
            at_unix_seconds,
        } = observation;
        let now = unix_seconds(now_micros)?;
        let cooldown = match outcome {
            HealthOutcome::RateLimited { cooldown_seconds }
            | HealthOutcome::UpstreamUnavailable { cooldown_seconds } => cooldown_seconds,
            _ => None,
        };
        if !identity.valid()
            || !(1..=1_000_000).contains(&credential_version)
            || model.is_some_and(|value| !valid_field(value, 128))
            || !(1..=MAX_TIME).contains(&at_unix_seconds)
            || cooldown.is_some_and(|value| !(1..=3600).contains(&value))
        {
            return Err(Error::InvalidCommand);
        }
        let current: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND namespace=?2 AND credential_version=?3)",
            params![identity.id, identity.namespace, credential_version], |row| row.get(0),
        )?;
        if !current {
            return Ok(HealthUpdate(None));
        }
        if outcome == HealthOutcome::Succeeded {
            if let Some(model) = model {
                tx.execute(
                    "DELETE FROM account_model_health WHERE account_id=?1 AND model=?2 AND failure=?3",
                    params![identity.id, model, OVERLOADED],
                )?;
                return Ok(HealthUpdate(Some((
                    identity.clone(),
                    model.to_owned(),
                    None,
                ))));
            }
            return Ok(HealthUpdate(None));
        }
        let (failure, rejected) = match outcome {
            HealthOutcome::AuthenticationRejected => (REJECTED, Some(credential_version)),
            HealthOutcome::RateLimited { .. } => (RATE_LIMITED, None),
            HealthOutcome::UpstreamUnavailable { .. } => (OVERLOADED, None),
            HealthOutcome::Succeeded => unreachable!("handled above"),
        };
        tx.execute(
            "INSERT INTO account_health VALUES(?1,?2,?3,?4) ON CONFLICT(account_id) DO UPDATE SET
             auth_rejected_version=COALESCE(excluded.auth_rejected_version,auth_rejected_version),
             last_failure=CASE WHEN excluded.at_epoch>=at_epoch THEN excluded.last_failure ELSE last_failure END,
             at_epoch=MAX(at_epoch,excluded.at_epoch)",
            params![identity.id, rejected, failure, at_unix_seconds],
        )?;
        let Some(model) = model.filter(|_| rejected.is_none()) else {
            return Ok(HealthUpdate(None));
        };
        let configured: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM health_models WHERE model=?1)",
            [model],
            |row| row.get(0),
        )?;
        if !configured {
            return Ok(HealthUpdate(None));
        }
        let (until, update) = if failure == OVERLOADED {
            let previous_until = tx.query_row(
                "SELECT until_epoch FROM account_model_health WHERE account_id=?1 AND model=?2 AND failure=?3",
                params![identity.id, model, OVERLOADED], |row| row.get::<_, i64>(0),
            ).optional()?.unwrap_or(0);
            if !valid_deadline(previous_until) {
                return Err(Error::StorageUnavailable);
            }
            let mut pacing = self.pacing(identity, model, previous_until);
            let next = if let Some(delay) = cooldown {
                (at_unix_seconds + delay) * MICROS_PER_SECOND
            } else {
                pacing.failures = STEP_SECONDS.len().min(pacing.failures + 1);
                let base = if now == at_unix_seconds {
                    now_micros
                } else {
                    at_unix_seconds * MICROS_PER_SECOND
                };
                base + STEP_SECONDS[pacing.failures - 1] * MICROS_PER_SECOND
            };
            pacing.until_micros = pacing.until_micros.max(next);
            (
                pacing.persisted_until(),
                Some((identity.clone(), model.to_owned(), Some(pacing))),
            )
        } else {
            (at_unix_seconds + cooldown.unwrap_or(30), None)
        };
        tx.execute(
            "INSERT INTO account_model_health VALUES(?1,?2,?3,?4) ON CONFLICT(account_id,model) DO UPDATE SET
             failure=CASE WHEN excluded.until_epoch>=until_epoch THEN excluded.failure ELSE failure END,
             until_epoch=MAX(until_epoch,excluded.until_epoch)",
            params![identity.id, model, until, failure],
        )?;
        Ok(HealthUpdate(update))
    }

    pub fn apply(&mut self, update: HealthUpdate) {
        match update.0 {
            Some((identity, model, Some(pacing))) => {
                self.pacing
                    .entry(identity)
                    .or_default()
                    .insert(model, pacing);
            }
            Some((identity, model, None)) => {
                if let Some(models) = self.pacing.get_mut(&identity) {
                    models.remove(&model);
                    if models.is_empty() {
                        self.pacing.remove(&identity);
                    }
                }
            }
            None => {}
        }
    }

    /// After committing a configured-model change, discard removed models' streaks.
    pub fn retain_models(&mut self, mut configured: impl FnMut(&str) -> bool) {
        self.pacing.retain(|_, models| {
            models.retain(|model, _| configured(model));
            !models.is_empty()
        });
    }
}

fn valid_deadline(until: i64) -> bool {
    (0..=MAX_TIME + 3600).contains(&until)
}
