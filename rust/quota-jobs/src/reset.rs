use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use codexone_governance::{
    Account, AccountMode, AuthorizationState, Error, Governance, Result, Work, Writer,
    change_quota_settings, quota_account,
};
use codexone_http_upstream::CancellationToken;
use codexone_identity_runtime::{DispatchCredential, IdentityRuntime};
use tokio::{
    sync::{mpsc, watch},
    task::JoinSet,
};

use crate::{
    reset_store::{self as store, State},
    reset_types::{
        ResetCode, ResetList, ResetListing, ResetResult, ResetSettings, ResetStatus, valid_credit,
    },
    valid_id,
};

const PERIOD: f64 = 1800.;
const RETRY: f64 = 60.;

#[derive(Clone)]
struct Target {
    id: String,
    expiry: f64,
}

#[derive(Clone)]
struct Schedule {
    revision: i64,
    check_at: f64,
    target: Option<Target>,
    retrying: bool,
}

pub struct ResetSupervisor<W> {
    writer: W,
    governance: Arc<Governance<W>>,
    identity: IdentityRuntime<W>,
    clock: Arc<dyn Fn() -> f64 + Send + Sync>,
    active: Mutex<HashSet<String>>,
    changed: watch::Sender<u64>,
    stop: CancellationToken,
    hints: mpsc::Sender<String>,
    inbox: Mutex<Option<mpsc::Receiver<String>>>,
    running: AtomicBool,
}

struct Lease<W> {
    owner: Arc<ResetSupervisor<W>>,
    id: String,
}

impl<W> Drop for Lease<W> {
    fn drop(&mut self) {
        self.owner
            .active
            .lock()
            .expect("active reset jobs")
            .remove(&self.id);
        self.owner
            .changed
            .send_modify(|generation| *generation = generation.wrapping_add(1));
    }
}

impl<W: Writer> ResetSupervisor<W> {
    pub fn new(
        writer: W,
        governance: Arc<Governance<W>>,
        identity: IdentityRuntime<W>,
        clock: impl Fn() -> f64 + Send + Sync + 'static,
    ) -> Arc<Self> {
        let (hints, inbox) = mpsc::channel(64);
        Arc::new(Self {
            writer,
            governance,
            identity,
            clock: Arc::new(clock),
            active: Mutex::new(HashSet::new()),
            changed: watch::channel(0).0,
            stop: CancellationToken::new(),
            hints,
            inbox: Mutex::new(Some(inbox)),
            running: AtomicBool::new(false),
        })
    }

    pub fn observed_credits(&self, id: &str) {
        if valid_id(id) && !self.stop.is_cancelled() {
            let _ = self.hints.try_send(id.into());
        }
    }

    pub fn active_operations(&self) -> usize {
        self.active.lock().expect("active reset jobs").len()
    }

    fn acquire(self: &Arc<Self>, id: &str) -> Result<Lease<W>> {
        if !valid_id(id) {
            return Err(Error::InvalidCommand);
        }
        let mut active = self.active.lock().expect("active reset jobs");
        if self.stop.is_cancelled() {
            return Err(Error::AuthorizationUnavailable);
        }
        if active.contains(id) {
            return Err(Error::AccountConflict);
        }
        if active.len() >= 4 {
            return Err(Error::Capacity);
        }
        active.insert(id.into());
        Ok(Lease {
            owner: self.clone(),
            id: id.into(),
        })
    }

    pub async fn status(&self, id: &str) -> Result<ResetStatus> {
        let (account, state) = self.snapshot(id).await?;
        Ok(state.status(account.revision))
    }

    async fn snapshot(&self, id: &str) -> Result<(Account, State)> {
        if !valid_id(id) {
            return Err(Error::InvalidCommand);
        }
        let id = id.to_owned();
        self.writer
            .run(Work::Read, move |db, _, _| {
                Ok((
                    quota_account(db.connection(), &id)?,
                    State::load(db.connection(), &id)?,
                ))
            })
            .await
    }

