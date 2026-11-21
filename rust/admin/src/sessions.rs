use std::collections::HashMap;
use std::num::NonZeroU16;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use bytes::Bytes;
use codexone_wire::{JsonError, JsonValue};
use http::header::{
    AUTHORIZATION, CONTENT_ENCODING, CONTENT_TYPE, COOKIE, HOST, ORIGIN, SET_COOKIE,
};
use http::{HeaderMap, HeaderValue, Method, Request, Response, StatusCode};
use serde_json::json;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

use super::{AdminAuthorization, Failure, json_response};

const MAX_SESSIONS: usize = 16;
const IDLE_LIFETIME: Duration = Duration::from_secs(24 * 60 * 60);
const ABSOLUTE_LIFETIME: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const SECURE_COOKIE: &str = "__Host-codexone_admin";
const LAN_COOKIE: &str = "codexone_admin";
const ADMIN_USERNAME: &str = "admin";
const FETCH_SITE: &str = "sec-fetch-site";
const CSRF_HEADER: &str = "x-codexone-csrf";

pub(crate) struct Sessions {
    digest: [u8; 32],
    origin: String,
    authority: String,
    loopback_authority: String,
    cookie_name: &'static str,
    entries: Mutex<HashMap<[u8; 32], Session>>,
}

struct Session {
    csrf: String,
    last_activity: Instant,
    absolute_deadline: Instant,
    live_connections: Arc<Semaphore>,
    revoked: CancellationToken,
}

impl Session {
    fn valid_at(&self, now: Instant) -> bool {
        now < self.absolute_deadline && now.duration_since(self.last_activity) < IDLE_LIFETIME
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.revoked.cancel();
    }
}

/// Owns one admitted browser live connection. A session replacement, logout or
/// server revocation cancels the connection without retaining the browser cookie.
pub struct OverviewSession {
    owner: Arc<Sessions>,
    digest: [u8; 32],
    revoked: CancellationToken,
    _permit: OwnedSemaphorePermit,
}

impl OverviewSession {
    pub async fn revoked(&self) {
        self.revoked.cancelled().await;
    }

    pub fn valid(&self) -> bool {
        self.with_valid(false, || ()).is_some()
    }

    /// Serialize admitting a frame to the connection's write buffer with logout
    /// and session replacement. The callback must not await or block on I/O.
    pub fn with_valid<T>(&self, renew_idle: bool, send: impl FnOnce() -> T) -> Option<T> {
        let mut entries = self.owner.entries.lock().expect("admin sessions");
        let now = Instant::now();
        entries.retain(|_, session| session.valid_at(now));
        let session = entries.get_mut(&self.digest)?;
        if renew_idle {
            session.last_activity = now;
        }
        Some(send())
    }
}

pub(crate) struct Renewal {
    cookie_name: &'static str,
    token: Zeroizing<String>,
    csrf: String,
    absolute_deadline: Instant,
}

impl Renewal {
    pub(crate) fn header(self) -> HeaderValue {
        let seconds = self
            .absolute_deadline
            .saturating_duration_since(Instant::now())
            .as_secs();
        cookie_header(self.cookie_name, &self.token, seconds)
    }
}

struct Credentials {
    username_is_admin: bool,
    secret: Zeroizing<String>,
}

