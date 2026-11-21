mod attempt;
mod bridge;
mod ingress;
mod limits;
mod native;

pub use bridge::{BridgeRequest, BridgeResult, forward};
pub use limits::Path as SizePath;
pub use native::{Session, Upgrade};

use std::{sync::Arc, time::Duration};

use codexone_config::ExecutionBudget;
use codexone_http_upstream::HttpUpstream;
use codexone_responses::Contract;
use codexone_websocket::{CancellationToken, ConnectFailure, Socket, UpstreamHandshake};
use http::{HeaderMap, HeaderValue, Uri, header};
use tokio::time::Instant;

#[derive(Clone)]
pub struct Connector {
    http_target: Uri,
    ws_target: Uri,
    transport: HttpUpstream,
    pub contract: Contract,
    authorization: HeaderMap,
    pub diagnostics: Arc<limits::SizeDiagnostics>,
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
            diagnostics: Arc::default(),
        })
    }

    async fn connect(
        &self,
        forwarded: &HeaderMap,
        deadline: Instant,
    ) -> Result<(Socket, HeaderMap), ConnectFailure> {
        let handshake = UpstreamHandshake::new(
            self.ws_target.clone(),
            self.contract,
            forwarded,
            &self.authorization,
        )?;
        handshake
            .connect_over(
                self.transport.connect_stream(&self.http_target),
                deadline,
                &CancellationToken::new(),
            )
            .await
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