    pub async fn set_settings(
        &self,
        id: &str,
        revision: i64,
        settings: ResetSettings,
    ) -> Result<ResetStatus> {
        if !valid_id(id) || !settings.validate() {
            return Err(Error::InvalidCommand);
        }
        let owned = id.to_owned();
        let work = if settings.auto_use_before_expiry {
            Work::Optional
        } else {
            Work::Restrict
        };
        let status = self
            .writer
            .run(work, move |db, now, _| {
                let tx = db.begin_immediate()?;
                let mut state = State::load(&tx, &owned)?;
                state.revision =
                    change_quota_settings(&tx, &owned, revision, "reset_credit_settings", now)?;
                state.settings = settings;
                state.save(&tx, &owned)?;
                tx.commit()?;
                let revision = state.revision;
                Ok(state.status(revision))
            })
            .await?;
        self.observed_credits(id);
        Ok(status)
    }

    pub async fn list(self: &Arc<Self>, id: &str) -> Result<ResetList> {
        let lease = self.acquire(id)?;
        let owner = self.clone();
        // A client disconnect cannot detach the active slot from the network work.
        tokio::spawn(async move {
            let work = owner.prepare(&lease.id).await?;
            owner.fetch_list(work.headers).await
        })
        .await
        .map_err(|_| Error::Unavailable)?
    }

    pub async fn list_with_status(self: &Arc<Self>, id: &str) -> Result<ResetListing> {
        let list = self.list(id).await?;
        let state = self.status(id).await?;
        Ok(ResetListing { list, state })
    }

    pub async fn consume(
        self: &Arc<Self>,
        id: &str,
        credit_id: Option<String>,
    ) -> Result<ResetResult> {
        if credit_id
            .as_deref()
            .is_some_and(|credit| !valid_credit(credit, 256))
        {
            return Err(Error::InvalidCommand);
        }
        let lease = self.acquire(id)?;
        let owner = self.clone();
        tokio::spawn(async move {
            let work = owner.prepare(&lease.id).await?;
            owner.consume_prepared(work, credit_id, None).await
        })
        .await
        .map_err(|_| Error::Unavailable)?
    }

    async fn prepare(&self, id: &str) -> Result<DispatchCredential> {
        // Credential rotation belongs to the shared identity owner. A stopped
        // card job releases its wait without cancelling another caller's refresh.
        tokio::select! {
            biased;
            _ = self.stop.cancelled() => Err(Error::AuthorizationUnavailable),
            work = self.identity.prepare_quota_access(id) => work,
        }
    }

    async fn fetch_list(&self, headers: codexone_http_upstream::HeaderMap) -> Result<ResetList> {
        let raw = self
            .identity
            .subscription_provider()
            .reset_credits(headers, self.stop.child_token())
            .await
            .map_err(|_| Error::AuthorizationUnavailable)?;
        ResetList::parse(raw)
    }

    async fn consume_prepared(
        &self,
        work: DispatchCredential,
        credit_id: Option<String>,
        expiry: Option<f64>,
    ) -> Result<ResetResult> {
        if self.stop.is_cancelled() || expiry.is_some_and(|expiry| (self.clock)() >= expiry) {
            return Err(Error::AuthorizationUnavailable);
        }
        let id = work.account.id.clone();
        let access_expires_at = work.expires_at_unix_seconds;
        let attempt = self
            .writer
            .run(Work::Admission, move |db, now, allowed| {
                if !allowed {
                    return Err(Error::StoragePressure);
                }
                let tx = db.begin_immediate()?;
                let attempt = store::begin(
                    &tx,
                    &work.account,
                    credit_id,
                    expiry.is_some(),
                    expiry,
                    access_expires_at,
                    now,
                )?;
                tx.commit()?;
                Ok(attempt)
            })
            .await?;
        let now = (self.clock)();
        let result = if self.stop.is_cancelled()
            || now >= access_expires_at as f64
            || expiry.is_some_and(|expiry| now >= expiry)
        {
            ResetResult::UNKNOWN
        } else {
            self.identity
                .subscription_provider()
                .consume_reset_credit(
                    work.headers,
                    &attempt.intent.request_id,
                    attempt.intent.credit_id.as_deref(),
                    self.stop.child_token(),
                )
                .await
                .map_or(ResetResult::UNKNOWN, ResetResult::parse)
        };
        self.writer
            .run(Work::Critical, move |db, now, _| {
                let tx = db.begin_immediate()?;
                store::finish(&tx, &id, &attempt, result.code, now)?;
                tx.commit()?;
                Ok(())
            })
            .await?;
        Ok(result)
    }

    pub fn stop(&self) {
        let _active = self.active.lock().expect("active reset jobs");
        self.stop.cancel();
    }

