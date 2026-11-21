use std::{collections::BTreeMap, future::Future, sync::Arc};

use bytes::Bytes;
use codexone_admin::{AdminRouter, MAX_REQUEST_BYTES, request_too_large};
use codexone_config::Configuration;
use codexone_wire::{JsonObject, JsonValue};
use http::{Method, Request, Response, StatusCode, header};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::Semaphore;
use zeroize::Zeroizing;

use crate::{
    Account, AuthorizationMethod, AuthorizationProvider, Authorizations, Error, Governance, Key,
    KeyChange, KeyPolicy, NoAuthorizationProvider, Result, Target, Writer, uuid,
};

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyOptions {
    pub models: Vec<String>,
    pub image_models: Vec<String>,
    pub reasoning_efforts: BTreeMap<String, Vec<String>>,
    pub catalog_revision: Option<i64>,
}

impl KeyOptions {
    pub fn configured(configuration: &Configuration) -> Self {
        let Some(source) = &configuration.source else {
            return Self::default();
        };
        let responses = source.responses();
        let image_models = responses
            .image_generation
            .iter()
            .flat_map(|images| &images.models)
            .map(|model| model.id.clone())
            .collect();
        Self::for_models(&responses.models, image_models, None)
    }

    pub fn for_models(
        models: &[codexone_config::Model],
        image_models: Vec<String>,
        catalog_revision: Option<i64>,
    ) -> Self {
        let mut options = Self {
            image_models,
            catalog_revision,
            ..Self::default()
        };
        for model in models {
            options.models.push(model.id.clone());
            options.reasoning_efforts.insert(
                model.id.clone(),
                model
                    .supported_reasoning_efforts()
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
            );
        }
        options
    }
}

/// Hooks owned by the product's runtime. Cancellation must synchronously capture and
/// signal only currently registered executions, without awaiting or calling the writer.
pub trait AccountRuntime: Send + Sync + 'static {
    fn in_flight(&self, _account: &str) -> usize {
        0
    }

    fn force_stop(&self, _account: &str) -> Result<usize> {
        Err(Error::Unavailable)
    }

    fn refresh(
        &self,
        _account: String,
        _revision: i64,
    ) -> impl Future<Output = Result<Account>> + Send {
        async { Err(Error::AuthorizationUnavailable) }
    }

    fn quota_command(
        &self,
        _account: &str,
        _command: QuotaCommand,
        _body: Option<JsonValue>,
    ) -> impl Future<Output = Result<Value>> + Send {
        async { Err(Error::AuthorizationUnavailable) }
    }

    fn observability(&self, _account: &str) -> impl Future<Output = Result<Value>> + Send {
        async {
            Ok(json!({
                "quota": {
                    "state": "unavailable", "observedAtUnixSeconds": null,
                    "attemptedAtUnixSeconds": null, "ageSeconds": null,
                    "freshForSeconds": 0, "failure": null, "additionalCount": 0, "limits": []
                },
                "health": {
                    "authenticationRejected": false, "lastFailure": null,
                    "lastFailureAtUnixSeconds": null, "cooldownCount": 0, "nextCooldownEndsAtUnixSeconds": null
                },
                "observing": false
            }))
        }
    }
}

#[derive(Clone, Copy)]
pub enum QuotaCommand {
    PrimingStatus,
    PrimingSettings,
    ResetList,
    ResetStatus,
    ResetSettings,
    ResetConsume,
}

pub struct NoAccountRuntime;
impl AccountRuntime for NoAccountRuntime {}

pub struct GovernanceApi<W, P, R> {
    governance: Arc<Governance<W>>,
    authorization: Option<Authorizations<W, P>>,
    runtime: Arc<R>,
    capacity: Semaphore,
}

impl<W: Writer> GovernanceApi<W, NoAuthorizationProvider, NoAccountRuntime> {
    pub fn keys_only(governance: Arc<Governance<W>>) -> Self {
        Self::new(governance, None, NoAccountRuntime)
    }
}

