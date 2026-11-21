use std::{
    collections::BTreeMap,
    path::Path,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use bytes::Bytes;
use codexone_execution::{
    ExecutionService, STORAGE_STOP_BYTES, STORAGE_WAL_STOP_BYTES, StorageObservation,
    StoragePressure,
};
use codexone_maintenance::online::BackupStatus;
pub(crate) use codexone_usage::DataClients;
use codexone_usage::{BusinessDay, Context, ProtocolExtensions, Reader, Usage};
use http::{Method, Request, Response, header};
use serde_json::{Value, json};

pub struct ManagementUsage {
    reader: Reader,
    pub usage: Usage,
    execution: ExecutionService,
    defaults: Box<dyn Fn() -> BTreeMap<String, String> + Send + Sync>,
    output_horizon: Option<i64>,
    protocol_extensions: Box<dyn Fn() -> ProtocolExtensions + Send + Sync>,
    backup: Option<BackupStatus>,
    pub(crate) clients: Arc<DataClients>,
}

impl ManagementUsage {
    pub async fn open(
        path: &Path,
        offset_minutes: i16,
        execution: ExecutionService,
        defaults: BTreeMap<String, String>,
    ) -> codexone_usage::Result<Self> {
        let day = BusinessDay::new(offset_minutes.into())?;
        let path = path.to_owned();
        let monitor = execution.clone();
        let reader = tokio::task::spawn_blocking(move || {
            // The progress callback polls frequently. Reuse the writer's monitor
            // and bound its filesystem sampling frequency for this single reader.
            let last_check = Mutex::new(None::<(Instant, bool)>);
            Reader::open(&path, Duration::from_secs(1), move || {
                let Ok(mut cached) = last_check.lock() else {
                    return false;
                };
                if let Some((at, allowed)) = *cached
                    && at.elapsed() < Duration::from_millis(25)
                {
                    return allowed;
                }
                let allowed = monitor.storage_pressure() == StoragePressure::Normal;
                *cached = Some((Instant::now(), allowed));
                allowed
            })
        })
        .await
        .map_err(|_| codexone_usage::Error::Unavailable)??;
        let observed = unix_now();
        let output_horizon = reader
            .read(|db| {
                Ok(db.query_row(
                    "SELECT COALESCE(MAX(output_rate_settled_at),-1) FROM attempts WHERE output_rate_settled_at IS NOT NULL",
                    [],
                    |row| row.get::<_, i64>(0),
                )?)
            })
            .await
            .ok()
            .map(|persisted| persisted.max(observed));
        let mut management = Self {
            usage: Usage::new(reader.clone(), day),
            reader,
            execution,
            defaults: Box::new(BTreeMap::new),
            output_horizon,
            protocol_extensions: Box::new(ProtocolExtensions::default),
            backup: None,
            clients: Arc::new(DataClients::default()),
        };
        management.attach_model_efforts(move || defaults.clone());
        management.attach_protocol_extensions(ProtocolExtensions::default);
        Ok(management)
    }

    pub fn attach_model_efforts(
        &mut self,
        current: impl Fn() -> BTreeMap<String, String> + Send + Sync + 'static,
    ) {
        self.defaults = Box::new(current);
    }

    pub fn attach_protocol_extensions(
        &mut self,
        current: impl Fn() -> ProtocolExtensions + Send + Sync + 'static,
    ) {
        self.protocol_extensions = Box::new(current);
    }

    pub fn attach_backup(&mut self, backup: BackupStatus) {
        self.backup = Some(backup);
    }

    pub fn matches(method: &Method, path: &str) -> bool {
        Usage::matches(method, path) || (method == Method::GET && path == "/api/runtime/storage")
    }

    pub async fn route(&self, request: &Request<Bytes>) -> Response<Bytes> {
        let path = request.uri().path().trim_end_matches('/');
        let now = unix_now();
        if path == "/api/runtime/storage" {
            return Response::builder()
                .header(header::CONTENT_TYPE, "application/json")
                .body(Bytes::from(self.storage(now).await.to_string()))
                .expect("static response headers");
        }
        let storage = if matches!(path, "/api/usage/headroom" | "/api/attention")
            && request.uri().query().is_none()
        {
            self.storage(now).await
        } else {
            Value::Null
        };
        let context = match path {
            "/api/usage/options" => Context {
                default_reasoning_efforts: (self.defaults)(),
                ..self.context(storage)
            },
            "/api/attention" => self.attention_context(storage),
            _ => self.context(storage),
        };
        self.usage
            .route(request, now, Arc::new(context))
            .await
            .unwrap_or_else(codexone_admin::not_found)
    }

    pub async fn storage(&self, now: i64) -> Value {
        let execution = self.execution.clone();
        let observation = tokio::task::spawn_blocking(move || execution.storage_observation())
            .await
            .unwrap_or_else(|_| StorageObservation::unavailable());
        let pressure = match observation.pressure {
            StoragePressure::Normal => "normal",
            StoragePressure::Degraded => "degraded",
            StoragePressure::Blocked => "blocked",
            StoragePressure::Unknown => "unknown",
        };
        let mut value = json!({
            "coreAvailable": observation.core_available,
            "pressure": pressure,
            "admissionAllowed": matches!(observation.pressure, StoragePressure::Normal | StoragePressure::Degraded),
            "optionalWorkAllowed": observation.pressure == StoragePressure::Normal,
            "reserveTargetBytes": observation.reserve_target_bytes,
            "usageReaderActive": self.reader.is_active(),
        });
        if observation.core_available {
            value["sampledUnixSeconds"] = json!(now);
        }
        for (field, amount) in [
            ("availableBytes", observation.available_bytes),
            ("volumeTotalBytes", observation.volume_total_bytes),
            ("databaseBytes", observation.database_bytes),
            ("walBytes", observation.wal_bytes),
            ("reserveBytes", observation.reserve_bytes),
        ] {
            if let Some(amount) = amount {
                value[field] = json!(amount);
            }
        }
        value["backup"] = json!(
            self.backup
                .as_ref()
                .map(BackupStatus::observation)
                .unwrap_or_default()
        );
        value
    }

    pub async fn wait_idle(&self) {
        self.reader.wait_idle().await;
    }

    pub fn activity_context(&self, storage: Value) -> Context {
        Context {
            clients: self.clients.snapshot(),
            ..self.context(storage)
        }
    }

    pub fn attention_context(&self, storage: Value) -> Context {
        Context {
            protocol_extensions: (self.protocol_extensions)(),
            ..self.context(storage)
        }
    }

    fn context(&self, storage: Value) -> Context {
        Context {
            first_events: self.execution.first_events(),
            live_output_after: self.output_horizon,
            daily_requests: Some(10_000),
            daily_budget_micros: Some(1_000_000_000),
            storage,
            stop_available_bytes: STORAGE_STOP_BYTES as i64,
            stop_wal_bytes: STORAGE_WAL_STOP_BYTES as i64,
            ..Context::default()
        }
    }
}

pub fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}
