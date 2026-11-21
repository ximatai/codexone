use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use codexone_account_pool::{Health, PacingWaiters};
use codexone_storage::{Database, bearer_digest};
use rusqlite::Transaction;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, oneshot, watch};
use tokio_util::sync::CancellationToken;

use crate::model::*;
use crate::reserve::{StorageMonitor, StorageObservation, StoragePressure, StorageReserve};
use crate::{
    AccountIdentity, ExecutionError as Error, FixedIdentity, Result, StaticAdmissionRequest,
    StaticAuthorization, StaticIdentity, admission, ledger,
};

const REGULAR_CAPACITY: usize = 16;

type Job = Box<dyn FnOnce(&mut Writer) + Send>;
type Recovery = fn(&Transaction<'_>, i64) -> Result<()>;

enum IdentitySource {
    Managed(String),
    Fixed(FixedIdentity),
    Pool,
    Static(Arc<StaticIdentity>),
}

pub struct Options {
    identity: IdentitySource,
    day_offset: i64,
    capacity: usize,
    clock: Arc<dyn Fn() -> i64 + Send + Sync>,
    governance_recovery: Option<Recovery>,
}

impl Options {
    pub fn new(account_id: impl Into<String>) -> Self {
        Self::with_identity(IdentitySource::Managed(account_id.into()))
    }

    pub fn for_account_pool() -> Self {
        Self::with_identity(IdentitySource::Pool)
    }

    pub fn for_fixed_identity_with_managed_keys(identity: FixedIdentity) -> Self {
        Self::with_identity(IdentitySource::Fixed(identity))
    }

    pub fn for_static_identity(policy: StaticIdentity) -> Self {
        Self::with_identity(IdentitySource::Static(Arc::new(policy)))
    }

    fn with_identity(identity: IdentitySource) -> Self {
        Self {
            identity,
            day_offset: 0,
            capacity: 16,
            clock: Arc::new(system_time),
            governance_recovery: None,
        }
    }

    /// The configured business-day offset in whole hours, between -12 and +14.
    pub fn with_business_day_offset_hours(mut self, hours: i8) -> Self {
        self.day_offset = i64::from(hours) * 3600;
        self
    }

    /// Active leases, queued terminal work and the current finalization share these slots.
    pub fn with_finalization_capacity(mut self, capacity: usize) -> Self {
        self.capacity = capacity;
        self
    }

    pub fn with_clock(self, clock: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.with_clock_micros(move || clock().saturating_mul(1_000_000))
    }

    /// Wall-clock Unix microseconds, including the subsecond pacing boundary.
    pub fn with_clock_micros(mut self, clock: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.clock = Arc::new(clock);
        self
    }

    /// Recover durable governance intents in the startup ledger transaction.
    pub fn with_governance_recovery(mut self, recover: Recovery) -> Self {
        self.governance_recovery = Some(recover);
        self
    }
}

fn system_time() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_micros()).ok())
        .unwrap_or(0)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionStatus {
    Accepting,
    Draining,
    Failed,
    Closed,
}

#[derive(Clone, Copy)]
pub enum GovernanceWork {
    Read,
    Optional,
    Restrict,
    Admission,
    Critical,
}

struct Gate {
    sender: Option<SyncSender<Job>>,
    status: watch::Sender<ExecutionStatus>,
}

impl Gate {
    fn status(&self) -> ExecutionStatus {
        *self.status.borrow()
    }
}

struct Inner {
    static_identity: Option<Arc<StaticIdentity>>,
    pool_enabled: bool,
    gate: Mutex<Gate>,
    regular: Arc<Semaphore>,
    tickets: Arc<Semaphore>,
    pacing: PacingWaiters,
    capacity: u32,
    done: watch::Receiver<bool>,
    active: Mutex<HashMap<String, ActiveAccountExecution>>,
}

struct ActiveAccountExecution {
    account: String,
    stop: CancellationToken,
}

impl Inner {
    fn gate(&self) -> MutexGuard<'_, Gate> {
        self.gate
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn fail(&self) {
        self.gate().status.send_replace(ExecutionStatus::Failed);
    }

