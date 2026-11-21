use std::{future::Future, sync::Arc, time::Duration};

use codexone_execution::{
    AccountDispatch, Execution, ExecutionError, ExecutionService, Failure, Outcome,
    PrimingAdmission,
};
use codexone_governance::{
    AccountMode, AuthorizationState, Error, Governance, Result, Work, Writer,
    change_quota_settings, quota_account,
};
use codexone_http_upstream::{CancellationToken, HeaderMap, Instant};
use codexone_identity_runtime::{IdentityRuntime, priming::PrimingState};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

use crate::{PrimingSettings, valid_id};

const EFFORTS: &[&str] = &[
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
];

/// Current configured conversation-model capabilities, supplied by the gateway catalog.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrimingModel {
    pub catalog_revision: Option<i64>,
    pub account: Option<String>,
    pub id: String,
    pub input_micros_per_million: i64,
    pub output_micros_per_million: i64,
    pub reasoning_efforts: Vec<String>,
    pub supports_verbosity: bool,
}

impl PrimingModel {
    fn effort(&self) -> &str {
        EFFORTS
            .iter()
            .copied()
            .find(|effort| self.reasoning_efforts.iter().any(|e| e == effort))
            .unwrap_or("low")
    }
}

pub struct PrimingRequest {
    pub headers: HeaderMap,
    pub body: Value,
    pub model: PrimingModel,
}

/// Use the configured Responses HTTP or WS transport, with normal usage evidence.
/// This trusted entry point already owns a dispatched execution lease. Drain or
/// close transport on cancellation before returning, and never retry or pool-route.
pub trait PrimingTransport: Send + Sync + 'static {
    fn exchange(
        &self,
        request: PrimingRequest,
        execution: &mut Execution,
        stop: CancellationToken,
        deadline: Instant,
    ) -> impl Future<Output = Option<Outcome>> + Send;
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrimingStatus {
    pub revision: i64,
    pub settings: PrimingSettings,
    pub models: Vec<String>,
    pub default_model: Option<String>,
    pub last_attempt_at: Option<i64>,
    pub last_result: Option<String>,
    pub attention: Option<String>,
}

#[derive(Clone)]
pub struct PrimingSignals {
    hints: mpsc::Sender<String>,
    stop: CancellationToken,
}

impl PrimingSignals {
    pub fn observed_quota(&self, id: &str) {
        if valid_id(id) && !self.stop.is_cancelled() {
            let _ = self.hints.try_send(id.into());
        }
    }

    /// Join the task running the supervisor before shutting down execution or identity.
    pub fn stop(&self) {
        self.stop.cancel();
    }
}

/// One worker owns the entire quota generation lifecycle.
pub struct PrimingSupervisor<W, T> {
    writer: W,
    governance: Arc<Governance<W>>,
    identity: IdentityRuntime<W>,
    execution: ExecutionService,
    transport: T,
    models: Arc<dyn Fn() -> Vec<PrimingModel> + Send + Sync>,
    reserved_micros: i64,
    signals: PrimingSignals,
}

impl<W: Writer, T: PrimingTransport> PrimingSupervisor<W, T> {
    pub fn new(
        writer: W,
        governance: Arc<Governance<W>>,
        identity: IdentityRuntime<W>,
        execution: ExecutionService,
        transport: T,
        reserved_micros: i64,
        models: impl Fn() -> Vec<PrimingModel> + Send + Sync + 'static,
    ) -> (Arc<Self>, PrimingSignals, PrimingWorker<W, T>) {
        let (hints, inbox) = mpsc::channel(64);
        let signals = PrimingSignals {
            hints,
            stop: CancellationToken::new(),
        };
        let owner = Arc::new(Self {
            writer,
            governance,
            identity,
            execution,
            transport,
            models: Arc::new(models),
            reserved_micros,
            signals: signals.clone(),
        });
        (owner.clone(), signals, PrimingWorker { owner, inbox })
    }

    fn models(&self, account: &str) -> (Option<i64>, Vec<PrimingModel>) {
        let catalog = (self.models)();
        let revision = catalog.first().and_then(|model| model.catalog_revision);
        (revision, models_for_account(catalog, account))
    }

    fn status_from(&self, state: PrimingState, models: Vec<PrimingModel>) -> PrimingStatus {
        PrimingStatus {
            revision: state.revision,
            settings: state.settings,
            default_model: models.first().map(|model| model.id.clone()),
            models: models.into_iter().map(|model| model.id).collect(),
            last_attempt_at: state.last_attempt_at,
            last_result: state.last_result,
            attention: state.attention,
        }
    }

    pub async fn status(&self, id: &str) -> Result<PrimingStatus> {
        let (state, _, _) = self.snapshot(id).await?;
        Ok(self.status_from(state, self.models(id).1))
    }

