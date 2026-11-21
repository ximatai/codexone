use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
};

use bytes::Bytes;
use codexone_admin::AdminRouter;
use codexone_config::{
    ClientFingerprint, ImageConfiguration, Model, ModelReasoningSettings, ResponsesConfiguration,
    valid_models,
};
use codexone_governance::{self as governance, Error, KeyOptions, Result, Work, Writer};
use codexone_identity_runtime::IdentityRuntime;
use codexone_wire::JsonValue;
use http::{Method, Request, Response, StatusCode, header};
use rusqlite::{OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use tokio::sync::Semaphore;
use uuid::Uuid;

use crate::managed::GovernanceWriter;

const DIRECTORY_BYTES: usize = 4 * 1024 * 1024;
const DISCOVERY_TTL: i64 = 900;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub revision: i64,
    pub active: Vec<Model>,
    retired: Vec<Model>,
    #[serde(default)]
    account_for_model: HashMap<String, String>,
}

impl Snapshot {
    pub fn model_owner(&self, model: &str) -> Option<&str> {
        self.account_for_model.get(model).map(String::as_str)
    }

    fn validate(&self, images: Option<&ImageConfiguration>) -> Result<()> {
        if !valid_models(&self.active)
            || (!self.retired.is_empty() && !valid_models(&self.retired))
            || images.is_some_and(|images| !images.is_valid(&self.active))
        {
            return Err(Error::InvalidCommand);
        }
        if self.active.len() + self.retired.len() > 32 {
            return Err(Error::Capacity);
        }
        Ok(())
    }
}

struct Discovery {
    account: String,
    account_revision: i64,
    revision: String,
    fetched_at: i64,
    entries: Vec<Value>,
}

impl Discovery {
    fn fresh(&self, now: i64) -> bool {
        now - self.fetched_at < DISCOVERY_TTL
    }

    fn entry(&self, id: &str) -> Option<&Value> {
        self.entries
            .iter()
            .find(|entry| entry["slug"].as_str() == Some(id))
    }
}

struct State {
    snapshot: Arc<Snapshot>,
    discovery: Option<Discovery>,
}

pub struct Directory {
    writer: GovernanceWriter,
    runtime: IdentityRuntime<GovernanceWriter>,
    state: Arc<Mutex<State>>,
    images: Option<ImageConfiguration>,
    fingerprint: ClientFingerprint,
    refreshing: Semaphore,
}