    fn active(&self) -> MutexGuard<'_, HashMap<String, ActiveAccountExecution>> {
        self.active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn enqueue(&self, job: Job, admission: bool) -> Result<()> {
        let gate = self.gate();
        if admission {
            match gate.status() {
                ExecutionStatus::Accepting => {}
                ExecutionStatus::Failed => return Err(Error::StorageUnavailable),
                _ => return Err(Error::Closed),
            }
        }
        let sender = gate.sender.as_ref().ok_or(Error::Closed)?;
        if let Err(error) = sender.try_send(job) {
            gate.status.send_replace(ExecutionStatus::Failed);
            // A rejected job can own a semaphore permit. Drop after releasing the gate.
            drop(gate);
            return match error {
                TrySendError::Full(_) => Err(Error::StorageUnavailable),
                TrySendError::Disconnected(_) => Err(Error::Closed),
            };
        }
        Ok(())
    }
}

struct WorkerExit {
    inner: Weak<Inner>,
    done: watch::Sender<bool>,
}

impl Drop for WorkerExit {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.upgrade() {
            let mut gate = inner.gate();
            gate.sender.take();
            if thread::panicking() {
                gate.status.send_replace(ExecutionStatus::Failed);
            }
        }
        self.done.send_replace(true);
    }
}

struct Writer {
    db: Database,
    reserve: StorageReserve,
    options: Options,
    health: Health,
}

impl Writer {
    fn open(db: Database, options: Options) -> Result<Self> {
        let reserve = StorageReserve::open(db.path())?;
        let mut writer = Self {
            db,
            reserve,
            options,
            health: Health::default(),
        };
        writer.reserve.maintain(writer.db.connection())?;
        let governance = writer.options.governance_recovery;
        writer.write(true, |tx, now| {
            ledger::recover(tx, now)?;
            if let Some(recover) = governance {
                recover(tx, now)?;
            }
            Ok(())
        })?;
        Ok(writer)
    }

    fn now(&self) -> Result<i64> {
        Ok(self.now_micros()?.div_euclid(1_000_000))
    }

    fn now_micros(&self) -> Result<i64> {
        let micros = (self.options.clock)();
        check_time(micros.div_euclid(1_000_000))?;
        Ok(micros)
    }

    fn finalize(
        &mut self,
        attempt: &str,
        evidence: Option<&UsageEvidence>,
        outcome: Option<&Outcome>,
    ) -> Result<()> {
        self.reserve.prepare_critical()?;
        let now_micros = self.now_micros()?;
        // Keep the fixed-account route's original cooldown when no hint was supplied.
        let overload_default =
            matches!(self.options.identity, IdentitySource::Managed(_)).then_some(15);
        ledger::finalize(
            &mut self.db,
            &mut self.health,
            attempt,
            evidence,
            outcome,
            now_micros,
            overload_default,
        )
    }

    fn write<T>(
        &mut self,
        essential: bool,
        body: impl FnOnce(&Transaction<'_>, i64) -> Result<T>,
    ) -> Result<T> {
        if essential {
            self.reserve.prepare_critical()?;
        }
        let tx = self.db.begin_immediate()?;
        let now = check_time((self.options.clock)().div_euclid(1_000_000))?;
        let result = body(&tx, now)?;
        tx.commit()?;
        Ok(result)
    }
}

/// Cloneable handle to a single bounded SQLite writer and execution finalizer.
#[derive(Clone)]
pub struct ExecutionService {
    inner: Arc<Inner>,
    storage: StorageMonitor,
}

impl ExecutionService {
    /// Open a v19 database, acquire the instance lock and recover abandoned intents before returning.
    pub async fn open(path: impl AsRef<Path>, options: Options) -> Result<Self> {
        let path = path.as_ref().to_owned();
        Self::start(move || Ok(Database::open_existing(path)?), options).await
    }

    /// Transfer an initialized writer and its instance lock, then recover abandoned intents.
    pub async fn open_database(db: Database, options: Options) -> Result<Self> {
        Self::start(move || Ok(db), options).await
    }

