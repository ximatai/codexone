use std::time::Duration;

use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_responses::{Contract, ProtocolError, ProviderFailure, http_provider_failure};
use http::{HeaderMap, Method, Request, Response, StatusCode, Uri, Version, header};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    time::{Instant, timeout_at},
};
use tokio_tungstenite::{
    WebSocketStream,
    tungstenite::{
        Error, client::IntoClientRequest, handshake::derive_accept_key, protocol::WebSocketConfig,
    },
};

use crate::{CancellationToken, WS_ROUTING_BYTES};

pub trait SocketIo: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> SocketIo for T {}

pub type Socket = WebSocketStream<Box<dyn SocketIo>>;

const INVALID_UPGRADE: ProtocolError = ProtocolError::new(400, "invalid_websocket_upgrade");
const CONNECT_LIMIT: Duration = Duration::from_secs(10);

fn tokens<'a>(headers: &'a HeaderMap, name: &'static str) -> impl Iterator<Item = &'a str> {
    headers
        .get_all(name)
        .into_iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(',').map(str::trim))
}

/// Check explicit upgrade routing. An extension offer is ignored.
pub fn upgrade_response<B>(
    request: &Request<B>,
    websocket_enabled: bool,
) -> Result<Option<Response<()>>, ProtocolError> {
    if !websocket_enabled
        || request.method() != Method::GET
        || !matches!(
            request.uri().path(),
            "/v1/responses" | "/backend-api/codex/responses"
        )
        || !tokens(request.headers(), "upgrade")
            .any(|value| value.eq_ignore_ascii_case("websocket"))
    {
        return Ok(None);
    }
    let headers = request.headers();
    let mut keys = headers.get_all(header::SEC_WEBSOCKET_KEY).iter();
    let key = keys.next().ok_or(INVALID_UPGRADE)?;
    let mut versions = headers.get_all(header::SEC_WEBSOCKET_VERSION).iter();
    if request.version() != Version::HTTP_11
        || keys.next().is_some()
        || versions.next().is_none_or(|version| version != "13")
        || versions.next().is_some()
        || headers.contains_key(header::SEC_WEBSOCKET_PROTOCOL)
        || !tokens(headers, "connection").any(|value| value.eq_ignore_ascii_case("upgrade"))
        || !STANDARD
            .decode(key.as_bytes())
            .is_ok_and(|key| key.len() == 16)
    {
        return Err(INVALID_UPGRADE);
    }
    Ok(Some(
        Response::builder()
            .status(StatusCode::SWITCHING_PROTOCOLS)
            .header(header::UPGRADE, "websocket")
            .header(header::CONNECTION, "upgrade")
            .header(
                header::SEC_WEBSOCKET_ACCEPT,
                derive_accept_key(key.as_bytes()),
            )
            .header("x-codex-websocket-max-message-bytes", WS_ROUTING_BYTES)
            .body(())
            .expect("valid upgrade response"),
    ))
}

pub(crate) fn limits(maximum: usize) -> WebSocketConfig {
    WebSocketConfig::default()
        .max_frame_size(Some(maximum))
        .max_message_size(Some(maximum))
        .read_buffer_size(64 * 1024)
        .write_buffer_size(0)
        .max_write_buffer_size(64 * 1024 * 1024 + 64)
}

#[derive(Debug)]
pub enum ConnectFailure {
    InvalidTarget,
    Cancelled,
    TimedOut,
    Transport,
    TransportSetup(codexone_http_upstream::Error),
    Handshake,
    Rejected(Box<ProviderFailure>),
}

pub struct UpstreamHandshake {
    request: Request<()>,
}

impl UpstreamHandshake {
    /// Accepts an explicit provider WS URL. The application supplies authorized provider headers
    /// independently from the downstream headers selected for forwarding.
    pub fn new(
        target: Uri,
        contract: Contract,
        forwarded: &HeaderMap,
        authorization: &HeaderMap,
    ) -> Result<Self, ConnectFailure> {
        if !matches!(target.scheme_str(), Some("ws" | "wss"))
            || target
                .authority()
                .is_none_or(|authority| authority.as_str().contains('@'))
        {
            return Err(ConnectFailure::InvalidTarget);
        }
        let mut request = target
            .to_string()
            .into_client_request()
            .map_err(|_| ConnectFailure::InvalidTarget)?;
        for (name, value) in forwarded {
            if is_hop_header(name.as_str())
                || tokens(forwarded, "connection")
                    .any(|token| token.eq_ignore_ascii_case(name.as_str()))
                || matches!(
                    name.as_str(),
                    "authorization"
                        | "cookie"
                        | "chatgpt-account-id"
                        | "x-openai-actor-authorization"
                )
                || (contract == Contract::CodexSubscription && name == "x-codex-turn-state")
                || authorization.contains_key(name)
            {
                continue;
            }
            request.headers_mut().append(name, value.clone());
        }
        for (name, value) in authorization {
            if is_hop_header(name.as_str()) {
                return Err(ConnectFailure::InvalidTarget);
            }
            request.headers_mut().append(name, value.clone());
        }
        if contract == Contract::CodexSubscription && !request.headers().contains_key("openai-beta")
        {
            request.headers_mut().insert(
                "openai-beta",
                http::HeaderValue::from_static("responses_websockets=2026-02-06"),
            );
        }
        Ok(Self { request })
    }

    pub fn target(&self) -> &Uri {
        self.request.uri()
    }

