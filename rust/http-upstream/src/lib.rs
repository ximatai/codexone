//! A single-attempt HTTP/1.1 transport for upstream exchanges.
//!
//! The caller owns endpoint selection, request encoding, provider semantics and settlement.

mod connect;
mod deadline;
mod upload;

use std::{fmt, future::pending, sync::Arc, time::Duration};

pub use bytes::Bytes;
pub use connect::Proxy;
pub use http::{HeaderMap, Method, Request, StatusCode, Uri};
pub use tokio::time::Instant;
pub use tokio_rustls::rustls::RootCertStore;
pub use tokio_util::sync::CancellationToken;
pub use upload::{RequestBody, UPLOAD_CHUNK_BYTES, UploadError};

use deadline::Progress;
use http::header::{
    CONNECTION, CONTENT_LENGTH, EXPECT, HOST, PROXY_AUTHORIZATION, TRAILER, TRANSFER_ENCODING,
    UPGRADE,
};
use http_body_util::BodyExt;
use hyper::{body::Incoming, client::conn::http1};
use hyper_util::rt::TokioIo;
use tokio::{
    sync::watch,
    task::JoinHandle,
    time::{sleep_until, timeout},
};
use tokio_rustls::rustls::ClientConfig;
use upload::UploadOwner;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Errors intentionally carry fixed categories and omit addresses, headers, and payloads.
/// Once a request may have been sent, classify a transport failure conservatively.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    InvalidRequest,
    InvalidProxy,
    Connect,
    ConnectTimeout,
    ProxyConnect,
    ProxyAuthenticationRequired,
    Tls,
    Upload,
    Transport,
    ResponseBody,
    ResponseTooLarge,
    Cancelled,
    FirstResponseTimeout,
    ProgressTimeout,
    DeadlineExceeded,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidRequest => "invalid upstream HTTP request",
            Self::InvalidProxy => "invalid upstream HTTP proxy",
            Self::Connect => "upstream connection failed",
            Self::ConnectTimeout => "upstream connection timed out",
            Self::ProxyConnect => "upstream proxy tunnel failed",
            Self::ProxyAuthenticationRequired => "upstream proxy requires authentication",
            Self::Tls => "upstream TLS handshake failed",
            Self::Upload => "upstream request body failed",
            Self::Transport => "upstream HTTP exchange failed before response headers",
            Self::ResponseBody => "upstream response body interrupted",
            Self::ResponseTooLarge => "upstream response body exceeded its limit",
            Self::Cancelled => "upstream HTTP exchange cancelled",
            Self::FirstResponseTimeout => "upstream first response timed out",
            Self::ProgressTimeout => "upstream HTTP progress timed out",
            Self::DeadlineExceeded => "upstream HTTP exchange exceeded its deadline",
        };
        f.write_str(message)
    }
}

impl std::error::Error for Error {}

/// What counts as progress on a successful response.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResponseProgress {
    /// A nonempty body chunk counts. Use for JSON and other ordinary bodies.
    BodyBytes,
    /// The caller marks effective progress after parsing events. Use for SSE.
    Explicit,
}

pub struct ExchangeOptions {
    /// Absolute execution deadline supplied by the caller, including time spent before dispatch.
    pub deadline: Instant,
    pub first_response_timeout: Duration,
    pub upload_idle_timeout: Option<Duration>,
    pub response_idle_timeout: Option<Duration>,
    pub response_progress: ResponseProgress,
    /// Body bytes after HTTP transfer framing, including non-success responses.
    pub max_response_bytes: usize,
    pub cancellation: CancellationToken,
}

impl ExchangeOptions {
    pub fn new(
        deadline: Instant,
        first_response_timeout: Duration,
        max_response_bytes: usize,
    ) -> Self {
        Self {
            deadline,
            first_response_timeout,
            upload_idle_timeout: None,
            response_idle_timeout: None,
            response_progress: ResponseProgress::BodyBytes,
            max_response_bytes,
            cancellation: CancellationToken::new(),
        }
    }
}

/// HTTP/1 transport with a fresh connection for every dispatch.
#[derive(Clone)]
pub struct HttpUpstream {
    proxy: Option<Proxy>,
    tls: Arc<ClientConfig>,
}

