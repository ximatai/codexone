use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use codexone_governance::{
    AuthorizationProvider, DeviceCode, DeviceGrant, FailureCode, PollError, ProviderFailure,
    RefreshFailure, RefreshProvider, VerifiedAuthorization,
};
use codexone_http_upstream::{
    Bytes, CancellationToken, Error as TransportError, ExchangeOptions, HttpUpstream, Instant,
    Proxy, RequestBody, Response,
};
use codexone_storage::AccountCredential;
use http::{HeaderMap, HeaderValue, Method, Request, StatusCode, header};
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;
use zeroize::Zeroizing;

use crate::{
    claims::{CLIENT, Claims, ISSUER, MAX_EPOCH, integer, visible},
    quota::{QuotaFailure, SubscriptionQuota},
};

const CALLBACK: &str = "http://localhost:1455/auth/callback";
const TOKEN: &str = "/oauth/token";
const DEVICE_CODE: &str = "/api/accounts/deviceauth/usercode";
const DEVICE_POLL: &str = "/api/accounts/deviceauth/token";
const USAGE: &str = "/backend-api/wham/usage";
const BODY_LIMIT: usize = 65_536;
const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
const QUOTA_TIMEOUT: Duration = Duration::from_secs(5);
const UNRESERVED: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// Production origins are fixed. Synthetic auth and usage hosts are always loopback.
#[derive(Clone)]
pub struct SubscriptionProvider {
    realm: String,
    usage_url: String,
    auth: HttpUpstream,
    quota: HttpUpstream,
    auth_slots: Arc<Semaphore>,
    now: Arc<dyn Fn() -> i64 + Send + Sync>,
}

impl SubscriptionProvider {
    /// Uses the same explicitly configured trusted proxy as subscription requests, when supplied.
    pub fn production(proxy: Option<Proxy>) -> Self {
        Self::new(
            ISSUER.into(),
            "https://chatgpt.com".into(),
            proxy,
            unix_seconds,
        )
    }

    pub fn synthetic_loopback(
        auth_port: std::num::NonZeroU16,
        data_port: std::num::NonZeroU16,
        clock: impl Fn() -> i64 + Send + Sync + 'static,
    ) -> Self {
        Self::new(
            format!("http://127.0.0.1:{auth_port}"),
            format!("http://127.0.0.1:{data_port}"),
            None,
            clock,
        )
    }

    fn new(
        realm: String,
        usage_origin: String,
        proxy: Option<Proxy>,
        clock: impl Fn() -> i64 + Send + Sync + 'static,
    ) -> Self {
        Self {
            realm,
            usage_url: format!("{usage_origin}{USAGE}"),
            auth: HttpUpstream::new(proxy.clone()),
            quota: HttpUpstream::new(proxy),
            auth_slots: Arc::new(Semaphore::new(4)),
            now: Arc::new(clock),
        }
    }

    pub(crate) fn now(&self) -> i64 {
        (self.now)().clamp(0, MAX_EPOCH)
    }

    /// A local identity check for a trusted sealed credential. The stored ID
    /// baseline may have expired while remaining sufficient to attempt a refresh.
    pub fn verifies_identity(&self, namespace: &str, credential: &AccountCredential) -> bool {
        self.baseline(credential, namespace).is_some()
    }

    /// The consumer must use a credential opened from a trusted sealed record
    /// and enforce revision and credential version again at durable admission.
    pub fn verified_headers(
        &self,
        namespace: &str,
        credential: &AccountCredential,
    ) -> Option<HeaderMap> {
        let now = self.now();
        if credential.expires_at_unix_seconds() <= now {
            return None;
        }
        let id = self.baseline(credential, namespace)?;
        let access = Claims::access(credential.access_token(), now)?;
        if !id.matches(&access) {
            return None;
        }
        let mut headers = HeaderMap::new();
        let mut authorization =
            HeaderValue::from_str(&format!("Bearer {}", credential.access_token())).ok()?;
        authorization.set_sensitive(true);
        headers.insert(header::AUTHORIZATION, authorization);
        let mut account = HeaderValue::from_str(&id.account).ok()?;
        account.set_sensitive(true);
        headers.insert("chatgpt-account-id", account);
        Some(headers)
    }

