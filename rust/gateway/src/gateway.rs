use std::{fs::DirBuilder, os::unix::fs::DirBuilderExt, path::Path, sync::Arc, time::Duration};

use bytes::Bytes;
use codexone_admin::{AdminRouter, ReadinessReport};
use codexone_config::{
    Configuration, ResponsesConfiguration, SingleIdentity, Source, UpstreamContract,
    UpstreamTransport,
};
use codexone_execution::{
    ExecutionService, ExecutionStatus, FixedIdentity, Options, StaticIdentity, StaticIdentityConfig,
};
use codexone_governance::KeyOptions;
use codexone_http_upstream::Proxy;
use codexone_maintenance::online::OnlineBackup;
use codexone_storage::{AccountCredentialCipher, Database};
use http::{Method, Request, Response, StatusCode, header};
use hyper::body::Incoming;
use rusqlite::ffi;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::{
    signal::unix::{SignalKind, signal},
    task::JoinSet,
    time::{self, MissedTickBehavior},
};
use tokio_util::sync::CancellationToken;

use crate::{
    data::{self, DataPlane},
    listener::{Listeners, Plane, ReadError, read_body},
    managed::{self, Managed, Pool, SubscriptionTarget},
    online_backup::BackupTask,
    reply::{self, FlushDeliveries, Reply},
};

pub enum StartupError {
    UnsupportedConfiguration,
    UnsupportedSettings,
    RequiresManagedKeys,
    Service,
}

pub struct Application {
    admin: AdminRouter,
    data: Option<DataPlane>,
    execution: Option<ExecutionService>,
    managed: Option<Managed>,
    pool: Option<Arc<Pool>>,
}

impl Application {
    async fn readiness(&self) -> ReadinessReport {
        let mut report = ReadinessReport::unconfigured();
        report.checks[1].ready = self.data.is_some();
        if let Some(execution) = &self.execution {
            report.checks[0].ready = execution.admission_ready().await;
            if let Some(pool) = &self.pool {
                report.checks[1].ready = pool.ready(execution).await;
            }
            report.checks[2].ready =
                self.data.is_some() && execution.status() == ExecutionStatus::Accepting;
        }
        report
    }

    pub async fn admin(&self, request: &Request<Bytes>) -> Response<Bytes> {
        if let Some(response) = self
            .admin
            .route(request, async || self.readiness().await)
            .await
        {
            return response;
        }
        if let Some(managed) = &self.managed
            && let Some(response) = managed.route(&self.admin, request).await
        {
            return response;
        }
        codexone_admin::not_found()
    }

    pub async fn data(&self, request: Request<Incoming>, pending: FlushDeliveries) -> Reply {
        let path = request.uri().path();
        if request.method() == Method::GET && (path == "/health/live" || path == "/health/ready") {
            let (status, body) = if path == "/health/live" {
                (StatusCode::OK, json!({"status": "alive"}))
            } else {
                let report = self.readiness().await;
                let ready = report.is_ready();
                let status = if ready {
                    StatusCode::OK
                } else {
                    StatusCode::SERVICE_UNAVAILABLE
                };
                (
                    status,
                    json!({"service": "codexone", "transportMode": "loopback", "ready": ready, "checks": report.checks}),
                )
            };
            return reply::from_bytes(
                Response::builder()
                    .status(status)
                    .header(header::CONTENT_TYPE, "application/json; charset=utf-8")
                    .body(Bytes::from(body.to_string()))
                    .expect("health response"),
            );
        }
        if let (Some(data), Some(execution)) = (&self.data, &self.execution) {
            data.handle(request, execution, pending).await
        } else {
            let (parts, body) = request.into_parts();
            match read_body(body, 4096, time::Instant::now() + Duration::from_secs(10)).await {
                Ok(_) => data::unconfigured(&parts.method, parts.uri.path()),
                Err(ReadError::TooLarge) => reply::from_bytes(codexone_admin::request_too_large()),
                Err(_) => reply::from_bytes(
                    Response::builder()
                        .status(408)
                        .body(Bytes::new())
                        .expect("unconfigured timeout"),
                ),
            }
        }
    }
}

pub async fn run(config: Configuration) -> Result<(), StartupError> {
    run_configured(config, None, BackupTask::start).await
}

#[cfg(test)]
pub(crate) async fn run_with_target(
    config: Configuration,
    subscription: Option<SubscriptionTarget>,
) -> Result<(), StartupError> {
    run_configured(config, subscription, BackupTask::start).await
}

