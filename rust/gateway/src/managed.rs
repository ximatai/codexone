use std::{sync::Arc, time::Instant as Monotonic};

use bytes::Bytes;
use codexone_admin::AdminRouter;
use codexone_config::{MasterKeyring, ResponsesConfiguration};
use codexone_execution::{
    AccountCredentialRecord, AccountDispatch, AccountDispatchSnapshot, AccountIdentity, Execution,
    ExecutionError, ExecutionService, GovernanceWork, ManagedAdmissionRequest, ObjectBinding,
    PoolRouting, PreparedPool, SessionAffinity, SessionLabel, TurnStateOwners,
};
use codexone_governance::{
    self as governance, AccountRuntime, Authorizations, Governance, GovernanceApi, KeyOptions,
};
use codexone_http_upstream::Proxy;
use codexone_identity_runtime::{IdentityRuntime, SubscriptionProvider};
use codexone_storage::{AccountCredentialCipher, AccountCredentialContext, Database};
use futures_util::{StreamExt, stream};
use http::{HeaderMap, Request, Response};
use rusqlite::Transaction;
use tokio::time::{Instant, timeout_at};
use zeroize::Zeroizing;

use crate::headers;

const SUBSCRIPTION_BASE: &str = "https://chatgpt.com/backend-api/codex";

#[derive(Clone)]
pub(crate) struct GovernanceWriter(ExecutionService);

impl governance::Writer for GovernanceWriter {
    async fn run<T: Send + 'static>(
        &self,
        work: governance::Work,
        operation: impl FnOnce(&mut Database, i64, bool) -> governance::Result<T> + Send + 'static,
    ) -> governance::Result<T> {
        let work = match work {
            governance::Work::Read => GovernanceWork::Read,
            governance::Work::Optional => GovernanceWork::Optional,
            governance::Work::Restrict => GovernanceWork::Restrict,
            governance::Work::Admission => GovernanceWork::Admission,
            governance::Work::Critical => GovernanceWork::Critical,
        };
        self.0
            .governance_command(work, operation)
            .await
            .map_err(|error| match error {
                ExecutionError::Capacity => governance::Error::Capacity,
                ExecutionError::StoragePressure => governance::Error::StoragePressure,
                ExecutionError::Closed => governance::Error::AuthorizationUnavailable,
                _ => governance::Error::AccountStorageUnavailable,
            })?
    }
}

pub fn recover(tx: &Transaction<'_>, now: i64) -> codexone_execution::Result<()> {
    governance::recover_refreshes(tx, now).map_err(|_| ExecutionError::StorageUnavailable)
}

pub struct SubscriptionTarget {
    provider: SubscriptionProvider,
    base: String,
}

impl SubscriptionTarget {
    pub fn production(proxy: Option<Proxy>) -> Self {
        Self {
            provider: SubscriptionProvider::production(proxy),
            base: SUBSCRIPTION_BASE.into(),
        }
    }

    #[cfg(test)]
    pub fn synthetic_loopback(
        auth_port: std::num::NonZeroU16,
        data_port: std::num::NonZeroU16,
    ) -> Self {
        Self {
            provider: SubscriptionProvider::synthetic_loopback(
                auth_port,
                data_port,
                crate::unix_time,
            ),
            base: format!("http://127.0.0.1:{data_port}/backend-api/codex"),
        }
    }
}

pub struct Managed {
    api: GovernanceApi<GovernanceWriter, SubscriptionProvider, Runtime>,
    options: KeyOptions,
    runtime: Option<IdentityRuntime<GovernanceWriter>>,
}

impl Managed {
    pub fn new(
        execution: ExecutionService,
        keyring: Option<MasterKeyring>,
        target: SubscriptionTarget,
        options: KeyOptions,
    ) -> Result<(Self, Option<Arc<Pool>>), ()> {
        let writer = GovernanceWriter(execution);
        let keyring = keyring.map(Keyring::new);
        let cipher = || keyring.as_ref().map(Keyring::cipher).transpose();
        let store = Arc::new(Governance::new(writer.clone(), cipher()?));
        let authorization = keyring
            .as_ref()
            .map(|_| Authorizations::new(store.clone(), target.provider.clone()));
        let runtime = if let Some(cipher) = cipher()? {
            Some(IdentityRuntime::new(
                writer,
                store.clone(),
                cipher,
                target.provider.clone(),
            ))
        } else {
            None
        };
        let pool = runtime.clone().zip(cipher()?).map(|(runtime, cipher)| {
            Arc::new(Pool {
                runtime,
                cipher,
                target,
                sessions: SessionAffinity::default(),
                turn_states: TurnStateOwners::default(),
            })
        });
        let api = GovernanceApi::new(store, authorization, Runtime(runtime.clone()));
        Ok((
            Self {
                api,
                options,
                runtime,
            },
            pool,
        ))
    }