    fn baseline(&self, credential: &AccountCredential, namespace: &str) -> Option<Claims> {
        let id = Claims::id(credential.id_token()?, None, None)?;
        (id.namespace(&self.realm) == namespace).then_some(id)
    }

    pub(crate) async fn observe(
        &self,
        namespace: &str,
        credential: &AccountCredential,
        stop: CancellationToken,
        deadline: Instant,
    ) -> Result<SubscriptionQuota, QuotaFailure> {
        let headers = self
            .verified_headers(namespace, credential)
            .ok_or(QuotaFailure::Unavailable)?;
        let account = headers["chatgpt-account-id"].clone();
        let mut request = Request::builder()
            .method(Method::GET)
            .uri(&self.usage_url)
            .body(RequestBody::bytes(Bytes::new()))
            .map_err(|_| QuotaFailure::Unavailable)?;
        *request.headers_mut() = headers;
        request
            .headers_mut()
            .insert(header::ACCEPT, HeaderValue::from_static("application/json"));
        request
            .headers_mut()
            .insert(header::USER_AGENT, HeaderValue::from_static("codex-cli"));
        let mut options = ExchangeOptions::new(
            deadline.min(Instant::now() + QUOTA_TIMEOUT),
            QUOTA_TIMEOUT,
            BODY_LIMIT,
        );
        options.cancellation = stop;
        let response = self
            .quota
            .send(request, options)
            .await
            .map_err(quota_transport)?;
        let failure = match response.status() {
            StatusCode::OK => None,
            StatusCode::UNAUTHORIZED => Some(QuotaFailure::AuthorizationRejected),
            StatusCode::TOO_MANY_REQUESTS => Some(QuotaFailure::RateLimited),
            _ => Some(QuotaFailure::Unavailable),
        };
        if let Some(failure) = failure {
            response.close().await;
            return Err(failure);
        }
        let doc = document(response).await.map_err(|e| match e {
            DocumentError::Transport(error) => quota_transport(error),
            DocumentError::Invalid => QuotaFailure::InvalidResponse,
        })?;
        if present(&doc, "account_id").is_some_and(|value| value.as_str() != account.to_str().ok())
        {
            return Err(QuotaFailure::InvalidResponse);
        }
        SubscriptionQuota::parse(&doc)
    }

    async fn post(&self, path: &str, payload: Payload<'_>) -> Result<AuthResponse, TransportError> {
        let deadline = Instant::now() + AUTH_TIMEOUT;
        let _permit = tokio::time::timeout_at(deadline, self.auth_slots.acquire())
            .await
            .map_err(|_| TransportError::ConnectTimeout)?
            .map_err(|_| TransportError::Cancelled)?;
        let (body, content_type) = match payload {
            Payload::Json(fields) => (
                serde_json::to_vec(
                    &fields
                        .iter()
                        .copied()
                        .collect::<std::collections::BTreeMap<_, _>>(),
                )
                .expect("string map"),
                "application/json",
            ),
            Payload::Form(fields) => (
                encoded_pairs(fields).into_bytes(),
                "application/x-www-form-urlencoded",
            ),
        };
        let request = Request::post(format!("{}{path}", self.realm))
            .header(header::CONTENT_TYPE, content_type)
            .header(header::ACCEPT, "application/json")
            .body(RequestBody::bytes(Bytes::from_owner(Zeroizing::new(body))))
            .map_err(|_| TransportError::InvalidRequest)?;
        let options = ExchangeOptions::new(deadline, AUTH_TIMEOUT, BODY_LIMIT);
        let response = self.auth.send(request, options).await?;
        let status = response.status();
        // Authorization status determines diagnostics before any untrusted error body.
        let read = status == StatusCode::OK
            || matches!(payload, Payload::Json(fields) if path == TOKEN && fields.iter().any(|(key, _)| *key == "refresh_token"))
                && matches!(status, StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED);
        let json = if read {
            document(response).await.ok()
        } else {
            response.close().await;
            None
        };
        Ok(AuthResponse { status, json })
    }