    /// Compose with a trusted dialer that returns a WS-ready byte stream, including verified TLS
    /// for wss:// and any configured proxy tunnel. The dialer never receives provider headers.
    pub async fn connect_over<T: SocketIo + 'static>(
        self,
        dial: impl Future<Output = Result<T, codexone_http_upstream::Error>>,
        deadline: Instant,
        cancellation: &CancellationToken,
    ) -> Result<(Socket, HeaderMap), ConnectFailure> {
        let config = Some(limits(codexone_responses::MAX_EVENT_BYTES));
        bounded_connect(deadline, cancellation, async {
            let io = dial.await.map_err(ConnectFailure::TransportSetup)?;
            let (socket, response) = tokio_tungstenite::client_async_with_config(
                self.request,
                Box::new(io) as Box<dyn SocketIo>,
                config,
            )
            .await
            .map_err(handshake_failure)?;
            Ok((socket, checked_headers(response)?))
        })
        .await
    }

    /// Dial directly with verified Web PKI TLS. Use connect_over when an explicit proxy is set.
    pub async fn connect_direct(
        self,
        deadline: Instant,
        cancellation: &CancellationToken,
    ) -> Result<(Socket, HeaderMap), ConnectFailure> {
        bounded_connect(deadline, cancellation, async {
            // Keep the post-handshake stream (including buffered frames) through type erasure.
            let target = self.request.uri();
            let host = target.host().ok_or(ConnectFailure::InvalidTarget)?;
            let host = host.trim_start_matches('[').trim_end_matches(']');
            let secure = target.scheme_str() == Some("wss");
            let port = target.port_u16().unwrap_or(if secure { 443 } else { 80 });
            let io = tokio::net::TcpStream::connect((host, port))
                .await
                .map_err(|_| ConnectFailure::Transport)?;
            io.set_nodelay(true)
                .map_err(|_| ConnectFailure::Transport)?;
            let io = direct_io(io, host, secure).await?;
            let (socket, response) = tokio_tungstenite::client_async_with_config(
                self.request,
                io,
                Some(limits(codexone_responses::MAX_EVENT_BYTES)),
            )
            .await
            .map_err(handshake_failure)?;
            Ok((socket, checked_headers(response)?))
        })
        .await
    }
}

async fn bounded_connect<T>(
    deadline: Instant,
    cancellation: &CancellationToken,
    operation: impl Future<Output = Result<T, ConnectFailure>>,
) -> Result<T, ConnectFailure> {
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => Err(ConnectFailure::Cancelled),
        result = timeout_at(deadline.min(Instant::now() + CONNECT_LIMIT), operation) =>
            result.unwrap_or(Err(ConnectFailure::TimedOut)),
    }
}

fn checked_headers(response: Response<Option<Vec<u8>>>) -> Result<HeaderMap, ConnectFailure> {
    let (parts, _) = response.into_parts();
    if parts.headers.contains_key(header::SEC_WEBSOCKET_EXTENSIONS)
        || parts.headers.contains_key(header::SEC_WEBSOCKET_PROTOCOL)
    {
        return Err(ConnectFailure::Handshake);
    }
    Ok(parts.headers)
}

fn is_hop_header(name: &str) -> bool {
    name.starts_with("sec-websocket-")
        || matches!(
            name,
            "host"
                | "connection"
                | "upgrade"
                | "proxy-connection"
                | "proxy-authorization"
                | "keep-alive"
                | "transfer-encoding"
                | "content-length"
                | "te"
                | "trailer"
        )
}

fn handshake_failure(error: Error) -> ConnectFailure {
    match error {
        Error::Http(response) => {
            let headers = response.headers();
            let retry: Vec<_> = tokens_raw(headers, "retry-after").collect();
            let connection: Vec<_> = tokens_raw(headers, "connection").collect();
            let mut failure =
                http_provider_failure(response.status().as_u16(), None, &retry, &connection, false);
            if failure.protocol.code == "upstream_rejected" {
                failure.protocol = ProtocolError::new(502, "upstream_upgrade_rejected");
            }
            ConnectFailure::Rejected(Box::new(failure))
        }
        Error::Io(_) => ConnectFailure::Transport,
        _ => ConnectFailure::Handshake,
    }
}

fn tokens_raw<'a>(headers: &'a HeaderMap, name: &'static str) -> impl Iterator<Item = &'a str> {
    headers
        .get_all(name)
        .iter()
        .map(|value| value.to_str().unwrap_or(""))
}

async fn direct_io(
    io: tokio::net::TcpStream,
    host: &str,
    secure: bool,
) -> Result<Box<dyn SocketIo>, ConnectFailure> {
    if !secure {
        return Ok(Box::new(io));
    }
    use std::sync::{Arc, OnceLock};
    use tokio_rustls::{
        TlsConnector,
        rustls::{ClientConfig, RootCertStore, crypto::ring, pki_types::ServerName},
    };
    static TLS: OnceLock<Arc<ClientConfig>> = OnceLock::new();
    let config = TLS.get_or_init(|| {
        Arc::new(
            ClientConfig::builder_with_provider(Arc::new(ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("supported TLS versions")
                .with_root_certificates(RootCertStore {
                    roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
                })
                .with_no_client_auth(),
        )
    });
    let name = ServerName::try_from(host.to_owned()).map_err(|_| ConnectFailure::InvalidTarget)?;
    let socket = TlsConnector::from(config.clone())
        .connect(name, io)
        .await
        .map_err(|_| ConnectFailure::TransportSetup(codexone_http_upstream::Error::Tls))?;
    Ok(Box::new(socket))
}