#[cfg(test)]
pub(crate) async fn run_with_backup(
    config: Configuration,
    start_backup: impl FnOnce(OnlineBackup, ExecutionService) -> BackupTask,
) -> Result<(), StartupError> {
    run_configured(config, None, start_backup).await
}

async fn run_configured(
    mut config: Configuration,
    subscription: Option<SubscriptionTarget>,
    start_backup: impl FnOnce(OnlineBackup, ExecutionService) -> BackupTask,
) -> Result<(), StartupError> {
    use StartupError::*;
    let mut terminate = signal(SignalKind::terminate()).map_err(|_| Service)?;
    let mut interrupt = signal(SignalKind::interrupt()).map_err(|_| Service)?;
    let proxy = config
        .upstream_proxy
        .take()
        .map(|proxy| {
            let authority = if proxy.host.contains(':') {
                format!("[{}]:{}", proxy.host, proxy.port)
            } else {
                format!("{}:{}", proxy.host, proxy.port)
            };
            Proxy::parse(&format!("http://{authority}"))
        })
        .transpose()
        .map_err(|_| Service)?;

    let key_options = KeyOptions::configured(&config);
    let runtime = config.runtime;
    if runtime.http_body_staging_directory.is_some() {
        return Err(UnsupportedSettings);
    }
    let static_identity =
        matches!(&config.source, Some(Source::SingleIdentity(identity)) if !identity.managed_keys);
    let (mut options, mut data, pool_config) = match config.source.take() {
        None => (Options::new("storage-only"), None, None),
        Some(Source::SingleIdentity(identity))
            if identity.responses.upstream_transport == UpstreamTransport::Http =>
        {
            let token = identity.read_upstream_token().map_err(|_| Service)?;
            let token = token.as_ref().map(|token| token.as_str());
            let (options, versions) = if identity.managed_keys {
                let fixed = FixedIdentity::new(
                    &identity.namespace,
                    identity.identity.clone(),
                    &identity.upstream_base_url,
                    token,
                )
                .map_err(|_| Service)?;
                (
                    Options::for_fixed_identity_with_managed_keys(fixed),
                    Some(identity_versions(
                        &identity.responses,
                        identity.upstream_contract,
                    )?),
                )
            } else {
                (
                    Options::for_static_identity(identity_policy(&identity, token)?),
                    None,
                )
            };
            let data =
                DataPlane::new(*identity, token, proxy.clone(), versions).map_err(|_| Service)?;
            (options, Some(data), None)
        }
        Some(Source::AccountPool(pool)) if pool.upstream_transport == UpstreamTransport::Http => {
            (Options::for_account_pool(), None, Some(pool))
        }
        _ => return Err(UnsupportedConfiguration),
    };
    if config.master_keys.is_some() {
        options = options.with_governance_recovery(managed::recover);
    }

    // Neither listener is announced until both sockets and startup recovery are ready.
    let data_listener = Listeners::bind("data", runtime.data_port, runtime.listen_address)
        .await
        .map_err(|_| Service)?;
    let admin_listener = Listeners::bind("admin", runtime.admin_port, runtime.listen_address)
        .await
        .map_err(|_| Service)?;
    let offset = (runtime.business_day_offset_minutes / 60) as i8;
    let (execution, backup) = match runtime.data_directory {
        Some(directory) => {
            let database =
                tokio::task::spawn_blocking(move || initialize_store(&directory, static_identity))
                    .await
                    .map_err(|_| Service)??;
            let backup = runtime
                .backup_directory
                .map(|root| (root, database.backup_source()));
            let service = ExecutionService::open_database(
                database,
                options.with_business_day_offset_hours(offset),
            )
            .await
            .map_err(|_| Service)?;
            let backup = if let Some((root, source)) = backup {
                let protection = config
                    .master_keys
                    .as_ref()
                    .map(|keys| {
                        let old: Vec<&[u8; 32]> =
                            keys.decrypt_only.iter().map(|key| &**key).collect();
                        AccountCredentialCipher::from_key_bytes(&keys.active, &old).map(Arc::new)
                    })
                    .transpose()
                    .map_err(|_| Service)?;
                let worker = tokio::task::spawn_blocking(move || {
                    OnlineBackup::new(root, source, protection)
                })
                .await
                .map_err(|_| Service)?;
                Some(start_backup(worker, service.clone()))
            } else {
                None
            };
            (Some(service), backup)
        }
        None => (None, None),
    };
    let (mut managed, pool) = if let Some(execution) = &execution
        && config.admin_digest.is_some()
    {
        let (managed, pool) = Managed::new(
            execution.clone(),
            config.master_keys,
            subscription.unwrap_or_else(|| SubscriptionTarget::production(proxy.clone())),
            key_options,
            pool_config.as_deref(),
            proxy.clone(),
        )
        .map_err(|_| Service)?;
        (Some(managed), pool)
    } else {
        (None, None)
    };
    let pool = if let Some(pool_config) = pool_config {
        let execution = execution.as_ref().ok_or(Service)?;
        let pool = pool.ok_or(Service)?;
        execution
            .configure_health_models(managed::health_models(&pool_config))
            .await
            .map_err(|_| Service)?;
        let versions = identity_versions(&pool_config, UpstreamContract::CodexSubscription)?;
        data = Some(
            DataPlane::new_pool(*pool_config, pool.clone(), versions, proxy)
                .map_err(|_| Service)?,
        );
        Some(pool)
    } else {
        None
    };
    let data_connections = data.as_ref().map_or(128, DataPlane::max_connections);
    let mut managed_tasks = JoinSet::new();
    if let Some(managed) = &mut managed {
        managed.spawn_workers(&mut managed_tasks);
    }
    let app = Arc::new(Application {
        admin: AdminRouter::new(
            admin_listener.port,
            runtime.listen_address,
            config.admin_digest,
            config.admin_origin.as_deref(),
            config.web_bundle.take(),
        ),
        data,
        execution,
        managed,
        pool,
    });
    let access: Arc<[_]> = runtime.allowed_networks.into();
    let stopping = CancellationToken::new();
    data_listener.announce();
    admin_listener.announce();
    let mut listeners = JoinSet::new();
    listeners.spawn(data_listener.serve(
        app.clone(),
        Plane::Data,
        access.clone(),
        stopping.clone(),
        data_connections,
    ));
    listeners.spawn(admin_listener.serve(
        app.clone(),
        Plane::Admin,
        access,
        stopping.clone(),
        codexone_admin::MAX_CONNECTIONS,
    ));
    let mut failed = tokio::select! {
        _ = terminate.recv() => false,
        _ = interrupt.recv() => false,
        _ = listeners.join_next() => true,
        _ = supervise_execution(app.execution.as_ref()) => true,
        _ = managed_tasks.join_next(), if !managed_tasks.is_empty() => true,
    };

    if let Some(backup) = &backup {
        backup.cancel();
    }
    if let Some(execution) = &app.execution {
        execution.stop_admission();
    }
    if let Some(managed) = &app.managed {
        managed.stop_quota();
    }
    stopping.cancel();
    while let Some(result) = listeners.join_next().await {
        failed |= !matches!(result, Ok(Ok(())));
    }
    app.admin.revoke_sessions();
    if let Some(backup) = backup {
        backup.join().await;
    }
    if let Some(managed) = &app.managed {
        if time::timeout(Duration::from_secs(3), managed.shutdown())
            .await
            .is_ok()
        {
            while let Some(result) = managed_tasks.join_next().await {
                failed |= !matches!(result, Ok(Ok(())));
            }
        } else {
            managed_tasks.abort_all();
            failed = true;
        }
    }
    if let Some(execution) = &app.execution {
        let drained = match time::timeout(Duration::from_secs(3), async {
            let checkpoint = execution.maintain_storage().await;
            let stopped = execution.shutdown().await;
            checkpoint.and(stopped)
        })
        .await
        {
            Ok(result) => result.is_ok(),
            Err(_) => {
                let _ = time::timeout(Duration::from_secs(1), execution.force_shutdown()).await;
                false
            }
        };
        failed |= !drained;
    }
    if failed { Err(Service) } else { Ok(()) }
}

