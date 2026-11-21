use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use codexone_storage::{Database, bearer_digest};
use rusqlite::Transaction;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, oneshot, watch};

use crate::model::*;
use crate::reserve::StorageReserve;
use crate::{
    ExecutionError as Error, Result, StaticAdmissionRequest, StaticAuthorization, StaticIdentity,
    admission, ledger,
};

const REGULAR_CAPACITY: usize = 16;

type Job = Box<dyn FnOnce(&mut Writer) + Send>;

enum IdentitySource {
    Managed(String),
    Static(Arc<StaticIdentity>),
}

pub struct Options {
    identity: IdentitySource,
    day_offset: i64,
    capacity: usize,
    clock: Arc<dyn Fn() -> i64 + Send + Sync>,
}

impl Options {
    pub fn new(account_id: impl Into<String>) -> Self {
        Self::with_identity(IdentitySource::Managed(account_id.into()))
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

    pub fn with_clock(mut self, clock: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.clock = Arc::new(clock);
        self
    }
}

fn system_time() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
        .unwrap_or(0)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionStatus {
    Accepting,
    Draining,
    Failed,
    Closed,
}

struct Gate {
    sender: Option<SyncSender<Job>>,
    status: ExecutionStatus,
}

struct Inner {
    static_identity: Option<Arc<StaticIdentity>>,
    gate: Mutex<Gate>,
    regular: Arc<Semaphore>,
    tickets: Arc<Semaphore>,
    capacity: u32,
    done: watch::Receiver<bool>,
}

impl Inner {
    fn gate(&self) -> MutexGuard<'_, Gate> {
        self.gate
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn fail(&self) {
        self.gate().status = ExecutionStatus::Failed;
    }

    fn enqueue(&self, job: Job, admission: bool) -> Result<()> {
        let mut gate = self.gate();
        if admission {
            match gate.status {
                ExecutionStatus::Accepting => {}
                ExecutionStatus::Failed => return Err(Error::StorageUnavailable),
                _ => return Err(Error::Closed),
            }
        }
        let sender = gate.sender.as_ref().ok_or(Error::Closed)?;
        if let Err(error) = sender.try_send(job) {
            gate.status = ExecutionStatus::Failed;
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
                gate.status = ExecutionStatus::Failed;
            }
        }
        self.done.send_replace(true);
    }
}

struct Writer {
    db: Database,
    reserve: StorageReserve,
    options: Options,
}

impl Writer {
    fn open(path: PathBuf, options: Options) -> Result<Self> {
        let path = path.canonicalize().map_err(|_| Error::StorageUnavailable)?;
        let db = Database::open_existing(&path)?;
        let reserve = StorageReserve::open(&path)?;
        let mut writer = Self {
            db,
            reserve,
            options,
        };
        writer.reserve.maintain(writer.db.connection())?;
        writer.write(true, ledger::recover)?;
        Ok(writer)
    }

    fn now(&self) -> Result<i64> {
        check_time((self.options.clock)())
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
        let now = check_time((self.options.clock)())?;
        let result = body(&tx, now)?;
        tx.commit()?;
        Ok(result)
    }
}

/// Cloneable handle to a single bounded SQLite writer and execution finalizer.
#[derive(Clone)]
pub struct ExecutionService {
    inner: Arc<Inner>,
}