    async fn start(
        open: impl FnOnce() -> Result<Database> + Send + 'static,
        options: Options,
    ) -> Result<Self> {
        if matches!(&options.identity, IdentitySource::Managed(id) if !valid_id(id))
            || !(-12 * 3600..=14 * 3600).contains(&options.day_offset)
            || !(1..=16).contains(&options.capacity)
        {
            return Err(Error::InvalidCommand);
        }
        let capacity = options.capacity;
        let (sender, receiver) = mpsc::sync_channel::<Job>(REGULAR_CAPACITY + capacity);
        let (done_tx, done_rx) = watch::channel(false);
        let (ready_tx, ready_rx) = oneshot::channel();
        let inner = Arc::new(Inner {
            static_identity: match &options.identity {
                IdentitySource::Static(policy) => Some(policy.clone()),
                IdentitySource::Managed(_) | IdentitySource::Fixed(_) | IdentitySource::Pool => {
                    None
                }
            },
            pool_enabled: matches!(options.identity, IdentitySource::Pool),
            gate: Mutex::new(Gate {
                sender: Some(sender),
                status: watch::Sender::new(ExecutionStatus::Accepting),
            }),
            regular: Arc::new(Semaphore::new(REGULAR_CAPACITY)),
            tickets: Arc::new(Semaphore::new(capacity)),
            pacing: PacingWaiters::default(),
            capacity: capacity as u32,
            done: done_rx,
            active: Mutex::new(HashMap::new()),
        });
        let exit = WorkerExit {
            inner: Arc::downgrade(&inner),
            done: done_tx,
        };
        thread::Builder::new()
            .name("codexone-execution".into())
            .spawn(move || {
                let _exit = exit;
                match open().and_then(|db| Writer::open(db, options)) {
                    Ok(mut writer) => {
                        if ready_tx.send(Ok(writer.reserve.monitor())).is_ok() {
                            for job in receiver {
                                job(&mut writer);
                            }
                        }
                    }
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                    }
                }
            })
            .map_err(|_| Error::StorageUnavailable)?;
        let storage = ready_rx.await.map_err(|_| Error::StorageUnavailable)??;
        Ok(Self { inner, storage })
    }

    pub fn status(&self) -> ExecutionStatus {
        self.inner.gate().status()
    }

    /// Optional work uses a read-only pressure sample outside the bounded writer queue.
    pub fn storage_pressure(&self) -> StoragePressure {
        if self.status() == ExecutionStatus::Accepting {
            self.storage.pressure()
        } else {
            StoragePressure::Unknown
        }
    }

    /// Sample the same reserve and WAL used by admission without running SQLite.
    /// Call from a blocking thread and treat absent metrics as unknown.
    pub fn storage_observation(&self) -> StorageObservation {
        if self.status() == ExecutionStatus::Accepting {
            self.storage.observation()
        } else {
            StorageObservation::unavailable()
        }
    }

    /// Resolve on a fatal command or an unexpected writer panic, including prior failures.
    pub async fn wait_until_failed(&self) {
        let mut status = self.inner.gate().status.subscribe();
        let _ = status
            .wait_for(|status| *status == ExecutionStatus::Failed)
            .await;
    }

    /// Use the same storage and restore admission gates as the writer. The existing command
    /// budget bounds concurrent probes, which report unavailable when the queue is saturated.
    pub async fn admission_ready(&self) -> bool {
        self.command(true, |writer| {
            writer.reserve.check_admission()?;
            let managed = !matches!(writer.options.identity, IdentitySource::Static(_));
            admission::restore_allows_admission(writer.db.connection(), managed, writer.now()?)
        })
        .await
        .is_ok()
            && self.status() == ExecutionStatus::Accepting
    }

    pub fn outstanding(&self) -> usize {
        self.inner.capacity as usize - self.inner.tickets.available_permits()
    }

    pub fn account_in_flight(&self, account: &str) -> usize {
        self.inner
            .active()
            .values()
            .filter(|entry| entry.account == account)
            .count()
    }

    /// Call inside the same writer command that verifies the disabled mode and revision.
    pub fn stop_account_executions(&self, account: &str) -> usize {
        let active = self.inner.active();
        let mut count = 0;
        for entry in active.values().filter(|entry| entry.account == account) {
            if !entry.stop.is_cancelled() {
                count += 1;
                entry.stop.cancel();
            }
        }
        count
    }

    pub fn stop_admission(&self) {
        let gate = self.inner.gate();
        if gate.status() == ExecutionStatus::Accepting {
            gate.status.send_replace(ExecutionStatus::Draining);
        }
    }

    /// Stop admission, wait for leases to hand off and drain queued writes. Apply the runtime's
    /// shutdown deadline to this future, then call force_shutdown if the deadline elapses.
    pub async fn shutdown(&self) -> Result<()> {
        self.stop_admission();
        self.inner.pacing.close().await;
        let _all = self
            .inner
            .tickets
            .clone()
            .acquire_many_owned(self.inner.capacity)
            .await
            .map_err(|_| Error::Closed)?;
        self.force_shutdown().await
    }