    async fn exchange(
        &self,
        code: &str,
        verifier: &str,
        redirect: &str,
        nonce: Option<&str>,
    ) -> Result<VerifiedAuthorization, ProviderFailure> {
        if !visible(code, 4096)
            || !unreserved(verifier, 43)
            || nonce.is_some_and(|n| !unreserved(n, 32))
        {
            return Err(FailureCode::VerificationFailed.into());
        }
        let response = self
            .post(
                TOKEN,
                Payload::Form(&[
                    ("grant_type", "authorization_code"),
                    ("client_id", CLIENT),
                    ("code", code),
                    ("code_verifier", verifier),
                    ("redirect_uri", redirect),
                ]),
            )
            .await
            .map_err(|_| FailureCode::ExchangeFailed)?;
        let doc = response.success(FailureCode::ExchangeFailed, FailureCode::ExchangeFailed)?;
        let failure = |code| ProviderFailure::new(code, Some(200));
        let access =
            required(&doc, "access_token").ok_or_else(|| failure(FailureCode::ExchangeFailed))?;
        let refresh =
            required(&doc, "refresh_token").ok_or_else(|| failure(FailureCode::ExchangeFailed))?;
        let id_token =
            required(&doc, "id_token").ok_or_else(|| failure(FailureCode::ExchangeFailed))?;
        let now = self.now();
        let verify = || {
            let id = Claims::id(id_token, nonce, Some(now))?;
            let identity = Claims::access(access, now)?;
            let expires = expiry(&doc, &identity, now)?;
            if !id.matches(&identity) {
                return None;
            }
            let credential = AccountCredential::new(
                access.into(),
                refresh.into(),
                Some(id_token.into()),
                expires,
            )
            .ok()?;
            Some(VerifiedAuthorization {
                namespace: id.namespace(&self.realm),
                credential,
            })
        };
        if expires_in(&doc).is_none() {
            return Err(failure(FailureCode::ExchangeFailed));
        }
        verify().ok_or_else(|| failure(FailureCode::VerificationFailed))
    }
}

impl RefreshProvider for SubscriptionProvider {
    async fn refresh(
        &self,
        credential: &AccountCredential,
        namespace: &str,
    ) -> Result<VerifiedAuthorization, RefreshFailure> {
        let baseline = self
            .baseline(credential, namespace)
            .ok_or(RefreshFailure::Unknown)?;
        let response = self
            .post(
                TOKEN,
                Payload::Json(&[
                    ("grant_type", "refresh_token"),
                    ("client_id", CLIENT),
                    ("refresh_token", credential.refresh_token()),
                ]),
            )
            .await
            .map_err(|error| match error {
                TransportError::Connect | TransportError::ConnectTimeout => {
                    RefreshFailure::NotCompleted
                }
                _ => RefreshFailure::Unknown,
            })?;
        if response.status != StatusCode::OK {
            return Err(
                if response
                    .json
                    .as_ref()
                    .is_some_and(|doc| rejected(response.status, doc))
                {
                    RefreshFailure::AuthorizationRequired
                } else {
                    RefreshFailure::Unknown
                },
            );
        }
        let verify = || {
            let doc = response.json?;
            if !bearer_type(&doc) {
                return None;
            }
            let now = self.now();
            let access_token = required(&doc, "access_token")?;
            let access = Claims::access(access_token, now)?;
            if !baseline.matches(&access) {
                return None;
            }
            let mut id_token = credential.id_token()?;
            if doc.get("id_token").is_some() {
                id_token = required(&doc, "id_token")?;
                let id = Claims::id(id_token, None, Some(now))?;
                if !baseline.matches(&id) || !access.matches(&id) {
                    return None;
                }
            }
            let refresh = if doc.get("refresh_token").is_some() {
                required(&doc, "refresh_token")?
            } else {
                credential.refresh_token()
            };
            let credential = AccountCredential::new(
                access_token.into(),
                refresh.into(),
                Some(id_token.into()),
                expiry(&doc, &access, now)?,
            )
            .ok()?;
            Some(VerifiedAuthorization {
                namespace: namespace.into(),
                credential,
            })
        };
        verify().ok_or(RefreshFailure::Unknown)
    }
}

