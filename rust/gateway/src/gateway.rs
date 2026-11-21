use std::{fs::DirBuilder, os::unix::fs::DirBuilderExt, path::Path, sync::Arc, time::Duration};

use bytes::Bytes;
use codexone_admin::{AdminRouter, ReadinessReport};
use codexone_config::{Configuration, SingleIdentity, Source, UpstreamTransport};
use codexone_execution::{
    ExecutionService, ExecutionStatus, Options, StaticIdentity, StaticIdentityConfig,
};
use codexone_http_upstream::Proxy;
use codexone_storage::Database;
use http::{Method, Request, Response, StatusCode, header};
use hyper::body::Incoming;
use rusqlite::{Connection, OpenFlags};
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
}

impl Application {
    fn readiness(&self) -> ReadinessReport {
        let mut report = ReadinessReport::unconfigured();
        let available = self
            .execution
            .as_ref()
            .is_some_and(|execution| execution.status() == ExecutionStatus::Accepting);
        report.checks[0].ready = available;
        report.checks[1].ready = self.data.is_some();
        report.checks[2].ready = self.data.is_some() && available;
        report
    }

    pub async fn admin(&self, request: &Request<Bytes>) -> Response<Bytes> {
        self.admin
            .route(request, async || self.readiness())
            .await
            .unwrap_or_else(codexone_admin::not_found)
    }

    pub async fn data(&self, request: Request<Incoming>, pending: FlushDeliveries) -> Reply {
        let path = request.uri().path();
        if request.method() == Method::GET && (path == "/health/live" || path == "/health/ready") {
            let (status, body) = if path == "/health/live" {
                (StatusCode::OK, json!({"status": "alive"}))
            } else {
                let report = self.readiness();
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

pub async fn run(mut config: Configuration) -> Result<(), StartupError> {
    use StartupError::*;
    let runtime = config.runtime;
    let mut terminate = signal(SignalKind::terminate()).map_err(|_| Service)?;
    let mut interrupt = signal(SignalKind::interrupt()).map_err(|_| Service)?;
    let proxy = config
        .upstream_proxy
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

    if runtime.backup_directory.is_some() || runtime.http_body_staging_directory.is_some() {
        return Err(UnsupportedSettings);
    }
    let (options, data) = match config.source.take() {
        None => (Options::new("storage-only"), None),
        Some(Source::SingleIdentity(identity))
            if !identity.managed_keys
                && identity.responses.upstream_transport == UpstreamTransport::Http =>
        {
            let token = identity.read_upstream_token().map_err(|_| Service)?;
            let token = token.as_ref().map(|token| token.as_str());
            let policy = identity_policy(&identity, token)?;
            let data = DataPlane::new(*identity, token, proxy).map_err(|_| Service)?;
            (Options::for_static_identity(policy), Some(data))
        }
        _ => return Err(UnsupportedConfiguration),
    };

    // Neither listener is announced until both sockets and startup recovery are ready.
    let data_listener = Listeners::bind("data", runtime.data_port, runtime.listen_address)
        .await
        .map_err(|_| Service)?;
    let admin_listener = Listeners::bind("admin", runtime.admin_port, runtime.listen_address)
        .await
        .map_err(|_| Service)?;
    let offset = (runtime.business_day_offset_minutes / 60) as i8;
    let (execution, inspection) = match runtime.data_directory {
        Some(directory) => {
            let static_identity = data.is_some();
            let path =
                tokio::task::spawn_blocking(move || initialize_store(&directory, static_identity))
                    .await
                    .map_err(|_| Service)??;
            let service =
                ExecutionService::open(&path, options.with_business_day_offset_hours(offset))
                    .await
                    .map_err(|_| Service)?;
            let inspection = tokio::task::spawn_blocking(move || open_inspection_reader(&path))
                .await
                .map_err(|_| Service)?
                .map_err(|_| Service)?;
            (Some(service), Some(inspection))
        }
        None => (None, None),
    };
    let data_connections = data.as_ref().map_or(128, DataPlane::max_connections);
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
    });
    let access: Arc<[_]> = runtime.allowed_networks.into();
    let stopping = CancellationToken::new();
    data_listener.announce();
    admin_listener.announce();
    let mut listeners = JoinSet::new();
    listeners.spawn_local(data_listener.serve(
        app.clone(),
        Plane::Data,
        access.clone(),
        stopping.clone(),
        data_connections,
    ));
    listeners.spawn_local(admin_listener.serve(
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
        _ = maintain(app.execution.as_ref()) => true,
    };

    if let Some(execution) = &app.execution {
        execution.stop_admission();
    }
    stopping.cancel();
    while let Some(result) = listeners.join_next().await {
        failed |= !matches!(result, Ok(Ok(())));
    }
    app.admin.revoke_sessions();
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
    drop(inspection);
    if failed { Err(Service) } else { Ok(()) }
}

fn initialize_store(
    directory: &Path,
    static_identity: bool,
) -> Result<std::path::PathBuf, StartupError> {
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
    drop(database);
    path.canonicalize().map_err(|_| Service)
}

// Keep a read-only connection through the writer's final checkpoint and close. An idle
// reader holds no transaction that pins WAL frames. Its presence retains SQLite's WAL
// and SHM files for offline read-only opening, including on macOS without a writable open.
fn open_inspection_reader(path: &Path) -> rusqlite::Result<Connection> {
    let reader = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    reader.query_row(
        "SELECT generation FROM maintenance_state WHERE id=1",
        [],
        |_| Ok(()),
    )?;
    Ok(reader)
}

async fn maintain(execution: Option<&ExecutionService>) {
    let Some(execution) = execution else {
        return std::future::pending().await;
    };
    let mut watch = time::interval(Duration::from_millis(50));
    watch.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut storage = time::interval_at(
        time::Instant::now() + Duration::from_secs(30),
        Duration::from_secs(30),
    );
    storage.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = watch.tick() => if execution.status() == ExecutionStatus::Failed { return; },
            _ = storage.tick() => {
                let _ = execution.maintain_storage().await;
                let _ = execution.expire_unknown().await;
            }
        }
    }
}

fn identity_policy(
    identity: &SingleIdentity,
    token: Option<&str>,
) -> Result<StaticIdentity, StartupError> {
    use StartupError::Service;
    let config = &identity.responses;
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
        "requestContract": match identity.upstream_contract {
            codexone_config::UpstreamContract::Responses => "responses",
            codexone_config::UpstreamContract::CodexSubscription => "codex-subscription",
        },
    });
    StaticIdentity::new(
        StaticIdentityConfig {
            principal: identity.principal.clone().ok_or(Service)?,
            key_id: identity.key_id.clone().ok_or(Service)?,
            key_sha256: identity.key_sha256.ok_or(Service)?,
            namespace: identity.namespace.clone(),
            identity: identity.identity.clone(),
            upstream_base_url: identity.upstream_base_url.clone(),
            models: models.iter().map(|model| model.id.clone()).collect(),
            vision_input: models.iter().any(|model| model.vision_input == Some(true)),
            image_models: images.iter().map(|model| model.id.clone()).collect(),
            policy_version: format!("{:x}", Sha256::digest(policy.to_string())),
            pricing_version: format!("{:x}", pricing.finalize()),
            reserved_micros: config.reserved_micros,
        },
        token,
    )
    .map_err(|_| Service)
}