    /// Stop accepting work and wait only for already queued writes. Unhanded intents are recovered
    /// on the next open. It is safe for the runtime to bound its wait for this future as well.
    pub async fn force_shutdown(&self) -> Result<()> {
        {
            let mut gate = self.inner.gate();
            if gate.status() != ExecutionStatus::Failed {
                gate.status.send_replace(ExecutionStatus::Closed);
            }
            gate.sender.take();
        }
        self.inner.pacing.close().await;
        let mut done = self.inner.done.clone();
        done.wait_for(|done| *done)
            .await
            .map_err(|_| Error::StorageUnavailable)?;
        if self.status() == ExecutionStatus::Failed {
            Err(Error::StorageUnavailable)
        } else {
            Ok(())
        }
    }

    async fn command<T: Send + 'static>(
        &self,
        opening_attempt: bool,
        body: impl FnOnce(&mut Writer) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        self.regular_command(opening_attempt, !opening_attempt, false, false, body)
            .await
    }

    async fn regular_command<T: Send + 'static>(
        &self,
        accepting_required: bool,
        allow_drain: bool,
        complete_on_cancel: bool,
        wait_for_capacity: bool,
        body: impl FnOnce(&mut Writer) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let slots = self.inner.regular.clone();
        let permit = if wait_for_capacity {
            // Only already-durable refresh operations may wait. Their owner bounds
            // the number of refresh jobs and is joined before shutting down this writer.
            slots.acquire_owned().await.map_err(|_| Error::Closed)?
        } else {
            slots.try_acquire_owned().map_err(|_| Error::Capacity)?
        };
        let inner = self.inner.clone();
        let (reply, response) = oneshot::channel();
        self.inner.enqueue(
            Box::new(move |writer| {
                let _permit = permit;
                if !complete_on_cancel && reply.is_closed() {
                    return;
                }
                let status = inner.gate().status();
                let result = match (allow_drain, status) {
                    (_, ExecutionStatus::Accepting) | (true, _) => body(writer),
                    (_, ExecutionStatus::Failed) => Err(Error::StorageUnavailable),
                    _ => Err(Error::Closed),
                };
                if matches!(result, Err(Error::StorageUnavailable)) {
                    inner.fail();
                }
                let _ = reply.send(result);
            }),
            accepting_required,
        )?;
        response.await.map_err(|_| Error::StorageUnavailable)?
    }

    /// Give a bounded governance command the existing writer, its clock and storage gates.
    /// The command owns its transaction and runs to completion after enqueueing.
    pub async fn governance_command<T: Send + 'static>(
        &self,
        work: GovernanceWork,
        operation: impl FnOnce(&mut Database, i64, bool) -> T + Send + 'static,
    ) -> Result<T> {
        use GovernanceWork::*;
        self.regular_command(
            !matches!(work, Read | Critical),
            true,
            true,
            matches!(work, Critical),
            move |writer| {
                let optional = match work {
                    Read => match writer.reserve.check_optional() {
                        Ok(()) => true,
                        Err(Error::StoragePressure) => false,
                        Err(error) => return Err(error),
                    },
                    Optional => {
                        writer.reserve.check_optional()?;
                        true
                    }
                    Restrict => match writer.reserve.check_optional() {
                        Ok(()) => true,
                        Err(Error::StoragePressure) => {
                            writer.reserve.prepare_critical()?;
                            false
                        }
                        Err(error) => return Err(error),
                    },
                    Admission => {
                        writer.reserve.check_admission()?;
                        match writer.reserve.check_optional() {
                            Ok(()) => true,
                            Err(Error::StoragePressure) => false,
                            Err(error) => return Err(error),
                        }
                    }
                    Critical => {
                        writer.reserve.prepare_critical()?;
                        false
                    }
                };
                let now = writer.now()?;
                Ok(operation(&mut writer.db, now, optional))
            },
        )
        .await
    }

    pub async fn authenticate(&self, headers: &[&str]) -> Result<AuthenticatedKey> {
        if self.inner.static_identity.is_some() {
            return Err(Error::Unauthorized);
        }
        let digest = bearer_digest(headers).map_err(|_| Error::Unauthorized)?;
        self.command(false, move |writer| {
            admission::authenticate(writer.db.connection(), &digest, writer.now()?)
        })
        .await
    }

    pub async fn account_credential(&self) -> Result<AccountCredentialRecord> {
        self.command(false, |writer| {
            let IdentitySource::Managed(account) = &writer.options.identity else {
                return Err(Error::AccountUnavailable);
            };
            admission::credential(writer.db.connection(), account)
        })
        .await
    }

    pub async fn admit(&self, request: AdmissionRequest) -> Result<Execution> {
        let (request, dispatch) = request.into_parts();
        request.validate()?;
        dispatch.validate()?;
        let ticket = self.admission_ticket()?;
        self.submit_single_admission(ticket, move |tx, options, now_micros| {
            let now = now_micros.div_euclid(1_000_000);
            let IdentitySource::Managed(account) = &options.identity else {
                return Err(Error::Unauthorized);
            };
            admission::admit(tx, account, options.day_offset, request, dispatch, now)
        })
        .await
    }

    /// Recheck current Key limits and revision for the configured fixed upstream.
    pub async fn admit_fixed(&self, request: ManagedAdmissionRequest) -> Result<Execution> {
        request.validate()?;
        let ticket = self.admission_ticket()?;
        self.submit_single_admission(ticket, move |tx, options, now_micros| {
            let IdentitySource::Fixed(identity) = &options.identity else {
                return Err(Error::Unauthorized);
            };
            admission::admit_fixed(
                tx,
                identity,
                options.day_offset,
                request,
                now_micros.div_euclid(1_000_000),
            )
        })
        .await
    }

    /// Admit one internal priming attempt and its window barrier atomically.
    pub async fn admit_priming(&self, request: PrimingAdmission) -> Result<Execution> {
        request.validate()?;
        if !self.inner.pool_enabled {
            return Err(Error::Unauthorized);
        }
        let ticket = self.admission_ticket()?;
        self.submit_single_admission(ticket, move |tx, options, now_micros| {
            admission::admit_priming(
                tx,
                options.day_offset,
                request,
                now_micros.div_euclid(1_000_000),
            )
        })
        .await
    }

    /// Authenticate a fixed Key with the policy supplied when opening this service.
    pub fn authenticate_static(&self, headers: &[&str]) -> Result<StaticAuthorization> {
        self.inner
            .static_identity
            .as_ref()
            .ok_or(Error::Unauthorized)?
            .authenticate(headers)
    }

    /// Validate a static turn with the fixed policy and commit the durable intent.
    pub async fn admit_static(
        &self,
        authorization: &StaticAuthorization,
        request: StaticAdmissionRequest,
    ) -> Result<Execution> {
        let policy = self
            .inner
            .static_identity
            .as_ref()
            .ok_or(Error::Unauthorized)?;
        if !Arc::ptr_eq(policy, &authorization.0) {
            return Err(Error::Unauthorized);
        }
        let authorized = policy.authorize(request)?;
        let ticket = self.admission_ticket()?;
        self.submit_single_admission(ticket, move |tx, options, now_micros| {
            let now = now_micros.div_euclid(1_000_000);
            admission::admit_static(tx, options.day_offset, authorized, now)
        })
        .await
    }

    /// Resolve hard affinity and list current eligible credential records for this pass.
    /// The writer checks affinity, catalog and all snapshots again at admission.
    pub async fn pool_credentials(
        &self,
        request: &ManagedAdmissionRequest,
        routing: &PoolRouting,
    ) -> Result<Vec<PoolCredential>> {
        request.validate()?;
        if !self.inner.pool_enabled {
            return Err(Error::Unauthorized);
        }
        let request = request.clone();
        let routing = routing.clone();
        self.command(true, move |writer| {
            let now = writer.now()?;
            writer.reserve.check_admission()?;
            admission::restore_allows_admission(writer.db.connection(), true, now)?;
            admission::pool_credentials(writer.db.connection(), &request, &routing, now)
        })
        .await
    }

    /// Local readiness candidates have at least one usable configured model and no
    /// credential-version authentication barrier. The caller verifies the envelope.
    pub async fn pool_readiness_credentials(&self) -> Result<Vec<AccountCredentialRecord>> {
        if !self.inner.pool_enabled {
            return Err(Error::Unauthorized);
        }
        self.command(true, |writer| {
            admission::pool_readiness_credentials(writer.db.connection(), writer.now()?)
        })
        .await
    }

    /// Resolve recent object history to a soft affinity for this Key's principal.
    pub async fn pool_hint(
        &self,
        key: &AuthenticatedKey,
        hints: &[ObjectBinding],
    ) -> Result<Option<AccountIdentity>> {
        if !self.inner.pool_enabled {
            return Err(Error::Unauthorized);
        }
        let key = key.clone();
        let recent = hints[hints.len().saturating_sub(64)..].to_vec();
        self.command(true, move |writer| {
            admission::resolve_hint(writer.db.connection(), &key, &recent, writer.now()?)
        })
        .await
    }

    /// Configure the complete health-tracked model set on the execution writer.
    pub async fn configure_health_models(&self, models: Vec<String>) -> Result<()> {
        let models: HashSet<_> = models.into_iter().collect();
        if models.len() > 48 || models.iter().any(|model| !valid_model(model)) {
            return Err(Error::InvalidCommand);
        }
        self.command(false, move |writer| {
            writer.write(true, |tx, _| {
                let mut stmt = tx.prepare("SELECT model FROM health_models")?;
                let existing = stmt
                    .query_map([], |row| row.get::<_, String>(0))?
                    .collect::<rusqlite::Result<HashSet<_>>>()?;
                for removed in existing.difference(&models) {
                    tx.execute("DELETE FROM health_models WHERE model=?1", [removed])?;
                }
                for added in models.difference(&existing) {
                    tx.execute("INSERT INTO health_models VALUES(?1)", [added])?;
                }
                Ok(())
            })?;
            writer.health.retain_models(|model| models.contains(model));
            Ok(())
        })
        .await
    }

    /// Prepare credentials on each pass and return only the selected transport work and lease.
    /// The caller's deadline or cancellation owns this future, including any pacing wait.
    pub async fn admit_pool<T, F, Fut>(
        &self,
        request: ManagedAdmissionRequest,
        mut prepare: F,
    ) -> Result<(Execution, T)>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<PreparedPool<T>>>,
    {
        request.validate()?;
        if !self.inner.pool_enabled {
            return Err(Error::Unauthorized);
        }
        loop {
            let ticket = self.admission_ticket()?;
            let PreparedPool {
                routing,
                candidates,
            } = prepare().await?;
            if candidates.len() > 64 {
                return Err(Error::InvalidCommand);
            }
            let snapshots = candidates
                .iter()
                .map(|(dispatch, _)| dispatch.clone())
                .collect();
            let request = request.clone();
            let admission = self
                .submit_admission(ticket, move |tx, options, health, now_micros| {
                    admission::admit_pool(
                        tx,
                        health,
                        options.day_offset,
                        request,
                        routing,
                        snapshots,
                        now_micros,
                    )
                })
                .await?;
            match admission {
                ControlFlow::Continue(execution) => {
                    let owner = &execution.admission().owner;
                    let (_, payload) = candidates
                        .into_iter()
                        .find(|(dispatch, _)| {
                            dispatch.id == owner.identity && dispatch.namespace == owner.namespace
                        })
                        .ok_or(Error::StorageUnavailable)?;
                    return Ok((execution, payload));
                }
                ControlFlow::Break(delay) => {
                    drop(candidates);
                    self.inner.pacing.wait(delay).await?;
                }
            }
        }
    }

    fn admission_ticket(&self) -> Result<OwnedSemaphorePermit> {
        match self.status() {
            ExecutionStatus::Accepting => {}
            ExecutionStatus::Failed => return Err(Error::StorageUnavailable),
            _ => return Err(Error::Closed),
        }
        self.inner
            .tickets
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::Capacity)
    }

    async fn submit_single_admission(
        &self,
        ticket: OwnedSemaphorePermit,
        write_intent: impl FnOnce(&Transaction<'_>, &Options, i64) -> Result<Admission> + Send + 'static,
    ) -> Result<Execution> {
        match self
            .submit_admission(ticket, move |tx, options, _, micros| {
                write_intent(tx, options, micros).map(ControlFlow::Continue)
            })
            .await?
        {
            ControlFlow::Continue(execution) => Ok(execution),
            ControlFlow::Break(_) => unreachable!("single-account admission does not pace"),
        }
    }

    async fn submit_admission(
        &self,
        ticket: OwnedSemaphorePermit,
        write_intent: impl FnOnce(
            &Transaction<'_>,
            &Options,
            &Health,
            i64,
        ) -> Result<ControlFlow<Duration, Admission>>
        + Send
        + 'static,
    ) -> Result<ControlFlow<Duration, Execution>> {
        let service = self.clone();
        self.command(true, move |writer| {
            writer.reserve.check_admission()?;
            let tx = writer.db.begin_immediate()?;
            let now_micros = (writer.options.clock)();
            check_time(now_micros.div_euclid(1_000_000))?;
            let admission = match write_intent(&tx, &writer.options, &writer.health, now_micros)? {
                ControlFlow::Continue(admission) => admission,
                ControlFlow::Break(delay) => return Ok(ControlFlow::Break(delay)),
            };
            tx.commit()?;
            // Registration is ordered with account mode and force-stop commands on
            // this writer. The finalization ticket bounds the live registry.
            let stop = admission.account_snapshot.as_ref().map(|_| {
                let stop = CancellationToken::new();
                service.inner.active().insert(
                    admission.attempt.clone(),
                    ActiveAccountExecution {
                        account: admission.owner.identity.clone(),
                        stop: stop.clone(),
                    },
                );
                stop
            });
            // If the admission future is cancelled after commit, dropping the undelivered
            // lease transfers finalization to the worker just like any other cancellation.
            Ok(ControlFlow::Continue(Execution {
                service,
                admission,
                ticket: Some(ticket),
                evidence: None,
                dispatched: false,
                binding_failed: false,
                stop,
            }))
        })
        .await
    }

    pub async fn snapshot(&self, attempt: &str) -> Result<Snapshot> {
        if !valid_string(attempt, 256) {
            return Err(Error::InvalidCommand);
        }
        let attempt = attempt.to_owned();
        self.command(false, move |writer| {
            ledger::snapshot(writer.db.connection(), &attempt)
        })
        .await
    }

    /// Reconcile a trusted observation delivered after the attempt's transport handed off.
    pub async fn reconcile(&self, attempt: &str, evidence: UsageEvidence) -> Result<()> {
        if !valid_string(attempt, 256) {
            return Err(Error::InvalidCommand);
        }
        evidence.validate()?;
        let attempt = attempt.to_owned();
        self.command(false, move |writer| {
            let snapshot = ledger::snapshot(writer.db.connection(), &attempt)?;
            if snapshot.state == State::Intent {
                return Err(Error::Conflict);
            }
            evidence.validate_for(&snapshot.admission)?;
            writer.finalize(&attempt, Some(&evidence), None)
        })
        .await
    }

    /// Close one bounded batch of expired unknowns. Schedule periodically from the runtime.
    pub async fn expire_unknown(&self) -> Result<usize> {
        self.command(false, |writer| {
            writer.reserve.check_optional()?;
            writer.write(false, ledger::expire_unknown)
        })
        .await
    }

    pub async fn release_unknown(&self, before: i64, expected: usize) -> Result<usize> {
        if !(0..=MAX_AMOUNT).contains(&before) {
            return Err(Error::InvalidCommand);
        }
        self.command(false, move |writer| {
            writer.write(true, |tx, now| {
                ledger::release_unknown(tx, before, expected, now)
            })
        })
        .await
    }

    /// Replenish the physical reserve and checkpoint WAL without waiting for readers.
    pub async fn maintain_storage(&self) -> Result<()> {
        self.command(false, |writer| {
            writer.reserve.maintain(writer.db.connection())
        })
        .await
    }
}

