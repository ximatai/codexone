use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use codexone_governance::{
    Account, AccountMode, AccountRuntime, AuthorizationState, Error, Governance, RefreshService,
    Result, Work, Writer,
};
use codexone_http_upstream::{CancellationToken, Instant};
use codexone_storage::AccountCredentialCipher;
use http::HeaderMap;
use serde_json::{Value, json};
use tokio::sync::{Semaphore, watch};

use crate::{Observation, QuotaFailure, SubscriptionProvider, UsageCredits, store};

const CAPACITY: usize = 64;
const PARALLEL: usize = 4;
const PERIOD: Duration = Duration::from_secs(60);
const JOB_TIMEOUT: Duration = Duration::from_secs(20);
const PROACTIVE_WINDOW: i64 = 15 * 60;
const DISPATCH_WINDOW: i64 = 5 * 60;

type Reply = watch::Receiver<Option<Result<Observation>>>;

struct Job {
    reply: Reply,
    manual: bool,
}

struct Inner<W> {
    writer: W,
    governance: Arc<Governance<W>>,
    cipher: AccountCredentialCipher,
    provider: SubscriptionProvider,
    refresh: RefreshService<W, SubscriptionProvider>,
    jobs: Mutex<HashMap<String, Job>>,
    waiters: Semaphore,
    parallel: Semaphore,
    stop: CancellationToken,
    periodic: AtomicBool,
    failed: AtomicBool,
}

/// A prepared subscription identity. Recheck the returned revision, credential version,
/// expiry and route mode in the execution admission transaction before using the headers.
pub struct DispatchCredential {
    pub account: Account,
    pub expires_at_unix_seconds: i64,
    pub headers: HeaderMap,
}

pub struct IdentityRuntime<W> {
    inner: Arc<Inner<W>>,
}

impl<W> Clone for IdentityRuntime<W> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