impl HttpUpstream {
    pub fn new(proxy: Option<Proxy>) -> Self {
        Self {
            proxy,
            tls: Arc::new(connect::tls_config()),
        }
    }

    /// Use a trusted explicit root store, for example when the platform supplies private CA roots.
    pub fn with_root_certificates(mut self, roots: RootCertStore) -> Self {
        self.tls = Arc::new(connect::tls_config_with_roots(roots));
        self
    }

    /// Dispatch exactly once. The response owns the live connection; use its methods to read or close it.
    pub async fn send(
        &self,
        mut request: Request<RequestBody>,
        options: ExchangeOptions,
    ) -> Result<Response, Error> {
        check_abort(&options)?;
        let uri = request.uri().clone();
        let authority = uri.authority().ok_or(Error::InvalidRequest)?;
        if !matches!(uri.scheme_str(), Some("http" | "https"))
            || authority.host().is_empty()
            || authority.as_str().contains(['@', '%'])
            || (authority.as_str() != authority.host()
                && !matches!(authority.port_u16(), Some(1..=u16::MAX)))
            || request.method() == Method::CONNECT
        {
            return Err(Error::InvalidRequest);
        }

        *request.uri_mut() = uri
            .path_and_query()
            .map_or("/", |path| path.as_str())
            .parse()
            .map_err(|_| Error::InvalidRequest)?;
        let headers = request.headers_mut();
        headers.insert(
            HOST,
            authority
                .as_str()
                .parse()
                .map_err(|_| Error::InvalidRequest)?,
        );
        for header in [
            CONNECTION,
            CONTENT_LENGTH,
            EXPECT,
            PROXY_AUTHORIZATION,
            TRAILER,
            TRANSFER_ENCODING,
            UPGRADE,
        ] {
            headers.remove(header);
        }
        *request.version_mut() = http::Version::HTTP_11;

        let progress = Progress::new(&options);
        progress.upload_progress();
        let io = tokio::select! {
            biased;
            _ = options.cancellation.cancelled() => return Err(Error::Cancelled),
            _ = sleep_until(options.deadline) => return Err(Error::DeadlineExceeded),
            error = progress.wait_for_expiry() => return Err(error),
            io = timeout(CONNECT_TIMEOUT, connect::connect(&uri, self.proxy.as_ref(), self.tls.clone())) => {
                io.map_err(|_| Error::ConnectTimeout)??
            }
        };
        let (mut sender, connection) = http1::Builder::new()
            .max_buf_size(64 * 1024)
            .handshake(TokioIo::new(io))
            .await
            .map_err(|_| Error::Transport)?;
        check_abort(&options)?;

        let (parts, body) = request.into_parts();
        let upload = UploadOwner::new(body);
        let request = Request::from_parts(parts, upload.wire_body(progress.clone()));
        let (failure, mut failures) = watch::channel(None);
        let cancel = options.cancellation.clone();
        let deadline = options.deadline;
        let monitor = progress.clone();
        let driver = Driver(tokio::spawn(async move {
            let error = tokio::select! {
                biased;
                _ = cancel.cancelled() => Error::Cancelled,
                _ = sleep_until(deadline) => Error::DeadlineExceeded,
                error = monitor.wait_for_expiry() => error,
                _ = connection => return,
            };
            failure.send_replace(Some(error));
        }));
        let response = tokio::select! {
            biased;
            error = wait_for_failure(&mut failures) => Err(error),
            result = sender.send_request(request) => result.map_err(|error| classify(error, Error::Transport)),
        };
        let response = match response {
            Ok(response) => response,
            Err(error) => {
                driver.close().await;
                return Err(error);
            }
        };
        let (parts, body) = response.into_parts();
        if !parts.status.is_success() {
            progress.rejected();
            upload.stop();
        }
        Ok(Response {
            status: parts.status,
            headers: parts.headers,
            body,
            options,
            progress,
            failures,
            received: 0,
            driver: Some(driver),
        })
    }
}

impl Default for HttpUpstream {
    fn default() -> Self {
        Self::new(None)
    }
}