impl<W: Writer, P: AuthorizationProvider, R: AccountRuntime> GovernanceApi<W, P, R> {
    pub fn new(
        governance: Arc<Governance<W>>,
        authorization: Option<Authorizations<W, P>>,
        runtime: R,
    ) -> Self {
        Self {
            governance,
            authorization,
            runtime: Arc::new(runtime),
            capacity: Semaphore::new(16),
        }
    }

    /// Invoke after core admin routes. Supply the same router that owns management sessions.
    /// The product may provide a live model snapshot for the options route.
    pub async fn route(
        &self,
        admin: &AdminRouter,
        request: &Request<Bytes>,
        options: impl FnOnce() -> KeyOptions,
    ) -> Option<Response<Bytes>> {
        let endpoint = Endpoint::parse(request)?;
        if self.authorization.is_none()
            && matches!(
                endpoint,
                Endpoint::Accounts
                    | Endpoint::Account(..)
                    | Endpoint::Quota(..)
                    | Endpoint::Begin
                    | Endpoint::Authorization(..)
            )
        {
            return None;
        }
        if request.body().len() > MAX_REQUEST_BYTES {
            return Some(request_too_large());
        }
        let Ok(_permit) = self.capacity.try_acquire() else {
            return Some(failure(
                StatusCode::SERVICE_UNAVAILABLE,
                "management_capacity",
            ));
        };
        let authorization = match admin.authorize(request.method(), request.headers()) {
            Ok(value) => value,
            Err(response) => return Some(*response),
        };
        let mut authorized = Response::new(Bytes::new());
        authorization.apply(&mut authorized);
        let result = self
            .handle(
                endpoint,
                request,
                authorized.headers().get(header::SET_COOKIE),
                options,
            )
            .await;
        let mut response = match result {
            Ok((status, payload)) => response(status, &payload),
            Err(error) => error_response(error),
        };
        response
            .headers_mut()
            .extend(authorized.into_parts().0.headers);
        Some(response)
    }

    pub async fn shutdown(&self) {
        if let Some(authorization) = &self.authorization {
            authorization.shutdown().await;
        }
    }

