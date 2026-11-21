use std::sync::Arc;

use http::{Method, Request, Uri, uri::Authority};
use http_body_util::Empty;
use hyper::client::conn::http1;
use hyper_util::rt::TokioIo;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
};
use tokio_rustls::{
    TlsConnector,
    rustls::{ClientConfig, RootCertStore, pki_types::ServerName},
};

use crate::Error;

/// Explicit HTTP proxy address from trusted process configuration.
#[derive(Clone)]
pub struct Proxy(Authority);

impl Proxy {
    pub fn parse(url: &str) -> Result<Self, Error> {
        let authority = url.strip_prefix("http://").ok_or(Error::InvalidProxy)?;
        let authority = authority.strip_suffix('/').unwrap_or(authority);
        if authority.len() > 2048 || authority.contains(['@', '%', '/', '?', '#']) {
            return Err(Error::InvalidProxy);
        }
        let authority: Authority = authority.parse().map_err(|_| Error::InvalidProxy)?;
        match authority.port_u16() {
            Some(1..=u16::MAX) if !authority.host().is_empty() => Ok(Self(authority)),
            _ => Err(Error::InvalidProxy),
        }
    }
}

impl std::fmt::Debug for Proxy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Proxy(redacted)")
    }
}

pub(crate) trait Io: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> Io for T {}

pub(crate) fn tls_config() -> ClientConfig {
    let roots = RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    tls_config_with_roots(roots)
}

pub(crate) fn tls_config_with_roots(roots: RootCertStore) -> ClientConfig {
    ClientConfig::builder_with_provider(Arc::new(
        tokio_rustls::rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("the ring provider supports the default TLS versions")
    .with_root_certificates(roots)
    .with_no_client_auth()
}

pub(crate) async fn connect(
    uri: &Uri,
    proxy: Option<&Proxy>,
    tls: Arc<ClientConfig>,
) -> Result<Box<dyn Io>, Error> {
    let authority = uri.authority().ok_or(Error::InvalidRequest)?;
    let https = uri.scheme_str() == Some("https");
    let port = authority.port_u16().unwrap_or(if https { 443 } else { 80 });
    let (peer, peer_port) = proxy
        .map(|proxy| (host(&proxy.0), proxy.0.port_u16().unwrap()))
        .unwrap_or((host(authority), port));

    let socket = TcpStream::connect((peer, peer_port))
        .await
        .map_err(|_| Error::Connect)?;
    socket.set_nodelay(true).map_err(|_| Error::Connect)?;
    let io: Box<dyn Io> = if proxy.is_some() {
        let target = format!("{}:{port}", authority.host());
        Box::new(tunnel(socket, target).await?)
    } else {
        Box::new(socket)
    };
    if !https {
        return Ok(io);
    }
    let server =
        ServerName::try_from(host(authority).to_owned()).map_err(|_| Error::InvalidRequest)?;
    let tls = TlsConnector::from(tls)
        .connect(server, io)
        .await
        .map_err(|_| Error::Tls)?;
    Ok(Box::new(tls))
}

fn host(authority: &Authority) -> &str {
    let host = authority.host();
    host.strip_prefix('[')
        .and_then(|ipv6| ipv6.strip_suffix(']'))
        .unwrap_or(host)
}

async fn tunnel(
    socket: TcpStream,
    target: String,
) -> Result<TokioIo<hyper::upgrade::Upgraded>, Error> {
    let (mut sender, connection) = http1::Builder::new()
        .max_buf_size(64 * 1024)
        .handshake(TokioIo::new(socket))
        .await
        .map_err(|_| Error::ProxyConnect)?;
    let request = Request::builder()
        .method(Method::CONNECT)
        .uri(&target)
        .header(http::header::HOST, &target)
        .body(Empty::<bytes::Bytes>::new())
        .map_err(|_| Error::InvalidRequest)?;

    let (result, _) = tokio::try_join!(
        async {
            let response = sender
                .send_request(request)
                .await
                .map_err(|_| Error::ProxyConnect)?;
            if response.status() == http::StatusCode::PROXY_AUTHENTICATION_REQUIRED {
                return Err(Error::ProxyAuthenticationRequired);
            }
            if !response.status().is_success() {
                return Err(Error::ProxyConnect);
            }
            hyper::upgrade::on(response)
                .await
                .map_err(|_| Error::ProxyConnect)
        },
        async {
            connection
                .with_upgrades()
                .await
                .map_err(|_| Error::ProxyConnect)
        }
    )?;
    Ok(TokioIo::new(result))
}
