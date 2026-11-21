use std::{
    collections::HashMap,
    future::Future,
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

use codexone_storage::AccountCredential;
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;
use tokio::{
    sync::{oneshot, watch},
    time::{Instant, sleep, sleep_until},
};
use zeroize::Zeroizing;

use crate::{Account, Error, Governance, Result, Writer, check_revision, id, nonce, uuid};

const CALLBACK_LIFETIME: Duration = Duration::from_secs(600);
const DEVICE_LIFETIME: Duration = Duration::from_secs(900);
const EXCHANGE_DEADLINE: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub enum Target {
    Create,
    Reauthorize { id: String, revision: i64 },
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AuthorizationMethod {
    Device,
    Callback,
}

/// Trusted provider response. Implementations must verify the provider issuer,
/// token claims, subject/account and (for callback) nonce before constructing it.
pub struct VerifiedAuthorization {
    pub namespace: String,
    pub credential: AccountCredential,
}

pub struct DeviceCode {
    pub device_auth_id: Zeroizing<String>,
    pub user_code: Zeroizing<String>,
    pub verification_url: String,
    pub interval_seconds: i64,
    pub expires_in_seconds: i64,
}

/// A valid grant from the fixed provider endpoint with its PKCE challenge verified.
pub struct DeviceGrant {
    pub code: Zeroizing<String>,
    pub verifier: Zeroizing<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureCode {
    ProviderRejected,
    ExchangeFailed,
    IdentityMismatch,
    VerificationFailed,
    RevisionConflict,
    DeviceCodeUnavailable,
    AuthorizationFailed,
}

#[derive(Clone, Copy, Debug)]
pub struct ProviderFailure {
    pub code: FailureCode,
    status: Option<u16>,
}

impl ProviderFailure {
    pub fn new(code: FailureCode, status: Option<u16>) -> Self {
        Self {
            code,
            status: status.filter(|status| (100..=599).contains(status)),
        }
    }
}

impl From<FailureCode> for ProviderFailure {
    fn from(code: FailureCode) -> Self {
        Self::new(code, None)
    }
}

#[derive(Clone, Copy)]
pub enum PollError {
    NoResponse,
    Failed(ProviderFailure),
}

/// The product provides fixed-endpoint transport and response verification. Futures
/// must own their network I/O and stop it when dropped. They must never retry exchanges.
pub trait AuthorizationProvider: Send + Sync + 'static {
    fn authorization_url(
        &self,
        state: &str,
        nonce: &str,
        verifier: &str,
    ) -> std::result::Result<String, FailureCode>;

    fn authorize(
        &self,
        code: &str,
        verifier: &str,
        nonce: &str,
    ) -> impl Future<Output = std::result::Result<VerifiedAuthorization, ProviderFailure>> + Send;

    fn request_device_code(
        &self,
    ) -> impl Future<Output = std::result::Result<DeviceCode, ProviderFailure>> + Send;

    fn poll_device_code(
        &self,
        code: &DeviceCode,
    ) -> impl Future<Output = std::result::Result<Option<DeviceGrant>, PollError>> + Send;

    fn authorize_device(
        &self,
        grant: &DeviceGrant,
    ) -> impl Future<Output = std::result::Result<VerifiedAuthorization, ProviderFailure>> + Send;
}

/// Type parameter for a Key-only service.
pub enum NoAuthorizationProvider {}

impl AuthorizationProvider for NoAuthorizationProvider {
    fn authorization_url(
        &self,
        _: &str,
        _: &str,
        _: &str,
    ) -> std::result::Result<String, FailureCode> {
        match *self {}
    }

    async fn authorize(
        &self,
        _: &str,
        _: &str,
        _: &str,
    ) -> std::result::Result<VerifiedAuthorization, ProviderFailure> {
        match *self {}
    }

    async fn request_device_code(&self) -> std::result::Result<DeviceCode, ProviderFailure> {
        match *self {}
    }

    async fn poll_device_code(
        &self,
        _: &DeviceCode,
    ) -> std::result::Result<Option<DeviceGrant>, PollError> {
        match *self {}
    }

    async fn authorize_device(
        &self,
        _: &DeviceGrant,
    ) -> std::result::Result<VerifiedAuthorization, ProviderFailure> {
        match *self {}
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Started {
    #[serde(rename = "flowID")]
    flow_id: String,
    method: AuthorizationMethod,
    expires_in_seconds: u64,
    #[serde(rename = "authorizationURL", skip_serializing_if = "Option::is_none")]
    authorization_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_code: Option<String>,
    #[serde(rename = "verificationURL", skip_serializing_if = "Option::is_none")]
    verification_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    interval_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure_code: Option<FailureCode>,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum State {
    Pending,
    Completed,
    Failed,
    Expired,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    status: State,
    expires_in_seconds: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_code: Option<String>,
    #[serde(rename = "accountID", skip_serializing_if = "Option::is_none")]
    account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure_code: Option<FailureCode>,
}

struct Proofs {
    state: Zeroizing<String>,
    nonce: Zeroizing<String>,
    verifier: Zeroizing<String>,
}

struct Flow {
    owner: String,
    target: Target,
    method: AuthorizationMethod,
    stage: &'static str,
    deadline: Instant,
    proofs: Option<Proofs>,
    user_code: Option<Zeroizing<String>>,
    state: State,
    account_id: Option<String>,
    failure: Option<FailureCode>,
    running: Option<Running>,
    discarded: bool,
}

impl Flow {
    fn log_failure(&self, code: FailureCode, cause: &'static str, provider_status: Option<u16>) {
        let method = match self.method {
            AuthorizationMethod::Callback => "callback",
            AuthorizationMethod::Device => "device",
        };
        tracing::warn!(
            method,
            failure_code = code.as_str(),
            stage = self.stage,
            cause,
            provider_status,
            "Account authorization failed"
        );
    }
}

impl FailureCode {
    fn as_str(self) -> &'static str {
        match self {
            Self::ProviderRejected => "provider_rejected",
            Self::ExchangeFailed => "exchange_failed",
            Self::IdentityMismatch => "identity_mismatch",
            Self::VerificationFailed => "verification_failed",
            Self::RevisionConflict => "revision_conflict",
            Self::DeviceCodeUnavailable => "device_code_unavailable",
            Self::AuthorizationFailed => "authorization_failed",
        }
    }
}

struct Running {
    cancel: watch::Sender<bool>,
    done: watch::Receiver<bool>,
    completing: bool,
}

struct Task<W, P> {
    inner: Arc<Inner<W, P>>,
    flow_id: String,
    cancel: watch::Receiver<bool>,
    done: watch::Sender<bool>,
}

struct Registry {
    accepting: bool,
    flows: HashMap<String, Flow>,
}

struct Inner<W, P> {
    governance: Arc<Governance<W>>,
    provider: P,
    registry: Mutex<Registry>,
}

impl<W, P> Inner<W, P> {
    fn registry(&self) -> MutexGuard<'_, Registry> {
        self.registry.lock().expect("authorization registry")
    }
}

pub struct Authorizations<W, P> {
    inner: Arc<Inner<W, P>>,
}

impl<W: Writer, P: AuthorizationProvider> Authorizations<W, P> {
    pub fn new(governance: Arc<Governance<W>>, provider: P) -> Self {
        Self {
            inner: Arc::new(Inner {
                governance,
                provider,
                registry: Mutex::new(Registry {
                    accepting: true,
                    flows: HashMap::new(),
                }),
            }),
        }
    }

    pub async fn begin(
        &self,
        owner: String,
        target: Target,
        method: AuthorizationMethod,
    ) -> Result<Started> {
        id(&owner).map_err(|_| Error::InvalidAuthorizationCommand)?;
        if let Target::Reauthorize {
            id: account_id,
            revision,
        } = &target
        {
            id(account_id)
                .and_then(|_| check_revision(*revision))
                .map_err(|_| Error::InvalidAuthorizationCommand)?;
        }
        let flow_id = uuid()?;
        let response = {
            let mut registry = self.inner.registry();
            if !registry.accepting {
                return Err(Error::AuthorizationUnavailable);
            }
            registry
                .flows
                .retain(|_, flow| flow.deadline > Instant::now() || flow.running.is_some());
            if registry.flows.len() >= 8 || registry.flows.contains_key(&flow_id) {
                return Err(Error::AuthorizationUnavailable);
            }
            let mut flow = Flow {
                owner,
                target,
                method,
                stage: "request",
                deadline: Instant::now() + DEVICE_LIFETIME,
                proofs: None,
                user_code: None,
                state: State::Pending,
                account_id: None,
                failure: None,
                running: None,
                discarded: false,
            };
            if method == AuthorizationMethod::Callback {
                flow.deadline = Instant::now() + CALLBACK_LIFETIME;
                let proofs = Proofs {
                    state: nonce()?,
                    nonce: nonce()?,
                    verifier: nonce()?,
                };
                let url = self
                    .inner
                    .provider
                    .authorization_url(&proofs.state, &proofs.nonce, &proofs.verifier)
                    .map_err(|_| Error::AuthorizationUnavailable)?;
                flow.proofs = Some(proofs);
                let mut started = started(flow_id.clone(), method, flow.deadline);
                started.authorization_url = Some(url);
                registry.flows.insert(flow_id, flow);
                return Ok(started);
            }
            let deadline = flow.deadline;
            let task = self.task(&flow_id, &mut flow, false);
            registry.flows.insert(flow_id, flow);
            let (reply, response) = oneshot::channel();
            tokio::spawn(task.device(deadline, reply));
            response
        };
        response.await.map_err(|_| Error::AuthorizationUnavailable)
    }

    pub fn status(&self, owner: &str, flow_id: &str) -> Result<Status> {
        let registry = self.inner.registry();
        let flow = owned(&registry, owner, flow_id)?;
        let state = if flow.state == State::Pending && flow.deadline <= Instant::now() {
            State::Expired
        } else {
            flow.state
        };
        Ok(Status {
            status: state,
            expires_in_seconds: remaining(flow.deadline),
            user_code: flow
                .user_code
                .as_ref()
                .filter(|_| state == State::Pending)
                .map(|code| code.as_str().to_owned()),
            account_id: flow.account_id.clone(),
            failure_code: flow.failure,
        })
    }

    pub async fn complete(
        &self,
        owner: &str,
        flow_id: &str,
        callback: Zeroizing<String>,
    ) -> Result<Account> {
        let response = {
            let mut registry = self.inner.registry();
            if !registry.accepting {
                return Err(Error::AuthorizationUnavailable);
            }
            owned(&registry, owner, flow_id)?;
            let full = completion_count(&registry) >= 4;
            let flow = registry
                .flows
                .get_mut(flow_id)
                .ok_or(Error::AccountConflict)?;
            if flow.proofs.is_none() || flow.state != State::Pending {
                return Err(Error::AccountConflict);
            }
            if full {
                return Err(Error::AuthorizationUnavailable);
            }
            let proofs = flow.proofs.take().ok_or(Error::AccountConflict)?;
            if flow.deadline <= Instant::now() {
                flow.state = State::Expired;
                return Err(Error::AccountConflict);
            }
            let Some(code) = callback_code(&callback, &proofs.state) else {
                flow.state = State::Failed;
                flow.failure = Some(FailureCode::VerificationFailed);
                flow.log_failure(FailureCode::VerificationFailed, "InvalidCallback", None);
                return Err(Error::InvalidAuthorizationCommand);
            };
            flow.stage = "exchange";
            let task = self.task(flow_id, flow, true);
            let (reply, response) = oneshot::channel();
            tokio::spawn(async move {
                let result = task.callback(code, proofs).await;
                let _ = reply.send(result);
            });
            response
        };
        response
            .await
            .map_err(|_| Error::AuthorizationUnavailable)?
    }

    pub async fn discard(&self, owner: &str, flow_id: &str) -> Result<()> {
        let wait = {
            let mut registry = self.inner.registry();
            owned(&registry, owner, flow_id)?;
            cancel(&mut registry, flow_id)
        };
        if let Some(mut wait) = wait {
            let _ = wait.wait_for(|done| *done).await;
        }
        Ok(())
    }

    /// Stop new flows, cancel provider I/O, and wait for in-progress commits.
    pub async fn shutdown(&self) {
        let waits = {
            let mut registry = self.inner.registry();
            registry.accepting = false;
            let ids: Vec<_> = registry.flows.keys().cloned().collect();
            ids.iter()
                .filter_map(|id| cancel(&mut registry, id))
                .collect::<Vec<_>>()
        };
        for mut wait in waits {
            let _ = wait.wait_for(|done| *done).await;
        }
    }

    fn task(&self, flow_id: &str, flow: &mut Flow, completing: bool) -> Task<W, P> {
        let (signal, cancel) = watch::channel(false);
        let (done, wait) = watch::channel(false);
        flow.running = Some(Running {
            cancel: signal,
            done: wait,
            completing,
        });
        Task {
            inner: self.inner.clone(),
            flow_id: flow_id.into(),
            cancel,
            done,
        }
    }
}

impl<W: Writer, P: AuthorizationProvider> Task<W, P> {
    async fn callback(mut self, code: Zeroizing<String>, proofs: Proofs) -> Result<Account> {
        let deadline = Instant::now() + EXCHANGE_DEADLINE;
        let result = match interrupt(
            &mut self.cancel,
            deadline,
            self.inner
                .provider
                .authorize(&code, &proofs.verifier, &proofs.nonce),
        )
        .await
        {
            Ok(Ok(verified)) => self.persist(verified, None).await,
            Ok(Err(code)) => Err(TaskError::Provider(code)),
            Err(TaskError::Expired) => Err(TaskError::Provider(FailureCode::ExchangeFailed.into())),
            Err(error) => Err(error),
        };
        self.finish(&result);
        result.map_err(TaskError::http)
    }

    async fn device(mut self, mut deadline: Instant, reply: oneshot::Sender<Started>) {
        let created = interrupt(
            &mut self.cancel,
            deadline,
            self.inner.provider.request_device_code(),
        )
        .await;
        let mut output = started(self.flow_id.clone(), AuthorizationMethod::Device, deadline);
        match created {
            Ok(Ok(device)) => {
                let interval = device.interval_seconds.clamp(3, 30) as u64;
                deadline = deadline.min(
                    Instant::now()
                        + Duration::from_secs(device.expires_in_seconds.clamp(1, 900) as u64),
                );
                let pending = {
                    let mut registry = self.inner.registry();
                    registry
                        .flows
                        .get_mut(&self.flow_id)
                        .filter(|flow| !flow.discarded)
                        .map(|flow| {
                            flow.deadline = deadline;
                            flow.user_code = Some(device.user_code.clone());
                            flow.stage = "poll";
                        })
                        .is_some()
                };
                if pending {
                    output.expires_in_seconds = remaining(deadline);
                    output.user_code = Some(device.user_code.to_string());
                    output.verification_url = Some(device.verification_url.clone());
                    output.interval_seconds = Some(interval);
                    let _ = reply.send(output);
                    let result = self
                        .poll(&device, Duration::from_secs(interval), deadline)
                        .await;
                    self.finish(&result);
                    return;
                }
                self.finish(&Err(TaskError::Cancelled));
            }
            Ok(Err(code)) => {
                output.failure_code = Some(code.code);
                self.finish(&Err(TaskError::Provider(code)));
            }
            Err(error) => self.finish(&Err(error)),
        }
        output
            .failure_code
            .get_or_insert(FailureCode::AuthorizationFailed);
        output.expires_in_seconds = remaining(deadline);
        let _ = reply.send(output);
    }

    async fn poll(
        &mut self,
        device: &DeviceCode,
        interval: Duration,
        deadline: Instant,
    ) -> std::result::Result<Account, TaskError> {
        let mut failures = 0;
        let grant = loop {
            match interrupt(&mut self.cancel, deadline, async {
                sleep(interval).await;
                self.inner.provider.poll_device_code(device).await
            })
            .await?
            {
                Ok(Some(grant)) => break grant,
                Ok(None) => failures = 0,
                Err(PollError::NoResponse) if failures < 5 => {
                    failures += 1;
                    tracing::info!(cause = "NoResponse", "Account authorization poll retry");
                }
                Err(PollError::NoResponse) => {
                    return Err(TaskError::Provider(FailureCode::AuthorizationFailed.into()));
                }
                Err(PollError::Failed(code)) => return Err(TaskError::Provider(code)),
            }
        };
        {
            let mut registry = self.inner.registry();
            if completion_count(&registry) >= 4 {
                return Err(TaskError::Provider(FailureCode::AuthorizationFailed.into()));
            }
            let flow = registry
                .flows
                .get_mut(&self.flow_id)
                .filter(|flow| !flow.discarded)
                .ok_or(TaskError::Cancelled)?;
            flow.running
                .as_mut()
                .ok_or(TaskError::Cancelled)?
                .completing = true;
            flow.stage = "exchange";
        }
        let exchange_deadline = deadline.min(Instant::now() + EXCHANGE_DEADLINE);
        let verified = interrupt(
            &mut self.cancel,
            exchange_deadline,
            self.inner.provider.authorize_device(&grant),
        )
        .await
        .map_err(|error| {
            if matches!(error, TaskError::Expired) && exchange_deadline < deadline {
                TaskError::Provider(FailureCode::ExchangeFailed.into())
            } else {
                error
            }
        })?
        .map_err(TaskError::Provider)?;
        self.persist(verified, Some(deadline)).await
    }

    async fn persist(
        &self,
        verified: VerifiedAuthorization,
        deadline: Option<Instant>,
    ) -> std::result::Result<Account, TaskError> {
        let target = {
            let mut registry = self.inner.registry();
            if !registry.accepting {
                return Err(TaskError::Cancelled);
            }
            let flow = registry
                .flows
                .get_mut(&self.flow_id)
                .filter(|flow| !flow.discarded)
                .ok_or(TaskError::Cancelled)?;
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return Err(TaskError::Expired);
            }
            flow.stage = "persist";
            flow.target.clone()
        };
        // Once authorized to persist, this task owns the writer reply through completion.
        self.inner
            .governance
            .seal_verified(target, verified)
            .await
            .map_err(TaskError::Store)
    }

    fn finish(&self, result: &std::result::Result<Account, TaskError>) {
        let mut registry = self.inner.registry();
        let Some(flow) = registry
            .flows
            .get_mut(&self.flow_id)
            .filter(|flow| !flow.discarded)
        else {
            return;
        };
        flow.user_code = None;
        match result {
            Ok(account) => {
                flow.state = State::Completed;
                flow.account_id = Some(account.id.clone());
            }
            Err(error)
                if matches!(error, TaskError::Expired) || flow.deadline <= Instant::now() =>
            {
                flow.state = State::Expired;
            }
            Err(error) => {
                flow.state = State::Failed;
                flow.failure = Some(error.code());
                let (cause, status) = error.diagnostic();
                flow.log_failure(error.code(), cause, status);
            }
        }
    }
}

impl<W, P> Drop for Task<W, P> {
    fn drop(&mut self) {
        let mut registry = self.inner.registry();
        if let Some(flow) = registry.flows.get_mut(&self.flow_id) {
            if flow.discarded {
                registry.flows.remove(&self.flow_id);
            } else {
                if flow.state == State::Pending {
                    flow.state = State::Failed;
                    flow.failure = Some(FailureCode::AuthorizationFailed);
                    flow.user_code = None;
                }
                flow.running = None;
            }
        }
        self.done.send_replace(true);
    }
}

fn completion_count(registry: &Registry) -> usize {
    registry
        .flows
        .values()
        .filter(|flow| flow.running.as_ref().is_some_and(|run| run.completing))
        .count()
}

fn owned<'a>(registry: &'a Registry, owner: &str, flow_id: &str) -> Result<&'a Flow> {
    registry
        .flows
        .get(flow_id)
        .filter(|flow| !flow.discarded && flow.owner == owner)
        .ok_or(Error::AccountConflict)
}