    async fn snapshot(&self, id: &str) -> Result<(PrimingState, bool, i64)> {
        if !valid_id(id) {
            return Err(Error::InvalidCommand);
        }
        let id = id.to_owned();
        self.writer
            .run(Work::Read, move |db, now, allowed| {
                let account = quota_account(db.connection(), &id)?;
                let mut state = PrimingState::load(db.connection(), &id)?;
                state.revision = account.revision;
                let eligible = allowed
                    && account.mode == AccountMode::Enabled
                    && account.authorization == AuthorizationState::Ready;
                Ok((state, eligible, now))
            })
            .await
    }

    pub async fn set_settings(
        &self,
        id: &str,
        revision: i64,
        settings: PrimingSettings,
    ) -> Result<PrimingStatus> {
        if !valid_id(id) {
            return Err(Error::InvalidCommand);
        }
        settings.validate()?;
        let (catalog_revision, models) = self.models(id);
        if (settings.enabled && models.is_empty())
            || settings
                .model
                .as_ref()
                .is_some_and(|model| models.iter().all(|m| m.id != *model))
        {
            return Err(Error::InvalidCommand);
        }
        let owned = id.to_owned();
        let work = if settings.enabled {
            Work::Optional
        } else {
            Work::Restrict
        };
        let state = self
            .writer
            .run(work, move |db, now, _| {
                let tx = db.begin_immediate()?;
                check_catalog_revision(&tx, catalog_revision)?;
                let mut state = PrimingState::load(&tx, &owned)?;
                state.revision =
                    change_quota_settings(&tx, &owned, revision, "quota_priming_settings", now)?;
                state.settings = settings;
                state.failures = 0;
                state.attention = None;
                state.save(&tx, &owned)?;
                tx.commit()?;
                Ok(state)
            })
            .await?;
        self.signals.observed_quota(id);
        Ok(self.status_from(state, models))
    }

    async fn disable_removed_model(
        &self,
        id: &str,
        revision: i64,
        catalog_revision: Option<i64>,
    ) -> Result<()> {
        let id = id.to_owned();
        self.writer
            .run(Work::Restrict, move |db, now, _| {
                let tx = db.begin_immediate()?;
                let mut state = PrimingState::load(&tx, &id)?;
                check_catalog_revision(&tx, catalog_revision)?;
                if state.settings.enabled {
                    state.revision = change_quota_settings(
                        &tx,
                        &id,
                        revision,
                        "quota_priming_model_removed",
                        now,
                    )?;
                    state.settings.enabled = false;
                    state.attention = Some("model_removed".into());
                    state.save(&tx, &id)?;
                }
                tx.commit()?;
                Ok(())
            })
            .await
    }

    async fn cycle(&self, id: &str, deadline: Instant) -> Result<()> {
        let (state, eligible, now) = self.snapshot(id).await?;
        if !state.settings.enabled {
            return Ok(());
        }
        let (catalog_revision, models) = self.models(id);
        let model = selected(&models, &state.settings);
        let Some(model) = model else {
            return self
                .disable_removed_model(id, state.revision, catalog_revision)
                .await;
        };
        if !eligible || !state.ready(&self.identity.quota(id).await?, now) {
            return Ok(());
        }
        let work = tokio::select! {
            biased;
            _ = self.signals.stop.cancelled() => return Ok(()),
            work = tokio::time::timeout_at(deadline, self.identity.prepare_dispatch(id, false)) => {
                match work { Ok(work) => work?, Err(_) => return Ok(()) }
            }
        };
        if self.signals.stop.is_cancelled() || Instant::now() >= deadline {
            return Ok(());
        }
        if work.account.revision != state.revision
            || selected(&self.models(id).1, &state.settings) != Some(model)
        {
            return Err(Error::AccountConflict);
        }
        let effort = model.effort();
        let mut body = json!({
            "model": model.id, "input": state.settings.message,
            "instructions": "Reply with one word.", "tools": [], "store": false,
            "stream": true, "reasoning": { "effort": effort },
        });
        if model.supports_verbosity {
            body["text"] = json!({"verbosity": "low"});
        }
        let account = AccountDispatch::from_subscription(&work);
        let pricing_version = format!(
            "{:x}",
            Sha256::digest(format!(
                "{}:{}",
                model.input_micros_per_million, model.output_micros_per_million
            ))
        );
        let admission = self.execution.admit_priming(PrimingAdmission {
            attempt: uuid::Uuid::new_v4().to_string().to_ascii_uppercase(),
            account,
            model: model.id.clone(),
            catalog_revision: model.catalog_revision,
            settings: state.settings,
            pricing_version,
            reasoning_effort: effort.into(),
            reserved_micros: self.reserved_micros,
        });
        let mut lease = tokio::select! {
            biased;
            _ = self.signals.stop.cancelled() => return Ok(()),
            result = tokio::time::timeout_at(deadline, admission) => {
                match result {
                    Ok(lease) => lease.map_err(execution_error)?,
                    Err(_) => return Ok(()),
                }
            }
        };
        if self.signals.stop.is_cancelled() || Instant::now() >= deadline {
            return Ok(());
        }
        lease.begin_dispatch().map_err(execution_error)?;
        let token = self.signals.stop.child_token();
        let account_stop = lease.account_stop_token().cloned();
        let outcome = {
            let exchange = self.transport.exchange(
                PrimingRequest {
                    headers: work.headers,
                    body,
                    model: model.clone(),
                },
                &mut lease,
                token.clone(),
                deadline,
            );
            tokio::pin!(exchange);
            tokio::select! {
                biased;
                outcome = &mut exchange => outcome,
                _ = self.signals.stop.cancelled() => {
                    token.cancel();
                    exchange.await
                }
                _ = async {
                    if let Some(account_stop) = account_stop { account_stop.cancelled().await; }
                    else { std::future::pending::<()>().await; }
                } => {
                    token.cancel();
                    exchange.await
                }
                _ = tokio::time::sleep_until(deadline) => {
                    token.cancel();
                    exchange.await.or_else(|| Some(Outcome::new(Some(Failure::DeadlineExceeded), now)))
                }
            }
        };
        lease.finish(outcome).map_err(execution_error)
    }
}