/// Linear dispatch and finalization ownership. Dropping an unfinished lease enqueues its
/// last captured usage snapshot, or leaves a durable intent if the worker has already closed.
#[must_use]
pub struct Execution {
    service: ExecutionService,
    admission: Admission,
    ticket: Option<OwnedSemaphorePermit>,
    evidence: Option<UsageEvidence>,
    dispatched: bool,
    binding_failed: bool,
    stop: Option<CancellationToken>,
}

impl Execution {
    pub fn admission(&self) -> &Admission {
        &self.admission
    }

    pub fn account_stop_token(&self) -> Option<&CancellationToken> {
        self.stop.as_ref()
    }

    pub fn was_force_stopped(&self) -> bool {
        self.stop
            .as_ref()
            .is_some_and(CancellationToken::is_cancelled)
    }

    /// Call immediately before dispatch. This authorizes one logical upstream operation.
    pub fn begin_dispatch(&mut self) -> Result<()> {
        if self.dispatched {
            return Err(Error::Conflict);
        }
        if self.was_force_stopped() {
            return Err(Error::AccountForceStopped);
        }
        match self.service.status() {
            ExecutionStatus::Accepting => {
                self.dispatched = true;
                Ok(())
            }
            ExecutionStatus::Failed => Err(Error::StorageUnavailable),
            _ => Err(Error::Closed),
        }
    }