impl ExecutionService {
    /// Open a v19 database, acquire the instance lock and recover abandoned intents before returning.
    pub async fn open(path: impl AsRef<Path>, options: Options) -> Result<Self> {
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
                IdentitySource::Managed(_) => None,
            },
            gate: Mutex::new(Gate {
                sender: Some(sender),
                status: ExecutionStatus::Accepting,
            }),
            regular: Arc::new(Semaphore::new(REGULAR_CAPACITY)),
            tickets: Arc::new(Semaphore::new(capacity)),
            capacity: capacity as u32,
            done: done_rx,
        });
        let exit = WorkerExit {
            inner: Arc::downgrade(&inner),
            done: done_tx,
        };
        let path = path.as_ref().to_owned();
        thread::Builder::new()
            .name("codexone-execution".into())
            .spawn(move || {
                let _exit = exit;
                match Writer::open(path, options) {
                    Ok(mut writer) => {
                        if ready_tx.send(Ok(())).is_ok() {
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
        ready_rx.await.map_err(|_| Error::StorageUnavailable)??;
        Ok(Self { inner })
    }

    pub fn status(&self) -> ExecutionStatus {
        self.inner.gate().status
    }

    pub fn outstanding(&self) -> usize {
        self.inner.capacity as usize - self.inner.tickets.available_permits()
    }

    pub fn stop_admission(&self) {
        let mut gate = self.inner.gate();
        if gate.status == ExecutionStatus::Accepting {
            gate.status = ExecutionStatus::Draining;
        }
    }

    /// Stop admission, wait for leases to hand off and drain queued writes. Apply the runtime's
    /// shutdown deadline to this future, then call force_shutdown if the deadline elapses.
    pub async fn shutdown(&self) -> Result<()> {
        self.stop_admission();
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
            if gate.status != ExecutionStatus::Failed {
                gate.status = ExecutionStatus::Closed;
            }
            gate.sender.take();
        }
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
        let permit = self
            .inner
            .regular
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::Capacity)?;
        let inner = self.inner.clone();
        let (reply, response) = oneshot::channel();
        self.inner.enqueue(
            Box::new(move |writer| {
                let _permit = permit;
                if reply.is_closed() {
                    return;
                }
                let status = inner.gate().status;
                let result = match (opening_attempt, status) {
                    (true, ExecutionStatus::Accepting) | (false, _) => body(writer),
                    (true, ExecutionStatus::Failed) => Err(Error::StorageUnavailable),
                    _ => Err(Error::Closed),
                };
                if matches!(result, Err(Error::StorageUnavailable)) {
                    inner.fail();
                }
                let _ = reply.send(result);
            }),
            opening_attempt,
        )?;
        response.await.map_err(|_| Error::StorageUnavailable)?
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
        request.validate()?;
        self.submit_admission(move |tx, options, now| {
            let IdentitySource::Managed(account) = &options.identity else {
                return Err(Error::Unauthorized);
            };
            admission::admit(tx, account, options.day_offset, request, now)
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
        self.submit_admission(move |tx, options, now| {
            admission::admit_static(tx, options.day_offset, authorized, now)
        })
        .await
    }

    async fn submit_admission(
        &self,
        write_intent: impl FnOnce(&Transaction<'_>, &Options, i64) -> Result<Admission> + Send + 'static,
    ) -> Result<Execution> {
        let ticket = self
            .inner
            .tickets
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::Capacity)?;
        let service = self.clone();
        self.command(true, move |writer| {
            writer.reserve.check_admission()?;
            let tx = writer.db.begin_immediate()?;
            let now = check_time((writer.options.clock)())?;
            let admission = write_intent(&tx, &writer.options, now)?;
            tx.commit()?;
            // If the admission future is cancelled after commit, dropping the undelivered
            // lease transfers finalization to the worker just like any other cancellation.
            Ok(Execution {
                service,
                admission,
                ticket: Some(ticket),
                evidence: None,
                dispatched: false,
                binding_failed: false,
            })
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
            writer.reserve.prepare_critical()?;
            let now = writer.now()?;
            ledger::finalize(&mut writer.db, &attempt, Some(&evidence), None, now)
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
}

impl Execution {
    pub fn admission(&self) -> &Admission {
        &self.admission
    }

    /// Call immediately before dispatch. This authorizes one logical upstream operation.
    pub fn begin_dispatch(&mut self) -> Result<()> {
        if self.dispatched {
            return Err(Error::Conflict);
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

    fn handoff(&mut self, outcome: Option<Outcome>) -> Result<()> {
        let Some(ticket) = self.ticket.take() else {
            return Ok(());
        };
        let attempt = self.admission.attempt.clone();
        let evidence = self.evidence.take();
        let inner = self.service.inner.clone();
        self.service.inner.enqueue(
            Box::new(move |writer| {
                let _ticket = ticket;
                let result = (|| {
                    writer.reserve.prepare_critical()?;
                    let now = writer.now()?;
                    ledger::finalize(
                        &mut writer.db,
                        &attempt,
                        evidence.as_ref(),
                        outcome.as_ref(),
                        now,
                    )
                })();
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
