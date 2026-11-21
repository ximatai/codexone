mod attempt;
mod bridge;
mod ingress;
mod limits;
mod native;
mod priming;

pub use bridge::{BridgeRequest, BridgeResult, forward};
pub use limits::{Path as SizePath, record_size};
pub use native::{Session, Upgrade};
pub use priming::discard_priming;

use std::{sync::Arc, time::Duration};

use codexone_config::ExecutionBudget;
use codexone_execution::{AccountIdentity, Execution};
use codexone_http_upstream::HttpUpstream;
use codexone_responses::{self as protocol, Contract, JsonValue};
use codexone_websocket::{CancellationToken, ConnectFailure, Socket, UpstreamHandshake};
use http::{HeaderMap, HeaderValue, Uri, header};
use tokio::time::Instant;

use crate::managed::Pool;

#[derive(Clone)]
pub struct Connector {
    http_target: Uri,
    ws_target: Uri,
    transport: HttpUpstream,
    pub contract: Contract,
    authorization: HeaderMap,
}

impl Connector {
    pub fn new(
        http_target: Uri,
        transport: HttpUpstream,
        contract: Contract,
        authorization: Option<HeaderValue>,
    ) -> Result<Self, ()> {
        let mut parts = http_target.clone().into_parts();
        parts.scheme = Some(
            match http_target.scheme_str() {
                Some("http") => "ws",
                Some("https") => "wss",
                _ => return Err(()),
            }
            .parse()
            .map_err(|_| ())?,
        );
        let ws_target = Uri::from_parts(parts).map_err(|_| ())?;
        let mut provider = HeaderMap::new();
        if let Some(value) = authorization {
            provider.insert(header::AUTHORIZATION, value);
        }
        Ok(Self {
            http_target,
            ws_target,
            transport,
            contract,
            authorization: provider,
        })
    }

    pub(crate) async fn connect(
        &self,
        forwarded: &HeaderMap,
        provider: &Provider,
        deadline: Instant,
        stop: &CancellationToken,
    ) -> Result<(Socket, HeaderMap), ConnectFailure> {
        let mut authorization = self.authorization.clone();
        authorization.extend(provider.credentials.clone());
        let handshake = UpstreamHandshake::new(
            self.ws_target.clone(),
            self.contract,
            forwarded,
            &authorization,
        )?;
        let (socket, headers) = handshake
            .connect_over(
                self.transport.connect_stream(&self.http_target),
                deadline,
                stop,
            )
            .await?;
        provider.observe_headers(&headers);
        Ok((socket, headers))
    }
}

#[derive(Clone, Default)]
pub struct Provider {
    pub credentials: HeaderMap,
    ownership: Option<(Arc<Pool>, String, AccountIdentity)>,
}

impl Provider {
    pub fn with_credentials(credentials: HeaderMap) -> Self {
        Self {
            credentials,
            ownership: None,
        }
    }

    pub fn selected(
        pool: Option<&Arc<Pool>>,
        key: String,
        lease: &Execution,
        credentials: HeaderMap,
    ) -> Self {
        let owner = &lease.admission().owner;
        Self {
            credentials,
            ownership: pool.map(|pool| {
                (
                    pool.clone(),
                    key,
                    AccountIdentity {
                        id: owner.identity.clone(),
                        namespace: owner.namespace.clone(),
                    },
                )
            }),
        }
    }

    pub fn observe_headers(&self, headers: &HeaderMap) {
        if let Some((pool, key, owner)) = &self.ownership {
            pool.observe_turn_state(key, owner, headers);
        }
    }

    pub fn observe_event(&self, event: &JsonValue) {
        if let Some((pool, key, owner)) = &self.ownership
            && let Some(token) = protocol::response_metadata_turn_state(event)
        {
            pool.observe_turn_token(key, owner, token);
        }
    }
}

pub fn budget(config: ExecutionBudget, images: bool) -> codexone_websocket::ExecutionBudget {
    let duration = |seconds: u16| Duration::from_secs(seconds.into());
    codexone_websocket::ExecutionBudget {
        total: duration(config.total_seconds),
        first_response: duration(if images {
            config.image_first_response_seconds
        } else {
            config.first_response_seconds
        }),
        idle: duration(config.progress_seconds),
    }
}