impl<W: Writer> IdentityRuntime<W> {
    /// All commands use the same writer used to construct governance. Supply the same keyring.
    pub fn new(
        writer: W,
        governance: Arc<Governance<W>>,
        cipher: AccountCredentialCipher,
        provider: SubscriptionProvider,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                writer,
                cipher,
                refresh: RefreshService::new(governance.clone(), provider.clone()),
                governance,
                provider,
                jobs: Mutex::new(HashMap::new()),
                waiters: Semaphore::new(CAPACITY),
                parallel: Semaphore::new(PARALLEL),
                stop: CancellationToken::new(),
                periodic: AtomicBool::new(false),
                failed: AtomicBool::new(false),
            }),
        }
    }

    /// Join the same per-identity owner as dispatch and periodic observation.
    pub async fn refresh_account(&self, id: String, revision: i64) -> Result<Account> {
        if self.inner.stop.is_cancelled() {
            return Err(Error::AuthorizationUnavailable);
        }
        self.inner.refresh.refresh_account(id, revision).await
    }

    pub async fn prepare_dispatch(
        &self,
        id: &str,
        continuation: bool,
    ) -> Result<DispatchCredential> {
        validate_id(id)?;
        if self.inner.stop.is_cancelled() {
            return Err(Error::AuthorizationUnavailable);
        }
        let mut record = self.load(id, false).await?;
        self.check_dispatch_mode(&record.account, continuation)?;
        let needs_refresh = match record.account.authorization {
            AuthorizationState::Refreshing => true,
            AuthorizationState::Ready => {
                let credential = record
                    .open(&self.inner.cipher)
                    .ok_or(Error::AuthorizationUnavailable)?;
                credential.expires_at_unix_seconds() - self.inner.provider.now() <= DISPATCH_WINDOW
            }
            _ => return Err(Error::AuthorizationUnavailable),
        };
        if needs_refresh {
            self.inner
                .refresh
                .refresh_for_dispatch(&record.account)
                .await?;
            record = self.load(id, false).await?;
        }
        self.check_dispatch_mode(&record.account, continuation)?;
        if self.inner.stop.is_cancelled()
            || record.account.authorization != AuthorizationState::Ready
        {
            return Err(Error::AuthorizationUnavailable);
        }
        let credential = record
            .open(&self.inner.cipher)
            .ok_or(Error::AuthorizationUnavailable)?;
        let headers = self
            .inner
            .provider
            .verified_headers(&record.account.namespace, &credential)
            .ok_or(Error::AuthorizationUnavailable)?;
        Ok(DispatchCredential {
            account: record.account,
            expires_at_unix_seconds: credential.expires_at_unix_seconds(),
            headers,
        })
    }

    fn check_dispatch_mode(&self, account: &Account, continuation: bool) -> Result<()> {
        match account.mode {
            AccountMode::Enabled => Ok(()),
            AccountMode::Draining if continuation => Ok(()),
            _ => Err(Error::AuthorizationUnavailable),
        }
    }

    /// Schedule a passive GET and await its shared durable result. Cancelling the
    /// waiter releases its slot while the owner continues the observation.
    pub async fn observe_account(&self, id: &str) -> Result<Observation> {
        validate_id(id)?;
        let _waiter = self
            .inner
            .waiters
            .try_acquire()
            .map_err(|_| Error::Capacity)?;
        wait(self.enqueue(id, true)?).await
    }

    pub async fn quota(&self, id: &str) -> Result<Observation> {
        validate_id(id)?;
        let id = id.to_owned();
        self.inner
            .writer
            .run(Work::Read, move |db, _, _| {
                store::load(db.connection(), &id)?;
                store::load_quota(db.connection(), &id)
            })
            .await
    }

    /// One scan. Callers may use this for deterministic scheduling and tests.
    pub async fn schedule_cycle(&self) -> Result<()> {
        if self.inner.stop.is_cancelled() {
            return Err(Error::AuthorizationUnavailable);
        }
        for account in self.inner.governance.list_accounts(None).await? {
            if account.mode != AccountMode::Disabled
                && matches!(
                    account.authorization,
                    AuthorizationState::Ready | AuthorizationState::Refreshing
                )
            {
                match self.enqueue(&account.id, false) {
                    Ok(_) => {}
                    Err(Error::Capacity) => break,
                    Err(error) => return Err(error),
                }
            }
        }
        Ok(())
    }

    /// The gateway owns this future. Run it alongside the listeners and join it
    /// after shutdown. Storage faults are reported through this future.
    pub async fn run_periodic(&self) -> Result<()> {
        if self.inner.periodic.swap(true, Ordering::AcqRel) {
            return Err(Error::Conflict);
        }
        let mut interval = tokio::time::interval(PERIOD);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                biased;
                _ = self.inner.stop.cancelled() => break,
                _ = interval.tick() => {}
            }
            match self.schedule_cycle().await {
                Ok(()) | Err(Error::Capacity | Error::StoragePressure) => {}
                Err(Error::AuthorizationUnavailable) if self.inner.stop.is_cancelled() => break,
                Err(error) => {
                    self.shutdown().await;
                    return Err(error);
                }
            }
        }
        if self.inner.failed.load(Ordering::Acquire) {
            self.shutdown().await;
            Err(Error::AccountStorageUnavailable)
        } else {
            Ok(())
        }
    }

    /// Stop new identity work and await shared network and durable commands.
    /// Keep the writer open until this returns.
    pub async fn shutdown(&self) {
        let jobs = {
            let jobs = self.inner.jobs.lock().expect("observation jobs");
            self.inner.stop.cancel();
            jobs.values()
                .map(|job| job.reply.clone())
                .collect::<Vec<_>>()
        };
        self.inner.refresh.shutdown().await;
        for reply in jobs {
            let _ = wait(reply).await;
        }
    }

    fn enqueue(&self, id: &str, manual: bool) -> Result<Reply> {
        let mut jobs = self.inner.jobs.lock().expect("observation jobs");
        if self.inner.stop.is_cancelled() {
            return Err(Error::AuthorizationUnavailable);
        }
        if let Some(job) = jobs.get_mut(id) {
            job.manual |= manual;
            return Ok(job.reply.clone());
        }
        if jobs.len() >= CAPACITY {
            return Err(Error::Capacity);
        }
        let (publish, reply) = watch::channel(None);
        jobs.insert(
            id.into(),
            Job {
                reply: reply.clone(),
                manual,
            },
        );
        let task = Task {
            runtime: self.clone(),
            id: id.into(),
            publish,
            result: None,
        };
        tokio::spawn(task.run());
        Ok(reply)
    }

    async fn load(&self, id: &str, optional: bool) -> Result<store::Record> {
        let id = id.to_owned();
        self.inner
            .writer
            .run(Work::Read, move |db, _, allowed| {
                if optional && !allowed {
                    return Err(Error::StoragePressure);
                }
                store::load(db.connection(), &id)
            })
            .await
    }

    async fn execute(&self, id: &str) -> Result<Observation> {
        let stop = &self.inner.stop;
        let _slot = tokio::select! {
            biased;
            _ = stop.cancelled() => return Err(Error::AuthorizationUnavailable),
            slot = self.inner.parallel.acquire() => slot.map_err(|_| Error::AuthorizationUnavailable)?,
        };
        let deadline = Instant::now() + JOB_TIMEOUT;
        let mut record = self.load(id, true).await?;
        if record.account.mode == AccountMode::Disabled {
            let manual = self
                .inner
                .jobs
                .lock()
                .expect("observation jobs")
                .get(id)
                .is_some_and(|job| job.manual);
            if !manual {
                return self.quota(id).await;
            }
        }

        if record.account.mode != AccountMode::Disabled && self.should_refresh(&record) {
            let account = &record.account;
            tracing::info!(account_id = %account.id, credential_version = account.credential_version, "proactive_refresh_started");
            let refresh_result = tokio::select! {
                biased;
                _ = stop.cancelled() => return Err(Error::AuthorizationUnavailable),
                result = tokio::time::timeout_at(deadline, self.inner.refresh.refresh_for_dispatch(&record.account)) =>
                    result.unwrap_or(Err(Error::AuthorizationUnavailable)),
            };
            if let Ok(updated) = &refresh_result {
                tracing::info!(account_id = %account.id, credential_version = account.credential_version,
                    new_credential_version = updated.credential_version, result = "committed", "proactive_refresh_result");
            }
            if matches!(
                refresh_result,
                Err(Error::Unavailable | Error::AccountStorageUnavailable)
            ) {
                return Err(Error::AccountStorageUnavailable);
            }
            if let Err(error @ (Error::Capacity | Error::StoragePressure)) = refresh_result {
                return Err(error);
            }
            let current = self.load(id, true).await?;
            if let Err(error) = refresh_result {
                let safe = self
                    .safe_to_observe_after_refresh(&record, &current, error)
                    .await?;
                let result = match (safe, error, current.account.authorization) {
                    (true, _, _) => "not_completed",
                    (_, Error::AuthorizationRequired, _) => "requires_auth",
                    (_, _, AuthorizationState::AuthUncertain) => "auth_uncertain",
                    (_, Error::AccountConflict, _) => "conflict",
                    _ => "unavailable",
                };
                tracing::info!(account_id = %account.id, credential_version = account.credential_version,
                    result, "proactive_refresh_result");
                if !safe {
                    return self
                        .persist(record.account, Err(QuotaFailure::Unavailable))
                        .await;
                }
            }
            record = current;
        }

        let result = if Instant::now() >= deadline
            || record.account.authorization != AuthorizationState::Ready
        {
            Err(QuotaFailure::Unavailable)
        } else if let Some(credential) = record.open(&self.inner.cipher) {
            if credential.expires_at_unix_seconds() <= self.inner.provider.now() {
                Err(QuotaFailure::RefreshRequired)
            } else {
                self.inner
                    .provider
                    .observe(
                        &record.account.namespace,
                        &credential,
                        stop.clone(),
                        deadline,
                    )
                    .await
            }
        } else {
            Err(QuotaFailure::Unavailable)
        };
        self.persist(record.account, result).await
    }

    async fn safe_to_observe_after_refresh(
        &self,
        previous: &store::Record,
        current: &store::Record,
        error: Error,
    ) -> Result<bool> {
        let account = &current.account;
        if error != Error::AuthorizationUnavailable
            || account.authorization != AuthorizationState::Ready
            || account.namespace != previous.account.namespace
            || account.credential_version != previous.account.credential_version
            || account.revision <= previous.account.revision
            || !current.open(&self.inner.cipher).is_some_and(|credential| {
                credential.expires_at_unix_seconds() > self.inner.provider.now()
            })
        {
            return Ok(false);
        }
        // The refresh API groups capacity and safe non-completion into the same
        // error. Require the matching durable terminal event before proceeding.
        let id = account.id.clone();
        let revision = previous.account.revision;
        self.inner
            .writer
            .run(Work::Read, move |db, _, _| {
                let action = store::last_refresh_action(db.connection(), &id, revision)?;
                Ok(action.as_deref() == Some("refresh_not_completed"))
            })
            .await
    }

    fn should_refresh(&self, record: &store::Record) -> bool {
        record.account.authorization == AuthorizationState::Refreshing
            || (record.account.authorization == AuthorizationState::Ready
                && record.open(&self.inner.cipher).is_some_and(|credential| {
                    credential.expires_at_unix_seconds() - self.inner.provider.now()
                        <= PROACTIVE_WINDOW
                }))
    }

    async fn persist(
        &self,
        account: Account,
        result: std::result::Result<crate::SubscriptionQuota, QuotaFailure>,
    ) -> Result<Observation> {
        if self.inner.stop.is_cancelled() {
            return Err(Error::AuthorizationUnavailable);
        }
        self.inner
            .writer
            .run(Work::Optional, move |db, now, _| {
                let tx = db.begin_immediate()?;
                let observation = store::record_quota(&tx, &account, now, result)?;
                tx.commit()?;
                Ok(observation)
            })
            .await
    }
}