fn initialize_store(directory: &Path, static_identity: bool) -> Result<Database, StartupError> {
    use StartupError::*;
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(directory)
        .map_err(|_| Service)?;
    let path = directory.join("core.sqlite");
    let database = Database::open_or_create(&path).map_err(|_| Service)?;
    if static_identity {
        let restored: bool = database
            .connection()
            .query_row(
                "SELECT restore_json IS NOT NULL FROM maintenance_state WHERE id=1",
                [],
                |row| row.get(0),
            )
            .map_err(|_| Service)?;
        if restored {
            return Err(RequiresManagedKeys);
        }
    }
    // Keep the WAL and SHM files available to offline read-only clients. The writer can
    // checkpoint and close under the instance lock without a second SQLite connection.
    let mut persist: std::ffi::c_int = 1;
    // SAFETY: The connection is open and unshared. This SQLite opcode takes a pointer
    // to a C int and does not retain it.
    let result = unsafe {
        ffi::sqlite3_file_control(
            database.connection().handle(),
            c"main".as_ptr(),
            ffi::SQLITE_FCNTL_PERSIST_WAL,
            std::ptr::from_mut(&mut persist).cast(),
        )
    };
    if result != ffi::SQLITE_OK {
        return Err(Service);
    }
    Ok(database)
}

