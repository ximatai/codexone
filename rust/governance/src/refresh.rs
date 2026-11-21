use std::{
    collections::HashMap,
    future::Future,
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

use codexone_storage::AccountCredential;
use tokio::sync::{Semaphore, watch};

use crate::{
    Account, AccountMode, AccountRuntime, AuthorizationState, Error, Governance, RefreshIntent,
    Result, VerifiedAuthorization, Writer, check_revision, id,
};

#[derive(Clone, Copy)]
pub enum RefreshFailure {
    /// The provider adapter has evidence that the request did not complete.
    NotCompleted,
    AuthorizationRequired,
    Unknown,
}

/// Implement with bounded transport and no token POST retry. Shutdown or timeout
/// drops the provider future before settling the refresh intent. Dropping it
/// must synchronously release the exchange's I/O ownership.
pub trait RefreshProvider: Send + Sync + 'static {
    fn refresh(
        &self,
        credential: &AccountCredential,
        namespace: &str,
    ) -> impl Future<Output = std::result::Result<VerifiedAuthorization, RefreshFailure>> + Send;
}

struct Entry {
    revision: i64,
    credential_version: Option<i64>,
    waiters: Arc<Semaphore>,
    result: watch::Receiver<Option<Result<Account>>>,
}

struct Inner<W, P> {
    governance: Arc<Governance<W>>,
    provider: P,
    jobs: Mutex<HashMap<String, Entry>>,
    parallel: Semaphore,
    waiters: Semaphore,
    stop: watch::Sender<bool>,
}

impl<W, P> Inner<W, P> {
    fn jobs(&self) -> MutexGuard<'_, HashMap<String, Entry>> {
        self.jobs.lock().expect("refresh jobs")
    }
}

pub struct RefreshService<W, P> {
    inner: Arc<Inner<W, P>>,
}

impl<W: Writer, P: RefreshProvider> RefreshService<W, P> {
    pub fn new(governance: Arc<Governance<W>>, provider: P) -> Self {
        let (stop, _) = watch::channel(false);
        Self {
            inner: Arc::new(Inner {
                governance,
                provider,
                jobs: Mutex::new(HashMap::new()),
                parallel: Semaphore::new(4),
                waiters: Semaphore::new(64),
                stop,
            }),
        }
    }

    pub async fn refresh_account(&self, account_id: String, revision: i64) -> Result<Account> {
        id(&account_id)
            .and_then(|_| check_revision(revision))
            .map_err(|_| Error::InvalidAuthorizationCommand)?;
        self.join(account_id, revision, None, true).await
    }

    pub async fn refresh_for_dispatch(&self, account: &Account) -> Result<Account> {
        if account.mode == AccountMode::Disabled
            || !matches!(
                account.authorization,
                AuthorizationState::Ready | AuthorizationState::Refreshing
            )
        {
            return Err(Error::AuthorizationUnavailable);
        }
        self.join(
            account.id.clone(),
            account.revision,
            Some(account.credential_version),
            account.authorization == AuthorizationState::Ready,
        )
        .await
    }

    async fn join(
        &self,
        account: String,
        revision: i64,
        version: Option<i64>,
        may_start: bool,
    ) -> Result<Account> {
        let _total = self
            .inner
            .waiters
            .try_acquire()
            .map_err(|_| Error::AuthorizationUnavailable)?;
        let (mut result, _account_waiter) = {
            let mut jobs = self.inner.jobs();
            if *self.inner.stop.borrow() {
                return Err(Error::AuthorizationUnavailable);
            }
            let entry = if let Some(entry) = jobs.get(&account) {
                let matches = match version.zip(entry.credential_version) {
                    Some((expected, actual)) => expected == actual,
                    None => revision == entry.revision,
                };
                if !matches {
                    return Err(Error::AccountConflict);
                }
                entry
            } else {
                if !may_start {
                    return Err(Error::AccountConflict);
                }
                if jobs.len() >= 16 {
                    return Err(Error::AuthorizationUnavailable);
                }
                let (reply, result) = watch::channel(None);
                let entry = Entry {
                    revision,
                    credential_version: None,
                    waiters: Arc::new(Semaphore::new(16)),
                    result,
                };
                let task = Task {
                    inner: self.inner.clone(),
                    account: account.clone(),
                    reply,
                    outcome: None,
                };
                jobs.insert(account.clone(), entry);
                tokio::spawn(task.run(revision, self.inner.stop.subscribe()));
                jobs.get(&account).expect("refresh job registered")
            };
            let permit = entry
                .waiters
                .clone()
                .try_acquire_owned()
                .map_err(|_| Error::AuthorizationUnavailable)?;
            (entry.result.clone(), permit)
        };
        let value = result
            .wait_for(Option::is_some)
            .await
            .map_err(|_| Error::AccountStorageUnavailable)?;
        value.as_ref().expect("refresh result present").clone()
    }