    pub async fn route(
        &self,
        admin: &AdminRouter,
        request: &Request<Bytes>,
    ) -> Option<Response<Bytes>> {
        self.api
            .route(admin, request, || KeyOptions {
                models: self.options.models.clone(),
                image_models: self.options.image_models.clone(),
                reasoning_efforts: self.options.reasoning_efforts.clone(),
                catalog_revision: self.options.catalog_revision,
            })
            .await
    }

    pub fn supervise(
        &self,
    ) -> Option<impl Future<Output = governance::Result<()>> + Send + 'static> {
        let runtime = self.runtime.clone()?;
        Some(async move { runtime.run_periodic().await })
    }

    pub async fn shutdown(&self) {
        self.api.shutdown().await;
        if let Some(runtime) = &self.runtime {
            runtime.shutdown().await;
        }
    }
}

struct Runtime(Option<IdentityRuntime<GovernanceWriter>>);

impl AccountRuntime for Runtime {
    async fn refresh(
        &self,
        account: String,
        revision: i64,
    ) -> governance::Result<governance::Account> {
        self.0
            .as_ref()
            .ok_or(governance::Error::AuthorizationUnavailable)?
            .refresh(account, revision)
            .await
    }

    async fn observability(&self, account: &str) -> governance::Result<serde_json::Value> {
        self.0
            .as_ref()
            .ok_or(governance::Error::AuthorizationUnavailable)?
            .observability(account)
            .await
    }
}

struct Keyring {
    active: Zeroizing<String>,
    decrypt_only: Vec<Zeroizing<String>>,
}

impl Keyring {
    fn new(keyring: MasterKeyring) -> Self {
        Self {
            active: Zeroizing::new(hex::encode(keyring.active.as_slice())),
            decrypt_only: keyring
                .decrypt_only
                .iter()
                .map(|key| Zeroizing::new(hex::encode(key.as_slice())))
                .collect(),
        }
    }

    fn cipher(&self) -> Result<AccountCredentialCipher, ()> {
        let keys: Vec<_> = self.decrypt_only.iter().map(|key| key.as_str()).collect();
        AccountCredentialCipher::from_hex(&self.active, &keys).map_err(|_| ())
    }
}

pub struct Pool {
    runtime: IdentityRuntime<GovernanceWriter>,
    cipher: AccountCredentialCipher,
    target: SubscriptionTarget,
    sessions: SessionAffinity,
    turn_states: TurnStateOwners,
}

pub struct Affinity<'a> {
    pub hints: &'a [ObjectBinding],
    pub turn_state: Option<&'a str>,
    pub headers: &'a HeaderMap,
}

impl Pool {
    pub fn base(&self) -> &str {
        &self.target.base
    }

    pub async fn ready(&self, execution: &ExecutionService) -> bool {
        execution
            .pool_readiness_credentials()
            .await
            .is_ok_and(|records| records.iter().any(|record| self.check_credential(record)))
    }

    fn check_credential(&self, record: &AccountCredentialRecord) -> bool {
        let Ok(context) = AccountCredentialContext::new(
            record.id(),
            record.namespace(),
            record.credential_version(),
        ) else {
            return false;
        };
        self.cipher
            .open(record.sealed_credential(), &context)
            .is_ok_and(|credential| {
                self.target
                    .provider
                    .verified_headers(record.namespace(), &credential)
                    .is_some()
                    || (credential.expires_at_unix_seconds() <= crate::unix_time()
                        && self
                            .target
                            .provider
                            .verifies_identity(record.namespace(), &credential))
            })
    }

    #[allow(dead_code)] // Images uses the same admission path without HTTP Responses hints.
    pub async fn admit(
        &self,
        execution: &ExecutionService,
        request: ManagedAdmissionRequest,
        deadline: Instant,
    ) -> codexone_execution::Result<(Execution, HeaderMap)> {
        self.admit_with_affinity(execution, request, deadline, None)
            .await
    }