fn cancel(registry: &mut Registry, id: &str) -> Option<watch::Receiver<bool>> {
    let flow = registry.flows.get_mut(id)?;
    let Some(running) = &flow.running else {
        registry.flows.remove(id);
        return None;
    };
    flow.discarded = true;
    flow.user_code = None;
    running.cancel.send_replace(true);
    Some(running.done.clone())
}

enum TaskError {
    Provider(ProviderFailure),
    Store(Error),
    Cancelled,
    Expired,
}

impl TaskError {
    fn code(&self) -> FailureCode {
        match self {
            Self::Provider(failure) => failure.code,
            Self::Store(Error::Conflict) => FailureCode::RevisionConflict,
            Self::Store(Error::IdentityMismatch) => FailureCode::IdentityMismatch,
            _ => FailureCode::AuthorizationFailed,
        }
    }

    fn diagnostic(&self) -> (&'static str, Option<u16>) {
        match self {
            Self::Provider(failure) => ("ProviderFailure", failure.status),
            Self::Store(_) => ("GovernanceError", None),
            Self::Cancelled => ("Cancelled", None),
            Self::Expired => ("Expired", None),
        }
    }

    fn http(self) -> Error {
        match self {
            Self::Store(Error::Conflict | Error::IdentityMismatch) | Self::Expired => {
                Error::AccountConflict
            }
            Self::Store(Error::Unavailable | Error::UnknownAccount | Error::StoragePressure) => {
                Error::AccountStorageUnavailable
            }
            Self::Store(Error::InvalidCommand) => Error::InvalidAuthorizationCommand,
            Self::Provider(ProviderFailure {
                code: FailureCode::IdentityMismatch | FailureCode::RevisionConflict,
                ..
            }) => Error::AccountConflict,
            Self::Provider(ProviderFailure {
                code: FailureCode::ExchangeFailed,
                status: Some(400 | 401),
            }) => Error::AuthorizationRequired,
            Self::Provider(_) => Error::AuthorizationUnavailable,
            _ => Error::AuthorizationUnavailable,
        }
    }
}