    /// Reject new refreshes, stop queued/network work, and await intent settlement.
    pub async fn shutdown(&self) {
        let wait = {
            let jobs = self.inner.jobs();
            self.inner.stop.send_replace(true);
            jobs.values()
                .map(|job| job.result.clone())
                .collect::<Vec<_>>()
        };
        for mut job in wait {
            let _ = job.wait_for(Option::is_some).await;
        }
    }
}

impl<W: Writer, P: RefreshProvider> AccountRuntime for RefreshService<W, P> {
    async fn refresh(&self, account: String, revision: i64) -> Result<Account> {
        self.refresh_account(account, revision).await
    }
}

struct Task<W, P> {
    inner: Arc<Inner<W, P>>,
    account: String,
    reply: watch::Sender<Option<Result<Account>>>,
    outcome: Option<Result<Account>>,
}

impl<W: Writer, P: RefreshProvider> Task<W, P> {
    async fn run(mut self, revision: i64, stop: watch::Receiver<bool>) {
        self.outcome = Some(self.execute(revision, stop).await);
    }

    async fn execute(&self, revision: i64, mut stop: watch::Receiver<bool>) -> Result<Account> {
        let _permit = tokio::select! {
            biased;
            _ = stop.wait_for(|value| *value) => return Err(Error::AuthorizationUnavailable),
            permit = self.inner.parallel.acquire() => permit.map_err(|_| Error::AuthorizationUnavailable)?,
        };
        let work = self
            .inner
            .governance
            .begin_refresh(self.account.clone(), revision)
            .await
            .map_err(refresh_error)?;
        if let Some(entry) = self.inner.jobs().get_mut(&self.account) {
            entry.credential_version = Some(work.account.credential_version);
        }
        // A stopped service still settles a committed intent on the same writer.
        let outcome = tokio::select! {
            biased;
            _ = stop.wait_for(|value| *value) => Err(RefreshFailure::Unknown),
            result = tokio::time::timeout(Duration::from_secs(10),
                self.inner.provider.refresh(&work.credential, &work.account.namespace)) =>
                result.unwrap_or(Err(RefreshFailure::Unknown)),
        };
        let result = self.settle(&work, outcome).await;
        if *stop.borrow() && !matches!(result, Err(Error::AccountStorageUnavailable)) {
            return Err(Error::AuthorizationUnavailable);
        }
        result
    }

    async fn settle(
        &self,
        work: &RefreshIntent,
        outcome: std::result::Result<VerifiedAuthorization, RefreshFailure>,
    ) -> Result<Account> {
        let governance = &self.inner.governance;
        let failure = match outcome {
            Ok(verified) => match governance.finish_refresh(work, verified).await {
                Ok(account) => return Ok(account),
                Err(error) => {
                    let settled = governance.fail_refresh(work, false).await;
                    settled_or_superseded(settled)?;
                    return Err(refresh_error(error));
                }
            },
            Err(failure) => failure,
        };
        let result = match failure {
            RefreshFailure::NotCompleted => governance.abandon_refresh(work).await,
            RefreshFailure::AuthorizationRequired => governance.fail_refresh(work, true).await,
            RefreshFailure::Unknown => governance.fail_refresh(work, false).await,
        };
        settled_or_superseded(result)?;
        Err(match failure {
            RefreshFailure::AuthorizationRequired => Error::AuthorizationRequired,
            _ => Error::AuthorizationUnavailable,
        })
    }
}

impl<W, P> Drop for Task<W, P> {
    fn drop(&mut self) {
        let mut jobs = self.inner.jobs();
        jobs.remove(&self.account);
        let result = self
            .outcome
            .take()
            .unwrap_or(Err(Error::AccountStorageUnavailable));
        self.reply.send_replace(Some(result));
    }
}

fn settled_or_superseded(result: Result<Account>) -> Result<()> {
    match result {
        Ok(_) | Err(Error::Conflict) => Ok(()),
        Err(_) => Err(Error::AccountStorageUnavailable),
    }
}

fn refresh_error(error: Error) -> Error {
    match error {
        Error::Conflict | Error::IdentityMismatch => Error::AccountConflict,
        Error::InvalidCommand => Error::InvalidAuthorizationCommand,
        Error::Capacity | Error::StoragePressure => Error::AuthorizationUnavailable,
        _ => Error::AccountStorageUnavailable,
    }
}