    async fn handle(
        &self,
        endpoint: Endpoint<'_>,
        request: &Request<Bytes>,
        renewal: Option<&http::HeaderValue>,
        options: impl FnOnce() -> KeyOptions,
    ) -> Result<(StatusCode, Value)> {
        let payload = match endpoint {
            Endpoint::KeyOptions => json!(options()),
            Endpoint::Keys => {
                let mut query = query(request, &["after", "archived"])?;
                let archived = match query.remove("archived").as_deref() {
                    None | Some("false") => false,
                    Some("true") => true,
                    _ => return Err(Error::InvalidCommand),
                };
                let keys = self
                    .governance
                    .list_keys(query.remove("after"), archived)
                    .await?;
                json!({
                    "nextCursor": cursor(&keys, |key| &key.id),
                    "keys": keys.iter().map(key_metadata).collect::<Vec<_>>(),
                })
            }
            Endpoint::Issue => {
                let body = policy_body(request, &["principal", "models", "limits"])?;
                let (key, secret) = self
                    .governance
                    .issue_key(
                        string(&body, "principal")?,
                        policy(&body)?,
                        catalog_revision(&body)?,
                    )
                    .await?;
                return Ok((
                    StatusCode::CREATED,
                    json!({"key": key_metadata(&key), "secret": secret.as_str()}),
                ));
            }
            Endpoint::Rotate(id) => {
                let body = body(request, &["revision"], &[], true)?;
                let (key, secret) = self
                    .governance
                    .rotate_key(decoded(id)?, number(&body, "revision")?)
                    .await?;
                return Ok((
                    StatusCode::CREATED,
                    json!({"key": key_metadata(&key), "secret": secret.as_str()}),
                ));
            }
            Endpoint::ChangeKey(id, kind) => {
                let (revision, change) = key_change(request, kind)?;
                let key = self
                    .governance
                    .change_key(decoded(id)?, revision, change)
                    .await?;
                json!({"key": key_metadata(&key)})
            }
            Endpoint::Accounts => {
                let mut query = query(request, &["after"])?;
                self.accounts_document(query.remove("after"), false).await?
            }
            Endpoint::Account(id, kind) => {
                let id = decoded(id)?;
                let account = match kind {
                    AccountCommand::Mode => {
                        let fields = body(request, &["revision", "mode"], &[], false)?;
                        self.governance
                            .set_account_mode(
                                id,
                                number(&fields, "revision")?,
                                parse(fields.get("mode"))?,
                            )
                            .await?
                    }
                    AccountCommand::DisplayName => {
                        no_query(request)?;
                        let fields = body(request, &["revision", "displayName"], &[], false)?;
                        self.governance
                            .set_account_display_name(
                                id,
                                number(&fields, "revision")?,
                                nullable_string(&fields, "displayName")?,
                            )
                            .await?
                    }
                    AccountCommand::ForceStop => {
                        no_query(request)?;
                        let fields = body(request, &["revision"], &[], false)?;
                        let runtime = self.runtime.clone();
                        let count = self
                            .governance
                            .force_stop(id, number(&fields, "revision")?, move |id| {
                                runtime.force_stop(id)
                            })
                            .await?;
                        return Ok((StatusCode::OK, json!({"cancellationRequested": count})));
                    }
                    AccountCommand::Refresh => {
                        let fields = body(request, &["revision"], &[], false)?;
                        self.runtime
                            .refresh(id, number(&fields, "revision")?)
                            .await?
                    }
                };
                json!({"account": self.account_metadata(&account).await?})
            }
            Endpoint::Quota(id, command) => {
                no_query(request)?;
                use QuotaCommand::*;
                let fields = match command {
                    PrimingStatus | ResetList | ResetStatus => None,
                    PrimingSettings => Some(quota_body(
                        request,
                        &["revision", "enabled", "model", "message"],
                        &[],
                    )?),
                    ResetSettings => Some(quota_body(
                        request,
                        &["revision", "autoUseBeforeExpiry"],
                        &["leadMinutes", "retryCount", "leadHours"],
                    )?),
                    ResetConsume => Some(quota_body(request, &[], &["creditID"])?),
                };
                self.runtime
                    .quota_command(&decoded(id)?, command, fields.map(JsonValue::Object))
                    .await?
            }
            Endpoint::Begin | Endpoint::Authorization(_, _) => {
                let auth = self
                    .authorization
                    .as_ref()
                    .ok_or(Error::AuthorizationUnavailable)?;
                let owner = owner(request, renewal)?;
                match endpoint {
                    Endpoint::Begin => {
                        let fields = body(request, &["target"], &["method"], false)?;
                        let method = fields
                            .get("method")
                            .map(|method| parse(Some(method)))
                            .transpose()?
                            .unwrap_or(AuthorizationMethod::Device);
                        let target = match fields.get("target") {
                            Some(JsonValue::Null) => Target::Create,
                            Some(JsonValue::Object(target)) if target.len() == 2 => {
                                Target::Reauthorize {
                                    id: string(target, "id")?,
                                    revision: number(target, "revision")?,
                                }
                            }
                            _ => return Err(Error::InvalidCommand),
                        };
                        json!(auth.begin(owner, target, method).await?)
                    }
                    Endpoint::Authorization(id, &Method::GET) => {
                        no_query(request)?;
                        json!(auth.status(&owner, &decoded(id)?)?)
                    }
                    Endpoint::Authorization(id, &Method::DELETE) => {
                        no_query(request)?;
                        auth.discard(&owner, &decoded(id)?).await?;
                        json!({"discarded": true})
                    }
                    Endpoint::Authorization(id, _) => {
                        let body = body(request, &["callbackURL"], &[], false)?;
                        let result = auth
                            .complete(
                                &owner,
                                &decoded(id)?,
                                Zeroizing::new(string(&body, "callbackURL")?),
                            )
                            .await?;
                        json!({"account": self.account_metadata(&result).await?})
                    }
                    _ => unreachable!(),
                }
            }
        };
        Ok((StatusCode::OK, payload))
    }