    pub async fn admit_with_affinity(
        &self,
        execution: &ExecutionService,
        request: ManagedAdmissionRequest,
        deadline: Instant,
        affinity: Option<Affinity<'_>>,
    ) -> codexone_execution::Result<(Execution, HeaderMap)> {
        let key_id = request.key.id();
        let labels = affinity
            .as_ref()
            .map(|affinity| session_labels(affinity.headers))
            .unwrap_or_default();
        let required = affinity
            .as_ref()
            .and_then(|affinity| affinity.turn_state)
            .map(|token| self.turn_states.owner(key_id, token, Monotonic::now()))
            .transpose()?;
        let operation = async {
            let preferred = if let Some(affinity) = &affinity
                && !affinity.hints.is_empty()
            {
                execution.pool_hint(&request.key, affinity.hints).await?
            } else {
                None
            };
            let routing = PoolRouting {
                required,
                preferred: preferred
                    .or_else(|| self.sessions.preferred(key_id, &labels, Monotonic::now())),
                ..Default::default()
            };
            let result = execution
                .admit_pool(request.clone(), || async {
                    self.prepare(execution, &request, &routing).await
                })
                .await?;
            let owner = &result.0.admission().owner;
            self.sessions.observe(
                key_id,
                &labels,
                &AccountIdentity {
                    id: owner.identity.clone(),
                    namespace: owner.namespace.clone(),
                },
                Monotonic::now(),
            );
            Ok(result)
        };
        timeout_at(deadline, operation)
            .await
            .map_err(|_| ExecutionError::DeadlineExceeded)?
    }

    async fn prepare(
        &self,
        execution: &ExecutionService,
        request: &ManagedAdmissionRequest,
        routing: &PoolRouting,
    ) -> codexone_execution::Result<PreparedPool<HeaderMap>> {
        let records = execution.pool_credentials(request, routing).await?;
        let mut prepared = stream::iter(records)
            .map(|candidate| async move {
                let identity = candidate.record.identity();
                match self
                    .runtime
                    .prepare_dispatch(&identity.id, candidate.continuation)
                    .await
                {
                    Ok(credential) if identity.namespace == credential.account.namespace => {
                        Ok(Some((
                            AccountDispatch::from_snapshot(
                                identity,
                                AccountDispatchSnapshot {
                                    revision: credential.account.revision,
                                    credential_version: credential.account.credential_version,
                                    access_expires_at_unix_seconds: credential
                                        .expires_at_unix_seconds,
                                    continuation: candidate.continuation,
                                },
                            ),
                            credential.headers,
                        )))
                    }
                    Ok(_)
                    | Err(
                        governance::Error::UnknownAccount
                        | governance::Error::AuthorizationUnavailable
                        | governance::Error::AuthorizationRequired
                        | governance::Error::AccountConflict
                        | governance::Error::Conflict
                        | governance::Error::IdentityMismatch,
                    ) => Ok(None),
                    Err(governance::Error::Capacity) => Err(ExecutionError::Capacity),
                    Err(governance::Error::StoragePressure) => Err(ExecutionError::StoragePressure),
                    Err(_) => Err(ExecutionError::StorageUnavailable),
                }
            })
            .buffer_unordered(4);
        let mut candidates = Vec::new();
        while let Some(candidate) = prepared.next().await {
            candidates.extend(candidate?);
        }
        Ok(PreparedPool {
            routing: routing.clone(),
            candidates,
        })
    }

    pub fn observe_turn_state(&self, key: &str, owner: &AccountIdentity, response: &HeaderMap) {
        let filtered = headers::provider(response, false);
        if let Some(token) = filtered
            .get("x-codex-turn-state")
            .and_then(|value| value.to_str().ok())
        {
            self.turn_states
                .observe(key, token, owner, Monotonic::now());
        }
    }
}

fn session_labels(headers: &HeaderMap) -> Vec<(SessionLabel, &str)> {
    use SessionLabel::*;
    [
        ThreadId,
        SessionId,
        SessionIdUnderscore,
        XSessionId,
        ConversationIdUnderscore,
        XConversationId,
    ]
    .into_iter()
    .filter_map(|label| {
        headers
            .get(label.name())?
            .to_str()
            .ok()
            .map(|value| (label, value))
    })
    .collect()
}

pub fn health_models(config: &ResponsesConfiguration) -> Vec<String> {
    config
        .models
        .iter()
        .map(|model| model.id.clone())
        .chain(
            config
                .image_generation
                .iter()
                .flat_map(|images| &images.models)
                .map(|model| model.id.clone()),
        )
        .collect()
}