    /// Stop admitting jobs, cancel provider work, and wait for critical completion.
    /// The caller should also join its task running `run`.
    pub async fn shutdown(&self) {
        self.stop();
        let mut changed = self.changed.subscribe();
        while !self.active.lock().expect("active reset jobs").is_empty() {
            let _ = changed.changed().await;
        }
    }

    /// Refresh expiry schedules and share the same slots as manual operations.
    pub async fn run(self: &Arc<Self>) -> Result<()> {
        if self.running.swap(true, Ordering::AcqRel) {
            return Err(Error::Conflict);
        }
        let mut inbox = self
            .inbox
            .lock()
            .expect("reset hints")
            .take()
            .expect("first run");
        let mut changed = self.changed.subscribe();
        let mut jobs = JoinSet::new();
        let mut schedules = HashMap::<String, Schedule>::new();
        let mut in_flight = HashSet::new();
        let mut accounts: Vec<Account> = Vec::new();
        let mut scan = true;
        let result = loop {
            if self.stop.is_cancelled() {
                break Ok(());
            }
            if scan {
                match self.governance.list_accounts(None).await {
                    Ok(list) => {
                        accounts = list;
                        schedules.retain(|id, _| accounts.iter().any(|account| account.id == *id));
                    }
                    Err(error) if fatal(error) => break Err(error),
                    Err(_) => {}
                }
                scan = false;
            }
            let now = (self.clock)();
            let mut due: Vec<_> = accounts
                .iter()
                .filter(|account| {
                    account.mode == AccountMode::Enabled
                        && account.authorization == AuthorizationState::Ready
                        && !in_flight.contains(&account.id)
                })
                .map(|account| {
                    let schedule = schedules
                        .get(&account.id)
                        .filter(|s| s.revision == account.revision);
                    (account, schedule.map_or(now, |s| s.check_at))
                })
                .collect();
            due.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.id.cmp(&b.0.id)));
            let mut sleep: f64 = 60.;
            for (account, deadline) in due {
                if deadline > now {
                    sleep = sleep.min(deadline - now);
                    break;
                }
                let Ok(lease) = self.acquire(&account.id) else {
                    continue;
                };
                in_flight.insert(account.id.clone());
                let schedule = schedules.get(&account.id).cloned();
                let owner = self.clone();
                jobs.spawn(async move {
                    let result = owner.cycle(&lease.id, schedule).await;
                    (lease.id.clone(), result)
                });
            }
            tokio::select! {
                biased;
                _ = self.stop.cancelled() => break Ok(()),
                Some(done) = jobs.join_next() => {
                    let Ok((id, result)) = done else { break Err(Error::Unavailable); };
                    in_flight.remove(&id);
                    match result {
                        Ok(schedule) => { schedules.insert(id, schedule); }
                        Err(error) if fatal(error) => break Err(error),
                        Err(_) => {
                            let revision = accounts.iter().find(|a| a.id == id).map_or(0, |a| a.revision);
                            schedules.insert(id, Schedule { revision, check_at: now + 60., target: None, retrying: false });
                        }
                    }
                }
                _ = changed.changed() => {}
                Some(_) = inbox.recv() => scan = true,
                _ = tokio::time::sleep(Duration::from_secs_f64(sleep.max(0.001))) => scan = true,
            }
        };
        self.shutdown().await;
        while jobs.join_next().await.is_some() {}
        result
    }

    async fn cycle(&self, id: &str, previous: Option<Schedule>) -> Result<Schedule> {
        let (account, state) = self.snapshot(id).await?;
        let revision = account.revision;
        let now = (self.clock)();
        let target = previous
            .as_ref()
            .and_then(|schedule| schedule.target.clone());
        let old = previous.filter(|old| old.revision == revision);
        let mut schedule = Schedule {
            revision,
            check_at: now + PERIOD,
            target,
            retrying: false,
        };
        if account.mode != AccountMode::Enabled
            || account.authorization != AuthorizationState::Ready
            || !state.settings.auto_use_before_expiry
            || state
                .intent
                .as_ref()
                .is_some_and(|intent| !intent.automatic)
        {
            return Ok(schedule);
        }
        let budget = u32::from(state.settings.retry_count) + 1;
        if let Some(intent) = &state.intent {
            if state.failures >= budget {
                return Ok(schedule);
            }
            if schedule
                .target
                .as_ref()
                .is_some_and(|target| now >= target.expiry)
            {
                schedule.target = None;
            }
            if let Some(at) = state
                .last_failure_at
                .or(state.last_attempt_at)
                .map(|at| at as f64 + RETRY)
                && at > now
            {
                schedule.check_at = at;
                schedule.retrying = true;
                return Ok(schedule);
            }
            schedule.target = schedule
                .target
                .filter(|target| Some(&target.id) == intent.credit_id.as_ref());
        }
        let retrying = old.is_some_and(|old| old.retrying);
        if state.intent.is_none() && !retrying && state.failures != 0 {
            self.clear_poll_failures(id, revision).await?;
        }
        let failures = if state.intent.is_some() || retrying {
            state.failures
        } else {
            0
        };
        let work = self.prepare(id).await?;
        if work.account.revision != revision {
            return Err(Error::AccountConflict);
        }
        let list = match self.fetch_list(work.headers.clone()).await {
            Ok(list) => list,
            Err(error) => {
                if self.stop.is_cancelled() {
                    return Err(error);
                }
                let failed = self.record_poll_failure(id, revision).await?;
                let retry = (self.clock)() + RETRY;
                if failed < budget
                    && schedule
                        .target
                        .as_ref()
                        .is_none_or(|target| retry < target.expiry)
                {
                    schedule.retrying = true;
                    schedule.check_at = retry;
                } else if state.intent.is_none() {
                    self.clear_poll_failures(id, revision).await?;
                }
                return Ok(schedule);
            }
        };
        let now = (self.clock)();
        let lead = f64::from(state.settings.lead_minutes) * 60.;
        let mut available = list
            .credits
            .iter()
            .filter(|card| card.status == "available")
            .filter_map(|card| {
                Some(Target {
                    id: card.id.clone(),
                    expiry: card.expires()?,
                })
            })
            .filter(|target| target.expiry > now)
            .collect::<Vec<_>>();
        available.sort_by(|a, b| a.expiry.total_cmp(&b.expiry).then_with(|| a.id.cmp(&b.id)));
        let earliest = available.first().cloned();
        if let Some(due) = earliest
            .as_ref()
            .map(|target| target.expiry - lead)
            .filter(|due| *due > now)
        {
            schedule.check_at = schedule.check_at.min(due);
        }
        let target = if let Some(intent) = &state.intent {
            list.credits
                .iter()
                .find(|card| Some(&card.id) == intent.credit_id.as_ref())
                .and_then(|card| {
                    card.expires().map(|expiry| Target {
                        id: card.id.clone(),
                        expiry,
                    })
                })
                .or(schedule.target)
        } else if retrying && schedule.target.is_some() {
            available
                .iter()
                .find(|target| {
                    Some(&target.id) == schedule.target.as_ref().map(|target| &target.id)
                })
                .cloned()
        } else {
            earliest.clone()
        };
        schedule.target = if state.intent.is_some() {
            target.clone()
        } else {
            earliest
        };
        if let Some(target) = target.filter(|target| {
            target.expiry > now && (state.intent.is_some() || target.expiry <= now + lead)
        }) {
            let result = self
                .consume_prepared(work, Some(target.id.clone()), Some(target.expiry))
                .await?;
            if result.code == ResetCode::Unknown {
                let retry = (self.clock)() + RETRY;
                schedule.retrying = failures + 1 < budget && retry < target.expiry;
                schedule.target = Some(target);
                if schedule.retrying {
                    schedule.check_at = retry;
                }
            } else {
                // One card per regular cycle, including when the card was left unused.
                schedule.check_at = (self.clock)() + PERIOD;
            }
        } else if state.intent.is_none() {
            self.clear_poll_failures(id, revision).await?;
        }
        Ok(schedule)
    }

    async fn record_poll_failure(&self, id: &str, revision: i64) -> Result<u32> {
        let id = id.to_owned();
        self.writer
            .run(Work::Optional, move |db, now, _| {
                let tx = db.begin_immediate()?;
                let count = store::poll_failed(&tx, &id, revision, now)?;
                tx.commit()?;
                Ok(count)
            })
            .await
    }

    async fn clear_poll_failures(&self, id: &str, revision: i64) -> Result<()> {
        let id = id.to_owned();
        self.writer
            .run(Work::Optional, move |db, _, _| {
                let tx = db.begin_immediate()?;
                store::clear_poll_failures(&tx, &id, revision)?;
                tx.commit()?;
                Ok(())
            })
            .await
    }
}

fn fatal(error: Error) -> bool {
    matches!(error, Error::Unavailable | Error::AccountStorageUnavailable)
}