    /// Same account documents as authenticated HTTP, used directly by the overview.
    pub async fn overview_accounts(&self) -> Result<Value> {
        if self.authorization.is_none() {
            return Err(Error::AuthorizationUnavailable);
        }
        let _permit = self.capacity.try_acquire().map_err(|_| Error::Capacity)?;
        self.accounts_document(None, true).await
    }

    async fn accounts_document(&self, after: Option<String>, all: bool) -> Result<Value> {
        let accounts = self.governance.list_accounts(after).await?;
        let mut entries = Vec::with_capacity(accounts.len());
        for account in &accounts {
            let mut metadata = self.account_metadata(account).await?;
            metadata["observability"] = self.runtime.observability(&account.id).await?;
            entries.push(metadata);
        }
        let next = if all {
            None
        } else {
            cursor(&accounts, |account| &account.id)
        };
        Ok(json!({"accounts": entries, "nextCursor": next}))
    }

    async fn account_metadata(&self, account: &Account) -> Result<Value> {
        let (updated, expiry) = self.governance.credential_times(account.id.clone()).await?;
        Ok(json!({
            "id": account.id, "revision": account.revision, "displayName": account.display_name,
            "credentialVersion": account.credential_version, "mode": account.mode,
            "authorization": account.authorization, "createdAtUnixSeconds": account.created_at_unix_seconds,
            "accessExpiresAtUnixSeconds": expiry, "credentialUpdatedAtUnixSeconds": updated,
            "inFlight": self.runtime.in_flight(&account.id),
        }))
    }
}