async fn supervise_execution(execution: Option<&ExecutionService>) {
    let Some(execution) = execution else {
        return std::future::pending().await;
    };
    let mut storage = time::interval_at(
        time::Instant::now() + Duration::from_secs(30),
        Duration::from_secs(30),
    );
    storage.set_missed_tick_behavior(MissedTickBehavior::Skip);
    tokio::select! {
        _ = execution.wait_until_failed() => {}
        _ = async {
            loop {
                storage.tick().await;
                let _ = execution.maintain_storage().await;
                let _ = execution.expire_unknown().await;
            }
        } => {}
    }
}

fn identity_policy(
    identity: &SingleIdentity,
    token: Option<&str>,
) -> Result<StaticIdentity, StartupError> {
    use StartupError::Service;
    let config = &identity.responses;
    let (policy_version, pricing_version) = identity_versions(config, identity.upstream_contract)?;
    StaticIdentity::new(
        StaticIdentityConfig {
            principal: identity.principal.clone().ok_or(Service)?,
            key_id: identity.key_id.clone().ok_or(Service)?,
            key_sha256: identity.key_sha256.ok_or(Service)?,
            namespace: identity.namespace.clone(),
            identity: identity.identity.clone(),
            upstream_base_url: identity.upstream_base_url.clone(),
            models: config.models.iter().map(|model| model.id.clone()).collect(),
            vision_input: config
                .models
                .iter()
                .any(|model| model.vision_input == Some(true)),
            image_models: config
                .image_generation
                .iter()
                .flat_map(|images| &images.models)
                .map(|model| model.id.clone())
                .collect(),
            policy_version,
            pricing_version,
            reserved_micros: config.reserved_micros,
        },
        token,
    )
    .map_err(|_| Service)
}

pub(crate) fn identity_versions(
    config: &ResponsesConfiguration,
    contract: UpstreamContract,
) -> Result<(String, String), StartupError> {
    use StartupError::Service;
    let mut models: Vec<_> = config.models.iter().collect();
    models.sort_by_key(|model| &model.id);
    let images: Vec<_> = config
        .image_generation
        .iter()
        .flat_map(|images| &images.models)
        .collect();
    let prices: Vec<_> = models
        .iter()
        .map(|model| {
            json!({
                "id": model.id,
                "inputMicrosPerMillion": model.input_micros_per_million,
                "outputMicrosPerMillion": model.output_micros_per_million,
            })
        })
        .collect();
    let image_prices: Vec<_> = images
        .iter()
        .map(|model| {
            json!({
                "id": model.id,
                "hostModel": model.host_model,
                "inputMicrosPerMillion": model.input_micros_per_million,
                "outputMicrosPerMillion": model.output_micros_per_million,
            })
        })
        .collect();
    let mut pricing = Sha256::new();
    pricing.update(
        serde_json::to_string(&prices)
            .map_err(|_| Service)?
            .replace('/', "\\/"),
    );
    if image_prices.is_empty() {
        pricing.update(b"null");
    } else {
        pricing.update(serde_json::to_vec(&image_prices).map_err(|_| Service)?);
    }
    let model_policies: Vec<_> = models
        .iter()
        .map(|model| {
            json!({
                "id": model.id, "vision": model.vision_input == Some(true),
                "images": model.image_generation == Some(true),
            })
        })
        .collect();
    let policy = json!({
        "protocolVersion": "rust-http-1",
        "models": model_policies,
        "images": image_prices,
        "reservation": config.reserved_micros,
        "executionTimeoutSeconds": config.budget.total_seconds,
        "firstResponseTimeoutSeconds": config.budget.first_response_seconds,
        "imageFirstResponseTimeoutSeconds": config.budget.image_first_response_seconds,
        "progressTimeoutSeconds": config.budget.progress_seconds,
        "requestContract": match contract {
            UpstreamContract::Responses => "responses",
            UpstreamContract::CodexSubscription => "codex-subscription",
        },
    });
    Ok((
        format!("{:x}", Sha256::digest(policy.to_string())),
        format!("{:x}", pricing.finalize()),
    ))
}