impl Sessions {
    pub(crate) fn new(digest: [u8; 32], origin: Option<&str>, port: NonZeroU16) -> Self {
        let loopback_authority = format!("127.0.0.1:{port}");
        let origin = match origin {
            Some(origin) => origin.to_owned(),
            None if port.get() == 80 => "http://127.0.0.1".to_owned(),
            None => format!("http://{loopback_authority}"),
        };
        // Configuration already validates and canonicalizes the scheme and authority.
        let (scheme, authority) = origin.split_once("://").expect("validated admin origin");
        let host = authority.split(':').next().expect("admin authority host");
        let cookie_name = if scheme == "http" && !matches!(host, "127.0.0.1" | "localhost") {
            LAN_COOKIE
        } else {
            SECURE_COOKIE
        };
        Self {
            digest,
            authority: authority.to_owned(),
            origin,
            loopback_authority,
            cookie_name,
            entries: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn lan_http(&self) -> bool {
        self.cookie_name == LAN_COOKIE
    }

    pub(crate) fn route(&self, request: &Request<Bytes>) -> Option<Response<Bytes>> {
        let headers = request.headers();
        let result = match *request.method() {
            Method::POST => Self::decode_login(request)
                .and_then(|credentials| self.login(credentials, headers).map(session_response)),
            Method::GET | Method::HEAD => self.authenticate(headers, false).map(session_response),
            Method::DELETE => self.logout(headers).map(|()| {
                let mut response = json_response(
                    StatusCode::OK,
                    "application/json",
                    &json!({"authenticated": false}),
                );
                response
                    .headers_mut()
                    .insert(SET_COOKIE, cookie_header(self.cookie_name, "", 0));
                response
            }),
            _ => return None,
        };
        Some(result.unwrap_or_else(Failure::response))
    }

    pub(crate) fn authorize(
        &self,
        method: &Method,
        headers: &HeaderMap,
    ) -> Result<AdminAuthorization, Failure> {
        if !headers.contains_key(AUTHORIZATION) {
            return self
                .authenticate(headers, !matches!(*method, Method::GET | Method::HEAD))
                .map(|renewal| AdminAuthorization(Some(renewal)));
        }
        if [ORIGIN, COOKIE]
            .iter()
            .any(|name| headers.contains_key(name))
            || headers.contains_key(FETCH_SITE)
        {
            return Err(Failure::Mixed);
        }
        let secret = single(headers.get_all(AUTHORIZATION).iter())
            .and_then(|header| header.strip_prefix("Bearer "))
            .filter(|secret| {
                (24..=512).contains(&secret.len())
                    && secret.bytes().all(|byte| (33..127).contains(&byte))
                    && !secret.starts_with("co1_")
            })
            .ok_or(Failure::Credential)?;
        if !bool::from(digest(secret).ct_eq(&self.digest)) {
            return Err(Failure::Credential);
        }
        Ok(AdminAuthorization(None))
    }

    fn decode_login(request: &Request<Bytes>) -> Result<Credentials, Failure> {
        let headers = request.headers();
        let json = single(headers.get_all(CONTENT_TYPE).iter()).is_some_and(|value| {
            value
                .get(.."application/json".len())
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case("application/json"))
        });
        if !json || headers.contains_key(CONTENT_ENCODING) {
            return Err(Failure::InvalidCommand);
        }
        let mut document = JsonValue::decode(request.body()).map_err(|error| match error {
            JsonError::TooDeep => Failure::JsonTooDeep,
            JsonError::InvalidJson => Failure::InvalidCommand,
        })?;
        let fields = document.as_object_mut().ok_or(Failure::InvalidCommand)?;
        if !fields
            .iter()
            .all(|(key, _)| matches!(key, "username" | "secret"))
        {
            return Err(Failure::InvalidCommand);
        }
        let Some(JsonValue::String(secret)) = fields.remove("secret") else {
            return Err(Failure::InvalidCommand);
        };
        Ok(Credentials {
            username_is_admin: fields.get("username").and_then(JsonValue::as_str)
                == Some(ADMIN_USERNAME),
            secret: Zeroizing::new(secret),
        })
    }

    fn login(&self, credentials: Credentials, headers: &HeaderMap) -> Result<Renewal, Failure> {
        self.check_browser(headers, true)?;
        if headers.contains_key(AUTHORIZATION)
            || !credentials.username_is_admin
            || !(32..=512).contains(&credentials.secret.len())
            || !bool::from(digest(&credentials.secret).ct_eq(&self.digest))
        {
            return Err(Failure::Credential);
        }

        let token = Zeroizing::new(nonce("as1_")?);
        let csrf = nonce("ac1_")?;
        let token_digest = digest(&token);
        let mut entries = self.entries.lock().expect("admin sessions");
        let now = Instant::now();
        entries.retain(|_, session| session.valid_at(now));
        // An invalid/old cookie is not authentication for login. Replace only a valid token.
        if let Ok(replacing) = self.cookie_token(headers) {
            entries.remove(&digest(replacing));
        }
        if entries.len() >= MAX_SESSIONS {
            return Err(Failure::Unavailable);
        }
        let absolute_deadline = now + ABSOLUTE_LIFETIME;
        entries.insert(
            token_digest,
            Session {
                csrf: csrf.clone(),
                last_activity: now,
                absolute_deadline,
                live_connections: Arc::new(Semaphore::new(2)),
                revoked: CancellationToken::new(),
            },
        );
        Ok(Renewal {
            cookie_name: self.cookie_name,
            token,
            csrf,
            absolute_deadline,
        })
    }

    fn authenticate(&self, headers: &HeaderMap, mutation: bool) -> Result<Renewal, Failure> {
        let token = self.browser_token(headers, mutation)?;
        let mut entries = self.entries.lock().expect("admin sessions");
        let now = Instant::now();
        entries.retain(|_, session| session.valid_at(now));
        let session = entries.get_mut(&digest(token)).ok_or(Failure::Credential)?;
        if mutation {
            Self::check_csrf(headers, session)?;
        }
        session.last_activity = now;
        Ok(Renewal {
            cookie_name: self.cookie_name,
            token: Zeroizing::new(token.to_owned()),
            csrf: session.csrf.clone(),
            absolute_deadline: session.absolute_deadline,
        })
    }

    pub(crate) fn overview(
        self: &Arc<Self>,
        headers: &HeaderMap,
    ) -> Result<OverviewSession, Failure> {
        let digest = digest(self.browser_token(headers, true)?);
        let mut entries = self.entries.lock().expect("admin sessions");
        let now = Instant::now();
        entries.retain(|_, session| session.valid_at(now));
        let session = entries.get_mut(&digest).ok_or(Failure::Credential)?;
        let permit = session
            .live_connections
            .clone()
            .try_acquire_owned()
            .map_err(|_| Failure::OverviewCapacity)?;
        Ok(OverviewSession {
            owner: self.clone(),
            digest,
            revoked: session.revoked.clone(),
            _permit: permit,
        })
    }

    fn logout(&self, headers: &HeaderMap) -> Result<(), Failure> {
        let token_digest = digest(self.browser_token(headers, true)?);
        let mut entries = self.entries.lock().expect("admin sessions");
        let now = Instant::now();
        entries.retain(|_, session| session.valid_at(now));
        let session = entries.get(&token_digest).ok_or(Failure::Credential)?;
        Self::check_csrf(headers, session)?;
        entries.remove(&token_digest);
        Ok(())
    }

    pub(crate) fn revoke_all(&self) {
        self.entries.lock().expect("admin sessions").clear();
    }

    fn check_csrf(headers: &HeaderMap, session: &Session) -> Result<(), Failure> {
        let valid = single(headers.get_all(CSRF_HEADER).iter())
            .is_some_and(|proof| bool::from(proof.as_bytes().ct_eq(session.csrf.as_bytes())));
        if !valid {
            return Err(Failure::Csrf);
        }
        Ok(())
    }

    fn browser_token<'a>(
        &self,
        headers: &'a HeaderMap,
        mutation: bool,
    ) -> Result<&'a str, Failure> {
        self.check_browser(headers, mutation)?;
        if headers.contains_key(AUTHORIZATION) {
            return Err(Failure::Credential);
        }
        self.cookie_token(headers)
    }

    fn check_browser(&self, headers: &HeaderMap, mutation: bool) -> Result<(), Failure> {
        let host_ok = single(headers.get_all(HOST).iter()).is_some_and(|host| {
            host.eq_ignore_ascii_case(&self.authority)
                || host.eq_ignore_ascii_case(&self.loopback_authority)
        });
        if !host_ok {
            return Err(Failure::Host);
        }
        let origin = single(headers.get_all(ORIGIN).iter());
        let origin_ok = if mutation || headers.contains_key(ORIGIN) {
            origin == Some(self.origin.as_str())
        } else {
            true
        };
        let fetch_ok = !headers.contains_key(FETCH_SITE)
            || single(headers.get_all(FETCH_SITE).iter()) == Some("same-origin");
        if !origin_ok || !fetch_ok {
            return Err(Failure::Origin);
        }
        Ok(())
    }

    fn cookie_token<'a>(&self, headers: &'a HeaderMap) -> Result<&'a str, Failure> {
        let cookie = single(headers.get_all(COOKIE).iter())
            .filter(|cookie| cookie.len() <= 4096)
            .ok_or(Failure::Credential)?;
        let mut matches = cookie.split(';').filter_map(|part| {
            let (name, value) = part.trim_matches([' ', '\t']).split_once('=')?;
            (name == self.cookie_name).then_some(value)
        });
        let token = matches.next().ok_or(Failure::Credential)?;
        if matches.next().is_some()
            || token.len() != 47
            || !token.starts_with("as1_")
            || !token
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        {
            return Err(Failure::Credential);
        }
        Ok(token)
    }
}