impl Directory {
    pub async fn open(
        writer: GovernanceWriter,
        runtime: IdentityRuntime<GovernanceWriter>,
        config: &ResponsesConfiguration,
    ) -> Result<Self> {
        let stored = writer.run(Work::Read, |db, _, _| {
            let row = db.connection().query_row(
                "SELECT revision, CASE WHEN length(CAST(document AS BLOB))<=?1 THEN document END
                 FROM model_directory WHERE singleton=1",
                [DIRECTORY_BYTES as i64], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?)),
            ).optional()?;
            row.map(|(revision, raw)| {
                let raw = raw.ok_or(Error::Unavailable)?;
                let snapshot: Snapshot = serde_json::from_str(&raw).map_err(|_| Error::Unavailable)?;
                if revision < 1 || snapshot.revision != revision {
                    return Err(Error::Unavailable);
                }
                Ok(snapshot)
            }).transpose()
        }).await?;
        let snapshot = stored.unwrap_or_else(|| Snapshot {
            revision: 0,
            active: config.models.clone(),
            retired: Vec::new(),
            account_for_model: HashMap::new(),
        });
        snapshot
            .validate(config.image_generation.as_ref())
            .map_err(|_| Error::Unavailable)?;
        Ok(Self {
            writer,
            runtime,
            state: Arc::new(Mutex::new(State {
                snapshot: Arc::new(snapshot),
                discovery: None,
            })),
            images: config.image_generation.clone(),
            fingerprint: config.client_fingerprint.clone(),
            refreshing: Semaphore::new(1),
        })
    }

    pub fn snapshot(&self) -> Arc<Snapshot> {
        self.state.lock().unwrap().snapshot.clone()
    }

    pub fn options(&self) -> KeyOptions {
        let snapshot = self.snapshot();
        KeyOptions::for_models(
            &snapshot.active,
            self.image_models(),
            Some(snapshot.revision),
        )
    }

    pub fn health_models(&self) -> Vec<String> {
        let mut models = self.image_models();
        models.extend(self.snapshot().active.iter().map(|model| model.id.clone()));
        models
    }

    fn image_models(&self) -> Vec<String> {
        self.images
            .iter()
            .flat_map(|images| &images.models)
            .map(|model| model.id.clone())
            .collect()
    }

    pub async fn route(
        &self,
        admin: &AdminRouter,
        request: &Request<Bytes>,
    ) -> Option<Response<Bytes>> {
        let route = Endpoint::recognize(request)?;
        let authorization = match admin.authorize(request.method(), request.headers()) {
            Ok(authorization) => authorization,
            Err(response) => return Some(*response),
        };
        let result = async {
            if request.uri().query().is_some() {
                return Err(Error::InvalidCommand);
            }
            match route {
                Endpoint::Read => Ok(()),
                Endpoint::Refresh(id) => self.refresh(id).await,
                _ => {
                    let content_type = crate::headers::values(request.headers(), "content-type");
                    if !matches!(content_type.as_slice(), [value] if value.to_ascii_lowercase().starts_with("application/json"))
                        || request.headers().contains_key(header::CONTENT_ENCODING) {
                        return Err(Error::InvalidCommand);
                    }
                    let body = JsonValue::decode(request.body()).map_err(|_| Error::InvalidCommand)?;
                    let body = serde_json::from_slice::<Value>(&body.encode(false)).map_err(|_| Error::InvalidCommand)?;
                    let fields = body.as_object().ok_or(Error::InvalidCommand)?;
                    self.change(route, fields).await
                }
            }
        }.await;
        let mut response = match result {
            Ok(()) => governance::admin_response(StatusCode::OK, &self.document()),
            Err(Error::AuthorizationUnavailable) => governance::admin_failure(
                StatusCode::SERVICE_UNAVAILABLE,
                "observation_unavailable",
            ),
            Err(error) => governance::admin_error(error),
        };
        authorization.apply(&mut response);
        Some(response)
    }

    async fn refresh(&self, id: &str) -> Result<()> {
        let _permit = self.refreshing.try_acquire().map_err(|_| Error::Conflict)?;
        let fingerprint = &self.fingerprint;
        let version = fingerprint.version.as_deref().unwrap_or("0.169.1");
        let agent = format!(
            "codex_cli_rs/{version} ({}; {}) {}",
            fingerprint.os.as_deref().unwrap_or("Mac OS 26.5.0"),
            fingerprint.arch.as_deref().unwrap_or("arm64"),
            fingerprint
                .terminal
                .as_deref()
                .unwrap_or("iTerm.app/3.6.10"),
        );
        let (account_revision, payload) =
            self.runtime.model_candidates(id, version, &agent).await?;
        let entries = payload
            .get("models")
            .and_then(Value::as_array)
            .filter(|entries| entries.len() <= 128)
            .ok_or(Error::AuthorizationUnavailable)?;
        let mut seen = HashSet::new();
        if entries.iter().any(|entry| {
            !entry["slug"]
                .as_str()
                .is_some_and(|slug| valid_id(slug) && seen.insert(slug))
        }) {
            return Err(Error::AuthorizationUnavailable);
        }
        let entries = entries
            .iter()
            .filter(|entry| {
                entry
                    .get("visibility")
                    .is_none_or(|visibility| visibility == "list")
            })
            .cloned()
            .collect();
        self.state.lock().unwrap().discovery = Some(Discovery {
            account: id.into(),
            account_revision,
            revision: Uuid::new_v4().to_string().to_ascii_uppercase(),
            fetched_at: crate::unix_time(),
            entries,
        });
        Ok(())
    }

    fn document(&self) -> Value {
        let state = self.state.lock().unwrap();
        let snapshot = &state.snapshot;
        let discovery = state.discovery.as_ref();
        let active: Vec<_> = snapshot
            .active
            .iter()
            .map(|model| {
                let mut row = metadata(model, "enabled", None, false);
                row["inputMicrosPerMillion"] = json!(model.input_micros_per_million);
                row["outputMicrosPerMillion"] = json!(model.output_micros_per_million);
                if let Some(update) =
                    refreshed_profile(snapshot, model, discovery, crate::unix_time())
                {
                    row["profileUpdate"] = metadata(
                        &update,
                        "enabled",
                        Some(model.vision_input == Some(true)),
                        reasoning_reset(&update),
                    );
                }
                row
            })
            .collect();
        let retired: Vec<_> = snapshot
            .retired
            .iter()
            .map(|model| {
                if let Some(discovery) = discovery
                    && snapshot.account_for_model.get(&model.id) == Some(&discovery.account)
                    && let Some(entry) = discovery.entry(&model.id)
                {
                    let mut updated = from_candidate(
                        &model.id,
                        entry,
                        model.input_micros_per_million,
                        model.output_micros_per_million,
                    );
                    updated.reasoning_settings = model.reasoning_settings.clone();
                    let reset = reasoning_reset(&updated);
                    if reset {
                        updated.reasoning_settings = None;
                    }
                    metadata(
                        &updated,
                        "retired",
                        Some(model.vision_input == Some(true)),
                        reset,
                    )
                } else {
                    metadata(model, "retired", None, false)
                }
            })
            .collect();
        let known: HashSet<_> = snapshot
            .active
            .iter()
            .chain(&snapshot.retired)
            .map(|model| model.id.as_str())
            .collect();
        let candidates: Vec<_> = discovery
            .into_iter()
            .flat_map(|discovery| &discovery.entries)
            .filter_map(|entry| {
                let id = entry["slug"].as_str()?;
                if known.contains(id) {
                    return None;
                }
                let model = from_candidate(id, entry, 0, 0);
                let state = if valid_models(std::slice::from_ref(&model)) {
                    "candidate"
                } else {
                    "incomplete"
                };
                Some(metadata(&model, state, None, false))
            })
            .collect();
        json!({
            "revision": snapshot.revision, "active": active, "retired": retired, "candidates": candidates,
            "imageModels": self.image_models(), "account": discovery.map(|entry| &entry.account),
            "candidateRevision": discovery.map(|entry| &entry.revision), "fetchedAt": discovery.map(|entry| entry.fetched_at),
        })
    }

    async fn change(&self, route: Endpoint<'_>, body: &Map<String, Value>) -> Result<()> {
        let expected = body
            .get("revision")
            .and_then(Value::as_i64)
            .filter(|revision| (0..i64::MAX).contains(revision))
            .ok_or(Error::InvalidCommand)?;
        let id = body
            .get("model")
            .and_then(Value::as_str)
            .filter(|id| (1..=128).contains(&id.len()))
            .ok_or(Error::InvalidCommand)?;
        let (next, expected_account) = {
            let state = self.state.lock().unwrap();
            if state.snapshot.revision != expected {
                return Err(Error::Conflict);
            }
            let mut next = (*state.snapshot).clone();
            next.revision += 1;
            let index = next.active.iter().position(|model| model.id == id);
            let now = crate::unix_time();
            let discovery = state.discovery.as_ref();
            let mut account = None;
            match route {
                Endpoint::Change => {
                    account = change_enabled(&mut next, index, id, body, discovery, now)?
                }
                Endpoint::Rates => {
                    if !fields_only(
                        body,
                        &[
                            "revision",
                            "model",
                            "inputMicrosPerMillion",
                            "outputMicrosPerMillion",
                        ],
                    ) {
                        return Err(Error::InvalidCommand);
                    }
                    let model = &mut next.active[index.ok_or(Error::InvalidCommand)?];
                    let (input, output) = rates(body)?;
                    model.input_micros_per_million = input;
                    model.output_micros_per_million = output;
                }
                Endpoint::Reasoning => {
                    if !fields_only(
                        body,
                        &[
                            "revision",
                            "model",
                            "allowedReasoningEfforts",
                            "defaultReasoningEffort",
                        ],
                    ) {
                        return Err(Error::InvalidCommand);
                    }
                    let model = &mut next.active[index.ok_or(Error::InvalidCommand)?];
                    model.reasoning_settings = settings(body, model)?;
                }
                Endpoint::Profile => {
                    if body
                        .get("candidateRevision")
                        .and_then(Value::as_str)
                        .is_none()
                        || !fields_only(
                            body,
                            &[
                                "revision",
                                "model",
                                "candidateRevision",
                                "resetReasoningSettings",
                            ],
                        )
                    {
                        return Err(Error::InvalidCommand);
                    }
                    let reset = reset_requested(body)?;
                    let index = index.ok_or(Error::Conflict)?;
                    let discovery = matching_discovery(discovery, body, now)?;
                    let mut refreshed =
                        refreshed_profile(&next, &next.active[index], Some(discovery), now)
                            .ok_or(Error::Conflict)?;
                    if reset != reasoning_reset(&refreshed) {
                        return Err(Error::Conflict);
                    }
                    if reset {
                        refreshed.reasoning_settings = None;
                    }
                    next.active[index] = refreshed;
                    account = Some((discovery.account.clone(), discovery.account_revision));
                }
                _ => unreachable!("write route"),
            }
            next.validate(self.images.as_ref())?;
            (next, account)
        };
        let images = self.image_models();
        let state = self.state.clone();
        self.writer.run(Work::Optional, move |db, _, _| {
            let serialized = serde_json::to_string(&next).map_err(|_| Error::Unavailable)?;
            if serialized.len() > DIRECTORY_BYTES { return Err(Error::Capacity); }
            let tx = db.begin_immediate()?;
            let actual: i64 = tx.query_row(
                "SELECT coalesce((SELECT revision FROM model_directory WHERE singleton=1),0)", [], |row| row.get(0),
            )?;
            if expected != actual { return Err(Error::Conflict); }
            if let Some((id, revision)) = expected_account {
                let current: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND revision=?2 AND mode='enabled' AND authorization='ready')",
                    params![id, revision], |row| row.get(0),
                )?;
                if !current { return Err(Error::Conflict); }
            }
            store(&tx, &next, &serialized, &images)?;
            // The publication belongs to the accepted writer command. A cancelled admin
            // response cannot leave the running directory behind durable state.
            let mut current = state.lock().unwrap();
            tx.commit()?;
            current.snapshot = Arc::new(next);
            Ok(())
        }).await
    }
}

