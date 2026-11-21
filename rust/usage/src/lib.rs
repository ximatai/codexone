//! Read-only management usage reports for the v19 ledger.

mod attention;
mod clients;
pub use clients::{DataClient, DataClients};
mod history;
mod overview;
mod query;
mod reader;
mod sql;
mod summary;

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    sync::Arc,
};

use bytes::Bytes;
use http::{Method, Request, Response, StatusCode, header};
use rusqlite::ErrorCode;
use serde::Serialize;
use serde_json::{Value, json};
use uuid::Uuid;

pub use overview::{OverviewSection, OverviewSource, OverviewStamp, OverviewState};
use query::{Query, boolean, number, parameters};
pub use reader::Reader;

const DAY: i64 = 86_400;
const MAX_RESPONSE_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Invalid,
    Capacity,
    Unavailable,
}
pub type Result<T> = std::result::Result<T, Error>;

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        match error.sqlite_error_code() {
            Some(
                ErrorCode::OperationInterrupted
                | ErrorCode::DatabaseBusy
                | ErrorCode::DatabaseLocked,
            ) => Self::Capacity,
            _ => Self::Unavailable,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct BusinessDay(i32);

impl BusinessDay {
    pub fn new(offset_minutes: i32) -> Result<Self> {
        if !(-720..=840).contains(&offset_minutes) || offset_minutes % 60 != 0 {
            return Err(Error::Invalid);
        }
        Ok(Self(offset_minutes))
    }

    fn seconds(self) -> i64 {
        i64::from(self.0) * 60
    }

    fn start(self, now: i64) -> i64 {
        (now + self.seconds()).div_euclid(DAY) * DAY - self.seconds()
    }

    fn timezone(self) -> String {
        match self.0 {
            0 => "UTC".into(),
            minutes => format!("UTC{:+03}:00", minutes / 60),
        }
    }

    fn document(self) -> Value {
        json!({"offsetMinutes": self.0})
    }
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientActivity {
    #[serde(rename = "keyID")]
    pub key_id: String,
    pub display_name: Option<String>,
    pub count: u32,
    pub connected_at_unix_seconds: i64,
}

#[derive(Clone, Default)]
pub struct ProtocolExtensions {
    pub names: BTreeMap<String, i64>,
    pub overflow: bool,
}

/// Current non-ledger observations supplied by the gateway. Callers can share an
/// immutable context across the sampler and HTTP requests.
#[derive(Clone)]
pub struct Context {
    pub default_reasoning_efforts: BTreeMap<String, String>,
    pub first_events: HashMap<String, bool>,
    pub clients: Vec<ClientActivity>,
    pub activity_overflow: u64,
    pub protocol_extensions: ProtocolExtensions,
    /// Later samples are known to have settled in this process.
    pub live_output_after: Option<i64>,
    /// Settlements observed after commit, including ones that share a second with history.
    pub live_output_attempts: HashSet<String>,
    pub daily_requests: Option<i64>,
    pub daily_budget_micros: Option<i64>,
    pub storage: Value,
    pub stop_available_bytes: i64,
    pub stop_wal_bytes: i64,
}

impl Default for Context {
    fn default() -> Self {
        Self {
            default_reasoning_efforts: BTreeMap::new(),
            first_events: HashMap::new(),
            clients: Vec::new(),
            activity_overflow: 0,
            protocol_extensions: ProtocolExtensions::default(),
            live_output_after: None,
            live_output_attempts: HashSet::new(),
            daily_requests: None,
            daily_budget_micros: None,
            storage: json!({"pressure": "unknown"}),
            stop_available_bytes: 128 * 1024 * 1024,
            stop_wal_bytes: 128 * 1024 * 1024,
        }
    }
}

#[derive(Clone)]
pub struct Usage {
    reader: Reader,
    day: BusinessDay,
}

#[derive(Clone, Copy)]
enum Endpoint {
    History,
    Daily,
    InFlight,
    Options,
    Keys,
    Headroom,
    Attention,
}

impl Endpoint {
    fn at(path: &str) -> Option<Self> {
        Some(match path.trim_end_matches('/') {
            "/api/usage" => Self::History,
            "/api/usage/daily" => Self::Daily,
            "/api/usage/in-flight" => Self::InFlight,
            "/api/usage/options" => Self::Options,
            "/api/usage/keys" => Self::Keys,
            "/api/usage/headroom" => Self::Headroom,
            "/api/attention" => Self::Attention,
            _ => return None,
        })
    }
}

impl Usage {
    pub fn new(reader: Reader, day: BusinessDay) -> Self {
        Self { reader, day }
    }

    pub fn matches(method: &Method, path: &str) -> bool {
        method == Method::GET && Endpoint::at(path).is_some()
    }

    /// Dispatch only after the existing management router authorizes the request.
    /// Apply the session renewal to the returned response at the call site.
    pub async fn route(
        &self,
        request: &Request<Bytes>,
        now: i64,
        context: Arc<Context>,
    ) -> Option<Response<Bytes>> {
        if !Self::matches(request.method(), request.uri().path()) {
            return None;
        }
        let endpoint = Endpoint::at(request.uri().path())?;
        Some(response(
            self.document(endpoint, request.uri().query(), now, context)
                .await,
            match endpoint {
                Endpoint::Options => None,
                Endpoint::Attention => Some("attention_query_capacity"),
                _ => Some("usage_query_capacity"),
            },
        ))
    }

    async fn document(
        &self,
        endpoint: Endpoint,
        raw: Option<&str>,
        now: i64,
        context: Arc<Context>,
    ) -> Result<Value> {
        validate_now(now)?;
        let day = self.day;
        match endpoint {
            Endpoint::History => {
                let query = Query::parse(raw)?;
                self.reader
                    .read(move |db| history::report(db, &query, day, now))
                    .await
            }
            Endpoint::Daily => {
                let mut values = parameters(raw, &["days", "end", "key", "model"])?;
                let query = daily_query(
                    day,
                    now,
                    number(&values, "days")?.unwrap_or(7),
                    number(&values, "end")?,
                    values.remove("key"),
                    values.remove("model"),
                )?;
                self.reader
                    .read(move |db| summary::daily(db, &query, day, now))
                    .await
            }
            Endpoint::InFlight => {
                let values = parameters(raw, &["limit"])?;
                let limit = number(&values, "limit")?.unwrap_or(200);
                if !(1..=200).contains(&limit) {
                    return Err(Error::Invalid);
                }
                self.reader
                    .read(move |db| summary::in_flight(db, now, limit, &context.first_events))
                    .await
            }
            Endpoint::Options => {
                if raw.is_some() {
                    return Err(Error::Invalid);
                }
                self.reader
                    .read(move |db| summary::options(db, day, &context.default_reasoning_efforts))
                    .await
            }
            Endpoint::Keys => {
                let include_archived = boolean(
                    &parameters(raw, &["includeArchived"])?,
                    "includeArchived",
                    true,
                )?;
                self.reader
                    .read(move |db| summary::keys(db, now, day, include_archived))
                    .await
            }
            Endpoint::Attention => {
                if raw.is_some() {
                    return Err(Error::Invalid);
                }
                self.attention(now, context).await
            }
            Endpoint::Headroom => {
                if raw.is_some() {
                    return Err(Error::Invalid);
                }
                self.reader
                    .read(move |db| summary::headroom(db, now, day, &context))
                    .await
            }
        }
    }

    pub async fn close(&self) -> Result<()> {
        self.reader.close().await
    }
}

fn validate_now(now: i64) -> Result<()> {
    if !(0..=1_000_000_000_000).contains(&now) {
        Err(Error::Invalid)
    } else {
        Ok(())
    }
}

fn daily_query(
    day: BusinessDay,
    now: i64,
    days: i64,
    end: Option<i64>,
    key: Option<String>,
    model: Option<String>,
) -> Result<Query> {
    let end = end.unwrap_or_else(|| day.start(now) + DAY);
    if !(1..=31).contains(&days) || !(0..=1_000_000_000_000).contains(&end) || day.start(end) != end
    {
        return Err(Error::Invalid);
    }
    Query::window(end - days * DAY, end, key, model)
}

fn response(result: Result<Value>, capacity_code: Option<&'static str>) -> Response<Bytes> {
    let result = result.and_then(|value| {
        let bytes = serde_json::to_vec(&value).map_err(|_| Error::Unavailable)?;
        if bytes.len() > MAX_RESPONSE_BYTES {
            return Err(Error::Capacity);
        }
        Ok(bytes)
    });
    let (status, body) = match result {
        Ok(body) => (StatusCode::OK, body),
        Err(error) => {
            let (status, code) = match error {
                Error::Invalid => (StatusCode::BAD_REQUEST, "invalid_command"),
                Error::Capacity if capacity_code.is_some() => {
                    (StatusCode::TOO_MANY_REQUESTS, capacity_code.unwrap())
                }
                _ => (StatusCode::SERVICE_UNAVAILABLE, "management_unavailable"),
            };
            (status, json!({"error": {
                "code": code, "message": "Management request failed.", "request_id": Uuid::new_v4().to_string(),
            }}).to_string().into_bytes())
        }
    };
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::CACHE_CONTROL, "no-store")
        .header(header::CONNECTION, "close")
        .body(Bytes::from(body))
        .expect("static management response headers")
}