fn single<'a>(mut headers: impl Iterator<Item = &'a HeaderValue>) -> Option<&'a str> {
    let first = headers.next()?.to_str().ok()?;
    headers.next().is_none().then_some(first)
}

fn digest(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}

fn nonce(prefix: &str) -> Result<String, Failure> {
    let mut entropy = Zeroizing::new([0; 32]);
    getrandom::fill(entropy.as_mut()).map_err(|_| Failure::Unavailable)?;
    let mut result = String::from(prefix);
    URL_SAFE_NO_PAD.encode_string(entropy.as_ref(), &mut result);
    Ok(result)
}

fn cookie_header(name: &str, token: &str, seconds: u64) -> HeaderValue {
    let secure = if name == LAN_COOKIE { "" } else { " Secure;" };
    let value =
        format!("{name}={token}; Path=/; Max-Age={seconds}; HttpOnly;{secure} SameSite=Strict");
    let mut header = HeaderValue::try_from(value).expect("session cookie is ASCII");
    header.set_sensitive(true);
    header
}

fn session_response(renewal: Renewal) -> Response<Bytes> {
    let mut response = json_response(
        StatusCode::OK,
        "application/json",
        &json!({"authenticated": true, "csrf": renewal.csrf}),
    );
    response.headers_mut().insert(SET_COOKIE, renewal.header());
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activity_slides_until_the_exact_idle_or_absolute_boundary() {
        let start = Instant::now();
        let mut session = Session {
            live_connections: Arc::new(Semaphore::new(2)),
            revoked: CancellationToken::new(),
            csrf: "synthetic-proof".into(),
            last_activity: start,
            absolute_deadline: start + ABSOLUTE_LIFETIME,
        };
        assert!(session.valid_at(start + IDLE_LIFETIME - Duration::from_nanos(1)));
        assert!(!session.valid_at(start + IDLE_LIFETIME));

        for hour in (23..168).step_by(12) {
            let now = start + Duration::from_secs(hour * 3600);
            assert!(session.valid_at(now));
            session.last_activity = now;
        }
        assert!(session.valid_at(start + ABSOLUTE_LIFETIME - Duration::from_nanos(1)));
        assert!(!session.valid_at(start + ABSOLUTE_LIFETIME));
    }
}