#[derive(Clone, Copy)]
enum Endpoint<'a> {
    Read,
    Change,
    Rates,
    Reasoning,
    Profile,
    Refresh(&'a str),
}

impl<'a> Endpoint<'a> {
    fn recognize(request: &'a Request<Bytes>) -> Option<Self> {
        Some(match (request.method(), request.uri().path()) {
            (&Method::GET, "/api/models") => Self::Read,
            (&Method::PUT, "/api/models") => Self::Change,
            (&Method::PUT, "/api/models/rates") => Self::Rates,
            (&Method::PUT, "/api/models/reasoning") => Self::Reasoning,
            (&Method::PUT, "/api/models/profile") => Self::Profile,
            (&Method::POST, path) => {
                let account = path
                    .strip_prefix("/api/accounts/")?
                    .strip_suffix("/model-candidates")?;
                if account.is_empty() || account.contains('/') {
                    return None;
                }
                Self::Refresh(account)
            }
            _ => return None,
        })
    }
}

fn store(tx: &Transaction<'_>, next: &Snapshot, document: &str, images: &[String]) -> Result<()> {
    tx.execute(
        "INSERT INTO model_directory(singleton,revision,document) VALUES(1,?,?)
         ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,document=excluded.document",
        params![next.revision, document],
    )?;
    let ids: HashSet<_> = next
        .active
        .iter()
        .map(|model| &model.id)
        .chain(images)
        .collect();
    let existing = tx
        .prepare("SELECT model FROM health_models")?
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for id in existing {
        if !ids.contains(&id) {
            tx.execute("DELETE FROM health_models WHERE model=?1", [&id])?;
        }
    }
    for id in ids {
        tx.execute("INSERT OR IGNORE INTO health_models VALUES(?1)", [id])?;
    }
    tx.execute("DELETE FROM model_directory_routes", [])?;
    for model in &next.active {
        let efforts = model
            .reasoning_settings
            .as_ref()
            .and_then(|settings| settings.allowed.as_ref());
        let efforts = efforts
            .map(serde_json::to_string)
            .transpose()
            .map_err(|_| Error::Unavailable)?;
        tx.execute(
            "INSERT INTO model_directory_routes(model,account,reasoning_efforts) VALUES(?,?,?)",
            params![model.id, next.account_for_model.get(&model.id), efforts],
        )?;
    }
    Ok(())
}