    /// Commit all referenceable identifiers in an output before emitting any of that output.
    /// An error or cancelled bind poisons further binding on this lease. Stop exposing output.
    pub async fn bind(&mut self, objects: &[ObjectBinding]) -> Result<()> {
        if !self.dispatched || self.binding_failed {
            return Err(Error::Conflict);
        }
        self.binding_failed = true;
        if objects.len() > MAX_REFERENCES {
            return Err(Error::InvalidCommand);
        }
        objects.iter().try_for_each(ObjectBinding::validate)?;
        let objects = objects.to_vec();
        let attempt = self.admission.attempt.clone();
        self.service
            .command(false, move |writer| {
                writer.write(true, |tx, now| ledger::bind(tx, &attempt, &objects, now))
            })
            .await?;
        self.binding_failed = false;
        Ok(())
    }

    /// Observe trusted provider usage before attempting downstream output. Keeps one bounded snapshot.
    pub fn observe(&mut self, evidence: UsageEvidence) -> Result<()> {
        if !self.dispatched {
            return Err(Error::Conflict);
        }
        evidence.validate_for(&self.admission)?;
        if let Some(previous) = &self.evidence {
            if evidence.revision < previous.revision {
                return if previous.dominates(&evidence) {
                    Ok(())
                } else {
                    Err(Error::Conflict)
                };
            }
            if evidence.revision == previous.revision {
                return if evidence == *previous {
                    Ok(())
                } else {
                    Err(Error::Conflict)
                };
            }
            if !evidence.dominates(previous) {
                return Err(Error::Conflict);
            }
        }
        self.evidence = Some(evidence);
        Ok(())
    }