struct Task<W> {
    runtime: IdentityRuntime<W>,
    id: String,
    publish: watch::Sender<Option<Result<Observation>>>,
    result: Option<Result<Observation>>,
}

impl<W: Writer> Task<W> {
    async fn run(mut self) {
        let result = self.runtime.execute(&self.id).await;
        if matches!(
            result,
            Err(Error::Unavailable | Error::AccountStorageUnavailable)
        ) {
            self.runtime.inner.failed.store(true, Ordering::Release);
            self.runtime.inner.stop.cancel();
        }
        self.result = Some(result);
    }
}

impl<W> Drop for Task<W> {
    fn drop(&mut self) {
        let mut jobs = self.runtime.inner.jobs.lock().expect("observation jobs");
        jobs.remove(&self.id);
        self.publish
            .send_replace(Some(self.result.take().unwrap_or(Err(Error::Unavailable))));
    }
}

async fn wait(mut reply: Reply) -> Result<Observation> {
    reply
        .wait_for(Option::is_some)
        .await
        .map_err(|_| Error::Unavailable)?
        .as_ref()
        .expect("completed observation")
        .clone()
}

fn validate_id(id: &str) -> Result<()> {
    if !(1..=64).contains(&id.len())
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
    {
        return Err(Error::InvalidCommand);
    }
    Ok(())
}