fn change_enabled(
    next: &mut Snapshot,
    active: Option<usize>,
    id: &str,
    body: &Map<String, Value>,
    discovery: Option<&Discovery>,
    now: i64,
) -> Result<Option<(String, i64)>> {
    const BASE: &[&str] = &["model", "revision", "enabled"];
    const CANDIDATE: &[&str] = &[
        "model",
        "revision",
        "enabled",
        "candidateRevision",
        "inputMicrosPerMillion",
        "outputMicrosPerMillion",
        "allowedReasoningEfforts",
        "defaultReasoningEffort",
    ];
    const RETIRED: &[&str] = &[
        "model",
        "revision",
        "enabled",
        "candidateRevision",
        "resetReasoningSettings",
        "allowedReasoningEfforts",
        "defaultReasoningEffort",
    ];
    if !valid_id(id) {
        return Err(Error::InvalidCommand);
    }
    let enabled = body
        .get("enabled")
        .and_then(Value::as_bool)
        .ok_or(Error::InvalidCommand)?;
    if !enabled {
        if !fields_only(body, BASE) {
            return Err(Error::InvalidCommand);
        }
        next.retired
            .push(next.active.remove(active.ok_or(Error::InvalidCommand)?));
        return Ok(None);
    }
    let retired = next.retired.iter().position(|model| model.id == id);
    let owner = next.account_for_model.get(id);
    if body
        .get("candidateRevision")
        .is_some_and(|revision| !revision.is_string())
    {
        return Err(Error::InvalidCommand);
    }
    let discovery = if owner.is_some() || retired.is_none() {
        Some(matching_discovery(discovery, body, now)?)
    } else {
        None
    };
    if active.is_some() {
        return Err(Error::InvalidCommand);
    }
    let mut model = if let Some(index) = retired {
        if !fields_only(body, RETIRED) {
            return Err(Error::InvalidCommand);
        }
        let reset = reset_requested(body)?;
        let original = next.retired.remove(index);
        if let Some(owner) = owner {
            let discovery = discovery
                .filter(|entry| &entry.account == owner)
                .ok_or(Error::Conflict)?;
            let entry = discovery.entry(id).ok_or(Error::Conflict)?;
            let mut updated = from_candidate(
                id,
                entry,
                original.input_micros_per_million,
                original.output_micros_per_million,
            );
            updated.reasoning_settings = original.reasoning_settings;
            if reset != reasoning_reset(&updated) {
                return Err(Error::Conflict);
            }
            if reset {
                updated.reasoning_settings = None;
            }
            updated
        } else {
            if reset {
                return Err(Error::InvalidCommand);
            }
            original
        }
    } else {
        if !fields_only(body, CANDIDATE) {
            return Err(Error::InvalidCommand);
        }
        let discovery = discovery.expect("new models require discovery");
        let entry = discovery.entry(id).ok_or(Error::InvalidCommand)?;
        let (input, output) = rates(body)?;
        next.account_for_model
            .insert(id.into(), discovery.account.clone());
        from_candidate(id, entry, input, output)
    };
    if body.contains_key("allowedReasoningEfforts") || body.contains_key("defaultReasoningEffort") {
        model.reasoning_settings = settings(body, &model)?;
    }
    next.active.push(model);
    Ok(discovery.map(|entry| (entry.account.clone(), entry.account_revision)))
}