impl AuthorizationProvider for SubscriptionProvider {
    fn authorization_url(
        &self,
        state: &str,
        nonce: &str,
        verifier: &str,
    ) -> Result<String, FailureCode> {
        if !unreserved(state, 32) || !unreserved(nonce, 32) || !unreserved(verifier, 43) {
            return Err(FailureCode::VerificationFailed);
        }
        let query = encoded_pairs(&[
            ("response_type", "code"),
            ("client_id", CLIENT),
            ("redirect_uri", CALLBACK),
            ("scope", "openid profile email offline_access"),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", &challenge(verifier)),
            ("code_challenge_method", "S256"),
            ("id_token_add_organizations", "true"),
        ]);
        Ok(format!("{}/oauth/authorize?{query}", self.realm))
    }

    async fn authorize(
        &self,
        code: &str,
        verifier: &str,
        nonce: &str,
    ) -> Result<VerifiedAuthorization, ProviderFailure> {
        self.exchange(code, verifier, CALLBACK, Some(nonce)).await
    }

    async fn request_device_code(&self) -> Result<DeviceCode, ProviderFailure> {
        let response = self
            .post(DEVICE_CODE, Payload::Json(&[("client_id", CLIENT)]))
            .await
            .map_err(|_| FailureCode::AuthorizationFailed)?;
        if response.status == StatusCode::NOT_FOUND {
            return Err(ProviderFailure::new(
                FailureCode::DeviceCodeUnavailable,
                Some(404),
            ));
        }
        let doc = response.success(
            FailureCode::ProviderRejected,
            FailureCode::AuthorizationFailed,
        )?;
        let parse = || {
            let id = required(&doc, "device_auth_id").filter(|id| visible(id, 4096))?;
            let code = required(&doc, "user_code").filter(|code| {
                code.len() <= 128 && code.bytes().all(|b| (32..=126).contains(&b))
            })?;
            let interval = doc["interval"]
                .as_str()
                .and_then(|value| value.trim().parse::<i64>().ok())
                .or_else(|| integer(&doc["interval"]))
                .filter(|seconds| *seconds > 0)?;
            let expires = match doc.get("expires_in") {
                Some(value) => {
                    integer(value).filter(|seconds| (1..=1_000_000).contains(seconds))?
                }
                None => 900,
            };
            Some(DeviceCode {
                device_auth_id: Zeroizing::new(id.into()),
                user_code: Zeroizing::new(code.into()),
                verification_url: format!("{}/codex/device", self.realm),
                interval_seconds: interval,
                expires_in_seconds: expires.min(900),
            })
        };
        parse().ok_or_else(|| ProviderFailure::new(FailureCode::AuthorizationFailed, Some(200)))
    }

    async fn poll_device_code(&self, code: &DeviceCode) -> Result<Option<DeviceGrant>, PollError> {
        let response = self
            .post(
                DEVICE_POLL,
                Payload::Json(&[
                    ("device_auth_id", &code.device_auth_id),
                    ("user_code", &code.user_code),
                ]),
            )
            .await
            .map_err(|_| PollError::NoResponse)?;
        if matches!(
            response.status,
            StatusCode::FORBIDDEN | StatusCode::NOT_FOUND
        ) {
            return Ok(None);
        }
        let doc = response
            .success(
                FailureCode::ProviderRejected,
                FailureCode::AuthorizationFailed,
            )
            .map_err(PollError::Failed)?;
        let failure = |code| PollError::Failed(ProviderFailure::new(code, Some(200)));
        let fields = || {
            Some((
                required(&doc, "authorization_code")?,
                required(&doc, "code_verifier")?,
                required(&doc, "code_challenge")?,
            ))
        };
        let (code, verifier, expected) =
            fields().ok_or_else(|| failure(FailureCode::AuthorizationFailed))?;
        if !visible(code, 4096) || !unreserved(verifier, 43) || expected != challenge(verifier) {
            return Err(failure(FailureCode::VerificationFailed));
        }
        Ok(Some(DeviceGrant {
            code: Zeroizing::new(code.into()),
            verifier: Zeroizing::new(verifier.into()),
        }))
    }