    /// Transfer finalization without awaiting I/O. Failure means the intent remains recoverable.
    pub fn finish(mut self, mut outcome: Option<Outcome>) -> Result<()> {
        if let Some(outcome) = &mut outcome {
            outcome.validate()?;
            outcome.actual_service_tier = outcome.actual_service_tier.take().map(sanitize_metadata);
            if outcome.kind == OutcomeKind::Succeeded && (!self.dispatched || self.binding_failed) {
                return Err(Error::Conflict);
            }
        }
        self.handoff(outcome)
    }

    pub fn cancel(self, at_unix_seconds: i64) -> Result<()> {
        self.finish(Some(Outcome::new(
            Some(Failure::ClientCancelled),
            at_unix_seconds,
        )))
    }

    fn handoff(&mut self, mut outcome: Option<Outcome>) -> Result<()> {
        let Some(ticket) = self.ticket.take() else {
            return Ok(());
        };
        let attempt = self.admission.attempt.clone();
        let evidence = self.evidence.take();
        let inner = self.service.inner.clone();
        if self.stop.is_some() {
            let stopped = inner
                .active()
                .remove(&attempt)
                .is_some_and(|entry| entry.stop.is_cancelled());
            let priming = self.admission.mode == Some(Mode::Priming);
            let has_priming_result = priming
                && outcome.as_ref().is_some_and(|outcome| {
                    matches!(
                        outcome.failure,
                        None | Some(Failure::AuthenticationRejected | Failure::RateLimited)
                    )
                });
            if stopped && !has_priming_result {
                let at = outcome.as_ref().map_or_else(
                    || system_time().div_euclid(1_000_000).max(1),
                    |outcome| outcome.at_unix_seconds,
                );
                // A forced stop after dispatch may have started a priming window.
                // Keep its barrier even when the generic account-stop result is definite.
                let failure = if priming && self.dispatched {
                    Failure::ClientCancelled
                } else {
                    Failure::AccountUnavailable
                };
                let mut updated = Outcome::new(Some(failure), at);
                if let Some(previous) = outcome {
                    updated.first_event_milliseconds = previous.first_event_milliseconds;
                    updated.total_milliseconds = previous.total_milliseconds;
                    updated.actual_service_tier = previous.actual_service_tier;
                }
                outcome = Some(updated);
            }
        }
        self.service.inner.enqueue(
            Box::new(move |writer| {
                let _ticket = ticket;
                let result = writer.finalize(&attempt, evidence.as_ref(), outcome.as_ref());
                if let Err(error) = result {
                    // Evidence within a retired revision range cannot replace newer truth. An
                    // active lease's normal handoff cannot be stale; other failures close admission.
                    if error != Error::StaleEvidence {
                        inner.fail();
                    }
                }
            }),
            false,
        )
    }
}

impl Drop for Execution {
    fn drop(&mut self) {
        let _ = self.handoff(None);
    }
}