fn refreshed_profile(
    snapshot: &Snapshot,
    old: &Model,
    discovery: Option<&Discovery>,
    now: i64,
) -> Option<Model> {
    let discovery = discovery.filter(|entry| entry.fresh(now))?;
    if snapshot
        .account_for_model
        .get(&old.id)
        .is_some_and(|owner| owner != &discovery.account)
    {
        return None;
    }
    let entry = discovery.entry(&old.id)?;
    if old.upstream.as_ref() == Some(entry) {
        return None;
    }
    let mut model = from_candidate(
        &old.id,
        entry,
        old.input_micros_per_million,
        old.output_micros_per_million,
    );
    model.image_generation = old.image_generation;
    if !valid_models(std::slice::from_ref(&model)) {
        return None;
    }
    model.reasoning_settings = old.reasoning_settings.clone();
    Some(model)
}

fn from_candidate(id: &str, entry: &Value, input: i64, output: i64) -> Model {
    Model {
        id: id.into(),
        input_micros_per_million: input,
        output_micros_per_million: output,
        catalog: None,
        vision_input: Some(
            entry["input_modalities"]
                .as_array()
                .is_some_and(|items| items.iter().any(|item| item == "image")),
        ),
        image_generation: None,
        upstream: Some(entry.clone()),
        profile_provenance: None,
        reasoning_settings: None,
    }
}