/// Owns one live upstream response. Dropping it cancels outstanding connection I/O.
pub struct Response {
    status: StatusCode,
    headers: HeaderMap,
    body: Incoming,
    options: ExchangeOptions,
    progress: Progress,
    failures: watch::Receiver<Option<Error>>,
    received: usize,
    driver: Option<Driver>,
}

impl fmt::Debug for Response {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Response")
            .field("status", &self.status)
            .finish_non_exhaustive()
    }
}

impl Response {
    pub fn status(&self) -> StatusCode {
        self.status
    }

    pub fn headers(&self) -> &HeaderMap {
        &self.headers
    }

    /// Mark an effective SSE event. Callers should exclude comments, empty deltas and heartbeats.
    pub fn mark_response_progress(&mut self) -> Result<(), Error> {
        self.check_deadline()?;
        if self.driver.is_some() && self.status.is_success() {
            self.progress.response_progress();
        }
        Ok(())
    }

    /// Pull the next nonempty body chunk. EOF is HTTP framing evidence; provider completion
    /// must be checked by the caller. On EOF or error, the response stops driving the connection.
    pub async fn next_chunk(&mut self) -> Result<Option<Bytes>, Error> {
        if self.driver.is_none() {
            return Ok(None);
        }
        let result = self.read_chunk().await;
        if !matches!(&result, Ok(Some(_))) {
            self.stop().await;
        }
        result
    }

    /// Collect the remaining body within the exchange's configured byte limit.
    pub async fn collect(mut self) -> Result<Bytes, Error> {
        let mut output = bytes::BytesMut::new();
        while let Some(chunk) = self.next_chunk().await? {
            output.extend_from_slice(&chunk);
        }
        Ok(output.freeze())
    }

    /// Close the exchange and wait for its connection task to leave.
    pub async fn close(mut self) {
        self.stop().await;
    }

    async fn read_chunk(&mut self) -> Result<Option<Bytes>, Error> {
        loop {
            self.check_deadline()?;
            let frame = tokio::select! {
                biased;
                error = wait_for_failure(&mut self.failures) => return Err(error),
                frame = self.body.frame() => frame,
            };
            let Some(frame) = frame else {
                return Ok(None);
            };
            let frame = frame.map_err(|error| classify(error, Error::ResponseBody))?;
            if let Ok(chunk) = frame.into_data() {
                if chunk.is_empty() {
                    continue;
                }
                if chunk.len() > self.options.max_response_bytes - self.received {
                    return Err(Error::ResponseTooLarge);
                }
                self.received += chunk.len();
                if self.status.is_success()
                    && self.options.response_progress == ResponseProgress::BodyBytes
                {
                    self.progress.response_progress();
                }
                return Ok(Some(chunk));
            }
        }
    }

    fn check_deadline(&self) -> Result<(), Error> {
        check_abort(&self.options)?;
        if let Some(error) = (*self.failures.borrow()).or_else(|| self.progress.expired()) {
            return Err(error);
        }
        Ok(())
    }

    async fn stop(&mut self) {
        if let Some(driver) = self.driver.take() {
            driver.close().await;
        }
    }
}

struct Driver(JoinHandle<()>);

impl Driver {
    async fn close(mut self) {
        self.0.abort();
        let _ = (&mut self.0).await;
    }
}

impl Drop for Driver {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn check_abort(options: &ExchangeOptions) -> Result<(), Error> {
    if options.cancellation.is_cancelled() {
        return Err(Error::Cancelled);
    }
    if Instant::now() >= options.deadline {
        return Err(Error::DeadlineExceeded);
    }
    Ok(())
}

async fn wait_for_failure(failures: &mut watch::Receiver<Option<Error>>) -> Error {
    match failures.wait_for(Option::is_some).await {
        Ok(error) => error.expect("the predicate only accepts an error"),
        // A complete HTTP response can still have pending bytes after the driver exits.
        Err(_) => pending().await,
    }
}

fn classify(error: hyper::Error, fallback: Error) -> Error {
    if std::error::Error::source(&error).and_then(|source| source.downcast_ref::<Error>())
        == Some(&Error::Upload)
    {
        Error::Upload
    } else {
        fallback
    }
}