impl<W: Writer> AccountRuntime for IdentityRuntime<W> {
    async fn refresh(&self, account: String, revision: i64) -> Result<Account> {
        self.refresh_account(account, revision).await
    }

    async fn observability(&self, account: &str) -> Result<Value> {
        validate_id(account)?;
        let id = account.to_owned();
        let (quota, health, now) = self
            .inner
            .writer
            .run(Work::Read, move |db, now, _| {
                let quota = store::load_quota(db.connection(), &id)?;
                let health = store::health(db.connection(), &id, now)?;
                Ok((quota, health, now))
            })
            .await?;
        let observing = self
            .inner
            .jobs
            .lock()
            .expect("observation jobs")
            .contains_key(account);
        Ok(json!({ "quota": quota_dto(quota, now), "health": health, "observing": observing }))
    }
}

fn quota_dto(observation: Observation, now: i64) -> Value {
    let limits = observation
        .quota
        .as_ref()
        .map_or(&[][..], |quota| quota.limits.as_slice());
    let has_data = limits.iter().any(|limit| {
        limit.allowed.is_some()
            || limit.limit_reached.is_some()
            || limit.primary.is_some()
            || limit.secondary.is_some()
    });
    let state = if !has_data {
        "unavailable"
    } else if observation.is_fresh(now) {
        "fresh"
    } else {
        "stale"
    };
    let age = observation
        .observed_at_unix_seconds
        .and_then(|time| now.checked_sub(time))
        .filter(|age| *age >= 0);
    let window = |value: Option<&crate::QuotaWindow>| {
        value.map(|window| {
            json!({
                "usedPercent": window.used_percent, "durationSeconds": window.duration_seconds,
                "resetsAtUnixSeconds": window.resets_at_unix_seconds,
            })
        })
    };
    let mut dto = json!({
        "state": state, "observedAtUnixSeconds": observation.observed_at_unix_seconds,
        "attemptedAtUnixSeconds": observation.attempted_at_unix_seconds, "ageSeconds": age,
        "freshForSeconds": age.map_or(0, |age| (300 - age).max(0)), "failure": observation.failure,
        "additionalCount": limits.iter().filter(|limit| limit.id != "codex").count(),
        "limits": limits.iter().map(|limit| json!({
            "id": limit.id, "allowed": limit.allowed, "limitReached": limit.limit_reached,
            "primary": window(limit.primary.as_ref()), "secondary": window(limit.secondary.as_ref()),
        })).collect::<Vec<_>>(),
    });
    match observation.quota.and_then(|quota| quota.usage_credits) {
        Some(UsageCredits::Balance { _0: balance }) => {
            dto["usageCredits"] = json!({"balance": balance, "unlimited": false})
        }
        Some(UsageCredits::Unlimited {}) => {
            dto["usageCredits"] = json!({"balance": null, "unlimited": true})
        }
        None => {}
    }
    dto
}