    async fn authorize_device(
        &self,
        grant: &DeviceGrant,
    ) -> Result<VerifiedAuthorization, ProviderFailure> {
        self.exchange(
            &grant.code,
            &grant.verifier,
            &format!("{}/deviceauth/callback", self.realm),
            None,
        )
        .await
    }
}

#[derive(Clone, Copy)]
enum Payload<'a> {
    Json(&'a [(&'a str, &'a str)]),
    Form(&'a [(&'a str, &'a str)]),
}

struct AuthResponse {
    status: StatusCode,
    json: Option<Value>,
}

impl AuthResponse {
    fn success(
        self,
        rejected: FailureCode,
        invalid: FailureCode,
    ) -> Result<Value, ProviderFailure> {
        if self.status != StatusCode::OK {
            return Err(ProviderFailure::new(rejected, Some(self.status.as_u16())));
        }
        self.json
            .filter(bearer_type)
            .ok_or_else(|| ProviderFailure::new(invalid, Some(200)))
    }
}

enum DocumentError {
    Invalid,
    Transport(TransportError),
}

async fn document(response: Response) -> Result<Value, DocumentError> {
    let types = response.headers().get_all(header::CONTENT_TYPE);
    let mut types = types.iter();
    let json = types
        .next()
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("application/json"));
    if !json || types.next().is_some() || response.headers().contains_key(header::CONTENT_ENCODING)
    {
        response.close().await;
        return Err(DocumentError::Invalid);
    }
    let bytes = response.collect().await.map_err(DocumentError::Transport)?;
    let document: Value = serde_json::from_slice(&bytes).map_err(|_| DocumentError::Invalid)?;
    document
        .is_object()
        .then_some(document)
        .ok_or(DocumentError::Invalid)
}

fn rejected(status: StatusCode, doc: &Value) -> bool {
    matches!(status, StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED)
        && ["access_token", "refresh_token", "id_token"]
            .iter()
            .all(|key| doc.get(key).is_none())
        && (doc["error"].as_str() == Some("invalid_grant")
            || matches!(
                doc["error"]["code"].as_str(),
                Some(
                    "refresh_token_expired" | "refresh_token_reused" | "refresh_token_invalidated"
                )
            ))
}

fn bearer_type(doc: &Value) -> bool {
    doc.get("token_type").is_none_or(|value| {
        value
            .as_str()
            .is_some_and(|text| text.eq_ignore_ascii_case("bearer"))
    })
}

fn required<'a>(doc: &'a Value, key: &str) -> Option<&'a str> {
    doc[key]
        .as_str()
        .filter(|text| !text.is_empty() && text.len() <= 16_384)
}

pub(crate) fn present<'a>(doc: &'a Value, key: &str) -> Option<&'a Value> {
    doc.get(key).filter(|value| !value.is_null())
}

fn expires_in(doc: &Value) -> Option<Option<i64>> {
    match doc.get("expires_in") {
        None => Some(None),
        Some(value) => integer(value)
            .filter(|seconds| (1..=2_592_000).contains(seconds))
            .map(Some),
    }
}

fn expiry(doc: &Value, access: &Claims, now: i64) -> Option<i64> {
    Some(expires_in(doc)?.map_or(access.expires, |seconds| access.expires.min(now + seconds)))
}

fn encoded_pairs(fields: &[(&str, &str)]) -> String {
    fields
        .iter()
        .map(|(key, value)| format!("{key}={}", utf8_percent_encode(value, UNRESERVED)))
        .collect::<Vec<_>>()
        .join("&")
}

fn challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn unreserved(value: &str, minimum: usize) -> bool {
    (minimum..=128).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
}

fn quota_transport(error: TransportError) -> QuotaFailure {
    match error {
        TransportError::Cancelled => QuotaFailure::Closed,
        _ => QuotaFailure::Unavailable,
    }
}

fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}