enum Endpoint<'a> {
    KeyOptions,
    Keys,
    Issue,
    Rotate(&'a str),
    ChangeKey(&'a str, KeyCommand),
    Accounts,
    Account(&'a str, AccountCommand),
    Quota(&'a str, QuotaCommand),
    Begin,
    Authorization(&'a str, &'a Method),
}

enum KeyCommand {
    Policy,
    DisplayName,
    Expiration,
    Archive(bool),
}
enum AccountCommand {
    Mode,
    DisplayName,
    ForceStop,
    Refresh,
}

impl<'a> Endpoint<'a> {
    fn parse(request: &'a Request<Bytes>) -> Option<Self> {
        use Method as M;
        let mut path = request
            .uri()
            .path()
            .split('/')
            .filter(|segment| !segment.is_empty());
        let (prefix, group, target, action, extra) = (
            path.next()?,
            path.next()?,
            path.next(),
            path.next(),
            path.next(),
        );
        if prefix != "api" || path.next().is_some() {
            return None;
        }
        if let Some(extra) = extra {
            use QuotaCommand::*;
            return match (group, target, action, extra, request.method()) {
                ("accounts", Some(id), Some("reset-credits"), "state", &M::GET) => {
                    Some(Self::Quota(id, ResetStatus))
                }
                ("accounts", Some(id), Some("reset-credits"), "settings", &M::PUT) => {
                    Some(Self::Quota(id, ResetSettings))
                }
                ("accounts", Some(id), Some("reset-credits"), "consume", &M::POST) => {
                    Some(Self::Quota(id, ResetConsume))
                }
                _ => None,
            };
        }
        Some(match (group, target, action, request.method()) {
            ("keys", Some("options"), None, &M::GET) => Self::KeyOptions,
            ("keys", None, None, &M::GET) => Self::Keys,
            ("keys", None, None, &M::POST) => Self::Issue,
            ("keys", Some(id), Some("rotate"), &M::POST) => Self::Rotate(id),
            ("keys", Some(id), None, &M::PUT) => Self::ChangeKey(id, KeyCommand::Policy),
            ("keys", Some(id), Some("display-name"), &M::PUT) => {
                Self::ChangeKey(id, KeyCommand::DisplayName)
            }
            ("keys", Some(id), Some("expiration"), &M::PUT) => {
                Self::ChangeKey(id, KeyCommand::Expiration)
            }
            ("keys", Some(id), Some("archive"), &M::PUT) => {
                Self::ChangeKey(id, KeyCommand::Archive(true))
            }
            ("keys", Some(id), Some("unarchive"), &M::PUT) => {
                Self::ChangeKey(id, KeyCommand::Archive(false))
            }
            ("accounts", None, None, &M::GET) => Self::Accounts,
            ("accounts", Some("authorization"), None, &M::POST) => Self::Begin,
            (
                "accounts",
                Some("authorization"),
                Some(id),
                method @ (&M::GET | &M::POST | &M::DELETE),
            ) => Self::Authorization(id, method),
            ("accounts", Some(id), Some("quota-priming"), &M::GET) => {
                Self::Quota(id, QuotaCommand::PrimingStatus)
            }
            ("accounts", Some(id), Some("quota-priming"), &M::PUT) => {
                Self::Quota(id, QuotaCommand::PrimingSettings)
            }
            ("accounts", Some(id), Some("reset-credits"), &M::GET) => {
                Self::Quota(id, QuotaCommand::ResetList)
            }
            ("accounts", Some(id), None, &M::PUT) => Self::Account(id, AccountCommand::Mode),
            ("accounts", Some(id), Some("display-name"), &M::PUT) => {
                Self::Account(id, AccountCommand::DisplayName)
            }
            ("accounts", Some(id), Some("force-stop"), &M::POST) => {
                Self::Account(id, AccountCommand::ForceStop)
            }
            ("accounts", Some(id), Some("refresh"), &M::POST) => {
                Self::Account(id, AccountCommand::Refresh)
            }
            _ => return None,
        })
    }
}

fn key_metadata(key: &Key) -> Value {
    let policy = &key.policy;
    json!({
        "id": key.id, "principal": key.principal, "enabled": key.enabled,
        "revision": key.revision, "createdAtUnixSeconds": key.created_at_unix_seconds,
        "expiresAtUnixSeconds": key.expires_at_unix_seconds, "archivedAtUnixSeconds": key.archived_at_unix_seconds,
        "displayName": key.display_name, "models": policy.models, "visionInput": policy.vision_input,
        "imageGeneration": policy.image_generation, "imageModels": policy.image_models, "limits": policy.limits,
        "reasoningEfforts": policy.reasoning_efforts.as_ref().map_or_else(|| json!({}), |rules| json!(rules)),
    })
}

fn key_change(request: &Request<Bytes>, command: KeyCommand) -> Result<(i64, KeyChange)> {
    if let KeyCommand::Policy = command {
        let fields = policy_body(request, &["revision", "enabled", "models", "limits"])?;
        let enabled = fields
            .get("enabled")
            .and_then(JsonValue::as_bool)
            .ok_or(Error::InvalidCommand)?;
        return Ok((
            number(&fields, "revision")?,
            KeyChange::Policy {
                enabled,
                policy: policy(&fields)?,
                catalog_revision: catalog_revision(&fields)?,
            },
        ));
    }
    no_query(request)?;
    let optional = match command {
        KeyCommand::DisplayName => &["revision", "displayName"][..],
        KeyCommand::Expiration => &["revision", "expiresAtUnixSeconds"][..],
        _ => &["revision"][..],
    };
    let fields = body(request, optional, &[], true)?;
    let revision = number(&fields, "revision")?;
    let change = match command {
        KeyCommand::DisplayName => KeyChange::DisplayName(nullable_string(&fields, "displayName")?),
        KeyCommand::Expiration => KeyChange::Expiration(match fields.get("expiresAtUnixSeconds") {
            Some(JsonValue::Null) => None,
            _ => Some(number(&fields, "expiresAtUnixSeconds")?),
        }),
        KeyCommand::Archive(archived) => KeyChange::Archive(archived),
        KeyCommand::Policy => unreachable!(),
    };
    Ok((revision, change))
}

fn policy_body(request: &Request<Bytes>, required: &[&str]) -> Result<JsonObject> {
    body(
        request,
        required,
        &[
            "visionInput",
            "imageGeneration",
            "imageModels",
            "reasoningEfforts",
            "catalogRevision",
        ],
        true,
    )
}

fn policy(fields: &JsonObject) -> Result<KeyPolicy> {
    let limits = fields
        .get("limits")
        .and_then(JsonValue::as_object)
        .ok_or(Error::InvalidCommand)?;
    if limits.len() != 2 || limits.get("active").is_none() || limits.get("tokens").is_none() {
        return Err(Error::InvalidCommand);
    }
    let mut fields = fields.clone();
    fields.remove("limits");
    fields.insert("limits", JsonValue::Object(JsonObject::new()));
    let mut document: KeyPolicy = parse(Some(&JsonValue::Object(fields)))?;
    for (name, value) in [
        ("tokens", &mut document.limits.tokens),
        ("active", &mut document.limits.active),
    ] {
        if !matches!(limits.get(name), Some(JsonValue::Null)) {
            *value = Some(number(limits, name)?);
        }
    }
    Ok(document)
}

fn catalog_revision(fields: &JsonObject) -> Result<Option<i64>> {
    fields
        .get("catalogRevision")
        .map(|value| {
            value
                .as_i64()
                .filter(|revision| *revision >= 0)
                .ok_or(Error::InvalidCommand)
        })
        .transpose()
}

fn body(
    request: &Request<Bytes>,
    required: &[&str],
    optional: &[&str],
    key: bool,
) -> Result<JsonObject> {
    parse_body(request, required, optional, key, &[])
}

fn quota_body(
    request: &Request<Bytes>,
    required: &[&str],
    optional: &[&str],
) -> Result<JsonObject> {
    let unique: Vec<_> = required.iter().chain(optional).copied().collect();
    parse_body(request, required, optional, false, &unique)
}

fn parse_body(
    request: &Request<Bytes>,
    required: &[&str],
    optional: &[&str],
    key: bool,
    unique: &[&str],
) -> Result<JsonObject> {
    let mut values = request.headers().get_all(header::CONTENT_TYPE).iter();
    let content_type = values
        .next()
        .and_then(|value| value.to_str().ok())
        .ok_or(Error::InvalidCommand)?
        .to_ascii_lowercase();
    let valid_type = if key {
        content_type.starts_with("application/json")
    } else {
        content_type
            .split(';')
            .next()
            .is_some_and(|mime| mime.trim() == "application/json")
    };
    if !valid_type
        || values.next().is_some()
        || request.headers().contains_key(header::CONTENT_ENCODING)
    {
        return Err(Error::InvalidCommand);
    }
    let JsonValue::Object(fields) = JsonValue::decode_rejecting_duplicates(request.body(), unique)
        .map_err(|_| Error::InvalidCommand)?
    else {
        return Err(Error::InvalidCommand);
    };
    if !required.iter().all(|field| fields.get(field).is_some())
        || fields
            .iter()
            .any(|(field, _)| !required.contains(&field) && !optional.contains(&field))
    {
        return Err(Error::InvalidCommand);
    }
    Ok(fields)
}

fn parse<T: serde::de::DeserializeOwned>(value: Option<&JsonValue>) -> Result<T> {
    serde_json::from_slice(&value.ok_or(Error::InvalidCommand)?.encode(false))
        .map_err(|_| Error::InvalidCommand)
}

fn number(fields: &JsonObject, name: &str) -> Result<i64> {
    fields
        .get(name)
        .and_then(JsonValue::as_i64)
        .ok_or(Error::InvalidCommand)
}

fn string(fields: &JsonObject, name: &str) -> Result<String> {
    fields
        .get(name)
        .and_then(JsonValue::as_str)
        .map(str::to_owned)
        .ok_or(Error::InvalidCommand)
}

fn nullable_string(fields: &JsonObject, name: &str) -> Result<Option<String>> {
    if matches!(fields.get(name), Some(JsonValue::Null)) {
        Ok(None)
    } else {
        string(fields, name).map(Some)
    }
}

fn decoded(raw: &str) -> Result<String> {
    percent_encoding::percent_decode_str(raw)
        .decode_utf8()
        .map(|value| value.into_owned())
        .map_err(|_| Error::InvalidCommand)
}

fn query(request: &Request<Bytes>, allowed: &[&str]) -> Result<BTreeMap<String, String>> {
    let mut result = BTreeMap::new();
    for pair in request
        .uri()
        .query()
        .filter(|query| !query.is_empty())
        .into_iter()
        .flat_map(|query| query.split('&'))
    {
        let (key, value) = pair.split_once('=').ok_or(Error::InvalidCommand)?;
        let key = decoded(key)?;
        if !allowed.contains(&key.as_str()) || result.insert(key, decoded(value)?).is_some() {
            return Err(Error::InvalidCommand);
        }
    }
    Ok(result)
}

fn no_query(request: &Request<Bytes>) -> Result<()> {
    if request.uri().query().is_some() {
        Err(Error::InvalidCommand)
    } else {
        Ok(())
    }
}

fn cursor<T>(items: &[T], id: impl FnOnce(&T) -> &str) -> Option<&str> {
    if items.len() == 64 {
        items.last().map(id)
    } else {
        None
    }
}

fn owner(request: &Request<Bytes>, renewal: Option<&http::HeaderValue>) -> Result<String> {
    // The shared router has already authenticated the request. Use the token from
    // its renewal to identify the authenticated browser when both cookie names are present.
    if let Some(renewal) = renewal {
        let token = renewal
            .to_str()
            .ok()
            .and_then(|cookie| cookie.split(';').next())
            .and_then(|cookie| cookie.split_once('='))
            .map(|(_, token)| token)
            .ok_or(Error::Unauthorized)?;
        return Ok(codexone_storage::key_digest(token));
    }
    let bearer = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .ok_or(Error::Unauthorized)?;
    codexone_storage::bearer_digest(&[bearer]).map_err(|_| Error::Unauthorized)
}

pub fn error_response(error: Error) -> Response<Bytes> {
    use StatusCode as S;
    let (status, code) = match error {
        Error::InvalidCommand => (S::BAD_REQUEST, "invalid_command"),
        Error::InvalidAuthorizationCommand => (S::BAD_REQUEST, "invalid_authorization_command"),
        Error::Conflict => (S::CONFLICT, "revision_conflict"),
        Error::AccountConflict => (S::CONFLICT, "account_conflict"),
        Error::AuthorizationRequired => (S::CONFLICT, "authorization_required"),
        Error::Unauthorized => (S::UNAUTHORIZED, "invalid_admin_credential"),
        Error::KeyEnabled => (S::CONFLICT, "key_enabled"),
        Error::KeyArchived => (S::CONFLICT, "key_archived"),
        Error::KeyNotArchived => (S::CONFLICT, "key_not_archived"),
        Error::AuthorizationUnavailable => (S::SERVICE_UNAVAILABLE, "account_unavailable"),
        Error::AccountStorageUnavailable => (S::SERVICE_UNAVAILABLE, "account_storage_unavailable"),
        _ => (S::SERVICE_UNAVAILABLE, "management_unavailable"),
    };
    failure(status, code)
}

pub fn failure(status: StatusCode, code: &str) -> Response<Bytes> {
    response(
        status,
        &json!({
            "error": {"code": code, "message": "Management request failed.",
                      "request_id": uuid().unwrap_or_else(|_| "local".into())}
        }),
    )
}

pub fn response(status: StatusCode, payload: &Value) -> Response<Bytes> {
    let mut response = Response::new(Bytes::from(
        serde_json::to_vec(payload).expect("serialize management JSON"),
    ));
    *response.status_mut() = status;
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        http::HeaderValue::from_static("application/json"),
    );
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        http::HeaderValue::from_static("no-store"),
    );
    response
        .headers_mut()
        .insert(header::CONNECTION, http::HeaderValue::from_static("close"));
    response
}