fn metadata(model: &Model, state: &str, old_vision: Option<bool>, reset: bool) -> Value {
    let supported = model.supported_reasoning_efforts();
    let number = |name: &str| model.upstream.as_ref()?.get(name)?.as_i64();
    let settings = model.reasoning_settings.as_ref();
    json!({
        "id": model.id, "state": state, "visionInput": model.vision_input == Some(true),
        "contextWindow": number("context_window").or_else(|| model.catalog.as_ref()?.context_window),
        "maxContextWindow": number("max_context_window").or_else(|| model.catalog.as_ref()?.max_context_window),
        "previousVisionInput": old_vision, "reasoningEfforts": model.effective_reasoning_efforts(),
        "supportedReasoningEfforts": supported,
        "profileDefaultReasoningEffort": model.profile_default_reasoning_effort().filter(|effort| supported.contains(effort)),
        "defaultReasoningEffort": model.effective_default_reasoning_effort(),
        "configuredReasoningEfforts": settings.and_then(|settings| settings.allowed.as_ref()),
        "configuredDefaultReasoningEffort": settings.and_then(|settings| settings.preferred.as_ref()),
        "resetReasoningRequired": reset,
    })
}

fn fields_only(body: &Map<String, Value>, names: &[&str]) -> bool {
    body.keys().all(|key| names.contains(&key.as_str()))
}

fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte))
}

fn rates(body: &Map<String, Value>) -> Result<(i64, i64)> {
    let read = |name| {
        body.get(name)
            .and_then(Value::as_i64)
            .ok_or(Error::InvalidCommand)
    };
    Ok((
        read("inputMicrosPerMillion")?,
        read("outputMicrosPerMillion")?,
    ))
}

fn matching_discovery<'a>(
    discovery: Option<&'a Discovery>,
    body: &Map<String, Value>,
    now: i64,
) -> Result<&'a Discovery> {
    discovery
        .filter(|entry| {
            entry.fresh(now)
                && body.get("candidateRevision").and_then(Value::as_str) == Some(&entry.revision)
        })
        .ok_or(Error::Conflict)
}

fn reasoning_reset(model: &Model) -> bool {
    model
        .reasoning_settings
        .as_ref()
        .is_some_and(|settings| !settings.valid_for(model))
}

fn reset_requested(body: &Map<String, Value>) -> Result<bool> {
    match body.get("resetReasoningSettings") {
        None => Ok(false),
        Some(Value::Bool(true)) => Ok(true),
        _ => Err(Error::InvalidCommand),
    }
}

fn settings(body: &Map<String, Value>, model: &Model) -> Result<Option<ModelReasoningSettings>> {
    let allowed = match body.get("allowedReasoningEfforts") {
        Some(Value::Null) => None,
        Some(Value::Array(values)) if (1..=8).contains(&values.len()) => Some(
            values
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or(Error::InvalidCommand)
                })
                .collect::<Result<Vec<_>>>()?,
        ),
        _ => return Err(Error::InvalidCommand),
    };
    let preferred = match body.get("defaultReasoningEffort") {
        Some(Value::Null) => None,
        Some(Value::String(effort)) => Some(effort.clone()),
        _ => return Err(Error::InvalidCommand),
    };
    let mut settings = ModelReasoningSettings { allowed, preferred };
    if settings.allowed.is_none() && settings.preferred.is_none() {
        return Ok(None);
    }
    if !settings.valid_for(model) {
        return Err(Error::InvalidCommand);
    }
    let previous = model
        .reasoning_settings
        .as_ref()
        .and_then(|previous| previous.allowed.as_ref());
    if let Some(allowed) = &settings.allowed
        && allowed.len() == model.supported_reasoning_efforts().len()
        && !previous.is_some_and(|old| {
            old.len() == allowed.len() && old.iter().all(|effort| allowed.contains(effort))
        })
    {
        settings.allowed = None;
    }
    Ok((settings.allowed.is_some() || settings.preferred.is_some()).then_some(settings))
}