fn check_catalog_revision(db: &rusqlite::Connection, expected: Option<i64>) -> Result<()> {
    if let Some(expected) = expected {
        let revision: i64 = db.query_row(
            "SELECT coalesce((SELECT revision FROM model_directory WHERE singleton=1),0)",
            [],
            |row| row.get(0),
        )?;
        if expected != revision {
            return Err(Error::AccountConflict);
        }
    }
    Ok(())
}

fn models_for_account(mut models: Vec<PrimingModel>, account: &str) -> Vec<PrimingModel> {
    models.retain(|model| {
        model
            .account
            .as_deref()
            .is_none_or(|owner| owner == account)
    });
    models.sort_by(|a, b| {
        let price = |model: &PrimingModel| {
            i128::from(model.input_micros_per_million) + i128::from(model.output_micros_per_million)
        };
        price(a).cmp(&price(b)).then_with(|| a.id.cmp(&b.id))
    });
    models
}

fn selected<'a>(
    models: &'a [PrimingModel],
    settings: &PrimingSettings,
) -> Option<&'a PrimingModel> {
    match &settings.model {
        Some(id) => models.iter().find(|model| &model.id == id),
        None => models.first(),
    }
}

fn execution_error(error: ExecutionError) -> Error {
    match error {
        ExecutionError::StorageUnavailable | ExecutionError::Database(_) => Error::Unavailable,
        ExecutionError::Capacity => Error::Capacity,
        ExecutionError::StoragePressure => Error::StoragePressure,
        _ => Error::AccountConflict,
    }
}

/// The assembly owns this single worker future and joins it on shutdown.
pub struct PrimingWorker<W, T> {
    owner: Arc<PrimingSupervisor<W, T>>,
    inbox: mpsc::Receiver<String>,
}

impl<W: Writer, T: PrimingTransport> PrimingWorker<W, T> {
    pub async fn run(mut self) -> Result<()> {
        let stop = self.owner.signals.stop.clone();
        let result = self.run_cycles().await;
        stop.cancel();
        result
    }

    async fn run_cycles(&mut self) -> Result<()> {
        let stop = &self.owner.signals.stop;
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            let id = tokio::select! {
                biased;
                _ = stop.cancelled() => return Ok(()),
                _ = interval.tick() => {
                    match self.owner.governance.list_accounts(None).await {
                        Ok(accounts) => {
                            for account in accounts { self.owner.signals.observed_quota(&account.id); }
                        }
                        Err(error @ (Error::Unavailable | Error::AccountStorageUnavailable)) => return Err(error),
                        Err(_) => {}
                    }
                    continue;
                }
                id = self.inbox.recv() => id,
            };
            let Some(id) = id else {
                return Ok(());
            };
            let deadline = Instant::now() + Duration::from_secs(20);
            let cycle = self.owner.cycle(&id, deadline);
            // The cycle's transport owns cleanup. Credential preparation is itself
            // bounded and shares the identity runtime's refresh owner.
            if let Err(error @ (Error::Unavailable | Error::AccountStorageUnavailable)) =
                cycle.await
            {
                return Err(error);
            }
        }
    }
}