async fn interrupt<T>(
    cancel: &mut watch::Receiver<bool>,
    deadline: Instant,
    operation: impl Future<Output = T>,
) -> std::result::Result<T, TaskError> {
    tokio::select! {
        biased;
        _ = cancel.wait_for(|cancelled| *cancelled) => Err(TaskError::Cancelled),
        _ = sleep_until(deadline) => Err(TaskError::Expired),
        result = operation => Ok(result),
    }
}

fn started(flow_id: String, method: AuthorizationMethod, deadline: Instant) -> Started {
    Started {
        flow_id,
        method,
        expires_in_seconds: remaining(deadline),
        authorization_url: None,
        user_code: None,
        verification_url: None,
        interval_seconds: None,
        failure_code: None,
    }
}

fn remaining(deadline: Instant) -> u64 {
    let duration = deadline.saturating_duration_since(Instant::now());
    duration.as_secs() + u64::from(duration.subsec_nanos() > 0)
}

fn callback_code(raw: &str, state: &str) -> Option<Zeroizing<String>> {
    if raw.len() > 8192 || !raw.bytes().all(|byte| byte.is_ascii_graphic()) {
        return None;
    }
    // Compare the raw authority/path too: URL parsers normalize dot segments and userinfo.
    let (base, query) = raw.split_once('?')?;
    if base != "http://localhost:1455/auth/callback" || query.contains('#') {
        return None;
    }
    let mut code = None;
    let mut state_seen = false;
    let mut scope_seen = false;
    for field in query.split('&') {
        let (name, value) = field.split_once('=').unwrap_or((field, ""));
        let name = callback_field(name)?;
        let value = callback_field(value)?;
        match name.as_ref() {
            "code"
                if code.is_none()
                    && (1..=4096).contains(&value.len())
                    && value.bytes().all(|byte| byte.is_ascii_graphic()) =>
            {
                code = Some(Zeroizing::new(value.into_owned()));
            }
            "state" if !state_seen && bool::from(value.as_bytes().ct_eq(state.as_bytes())) => {
                state_seen = true
            }
            "scope" if !scope_seen && value.len() <= 1024 => scope_seen = true,
            _ => return None,
        }
    }
    state_seen.then_some(code).flatten()
}

fn callback_field(raw: &str) -> Option<std::borrow::Cow<'_, str>> {
    if raw.match_indices('%').any(|(offset, _)| {
        raw.as_bytes()
            .get(offset + 1..offset + 3)
            .is_none_or(|escape| !escape.iter().all(u8::is_ascii_hexdigit))
    }) {
        return None;
    }
    percent_encoding::percent_decode_str(raw).decode_utf8().ok()
}
