//! A single-attempt HTTP/1.1 transport for upstream exchanges.
//!
//! The caller owns endpoint selection, request encoding, provider semantics and settlement.

mod connect;
mod deadline;
mod upload;
mod upload_diagnostics;

use std::{fmt, future::pending, sync::Arc, time::Duration};

pub use bytes::Bytes;
pub use connect::Proxy;
pub use http::{HeaderMap, Method, Request, StatusCode, Uri};
pub use tokio::time::Instant;
pub use tokio_rustls::rustls::RootCertStore;
pub use tokio_util::sync::CancellationToken;
pub use upload::{RequestBody, UPLOAD_CHUNK_BYTES, UploadError};
pub use upload_diagnostics::CompressionTime;

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
use upload::{UploadOwner, WireBody};

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

#[derive(Clone)]
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
    #[cfg(feature = "test-support")]
    drivers: DriverProbe,
}

impl HttpUpstream {
    pub fn new(proxy: Option<Proxy>) -> Self {
        Self {
            proxy,
            tls: Arc::new(connect::tls_config()),
            #[cfg(feature = "test-support")]
            drivers: DriverProbe::default(),
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
        request: Request<RequestBody>,
        options: ExchangeOptions,
    ) -> Result<Response, Error> {
        let (response, driver) = self.prepare(request, options).await?.split();
        let driver = Driver(tokio::spawn(driver));
        match response.await {
            Ok(inner) => Ok(Response {
                inner,
                driver: Some(driver),
            }),
            Err(error) => {
                driver.close().await;
                Err(error)
            }
        }
    }

    /// Dispatch once and optionally collect a bounded body. The connection is
    /// driven inline, so dropping the future or returning ends all HTTP I/O.
    /// A body failure is reported separately from failure to receive headers.
    pub async fn send_buffered(
        &self,
        request: Request<RequestBody>,
        options: ExchangeOptions,
        read_body: impl FnOnce(StatusCode, &HeaderMap) -> bool + Send,
    ) -> Result<BufferedResponse, Error> {
        let (response, driver) = self.prepare(request, options).await?.split();
        let read = async {
            let mut response = response.await?;
            let body = if read_body(response.status, &response.headers) {
                response.collect().await.map(Some)
            } else {
                Ok(None)
            };
            Ok(BufferedResponse {
                status: response.status,
                headers: response.headers,
                body,
            })
        };
        tokio::pin!(read);
        // If the driver reaches EOF first, the body may still hold final buffered bytes.
        tokio::select! {
            result = &mut read => result,
            () = driver => read.await,
        }
    }

    #[cfg(feature = "test-support")]
    pub fn driver_probe(&self) -> DriverProbe {
        self.drivers.clone()
    }

    async fn prepare(
        &self,
        mut request: Request<RequestBody>,
        options: ExchangeOptions,
    ) -> Result<Prepared, Error> {
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
        let (sender, connection) = http1::Builder::new()
            .max_buf_size(64 * 1024)
            .handshake(TokioIo::new(io))
            .await
            .map_err(|_| Error::Transport)?;
        check_abort(&options)?;

        let (parts, body) = request.into_parts();
        let upload = UploadOwner::new(body);
        let request = Request::from_parts(parts, upload.wire_body(progress.clone()));
        Ok(Prepared {
            sender,
            connection,
            request,
            options,
            progress,
            upload,
            #[cfg(feature = "test-support")]
            drivers: self.drivers.clone(),
        })
    }
}

type Connection = http1::Connection<TokioIo<Box<dyn connect::Io>>, WireBody>;

struct Prepared {
    sender: http1::SendRequest<WireBody>,
    connection: Connection,
    request: Request<WireBody>,
    options: ExchangeOptions,
    progress: Progress,
    upload: UploadOwner,
    #[cfg(feature = "test-support")]
    drivers: DriverProbe,
}

impl Prepared {
    fn split(
        self,
    ) -> (
        impl Future<Output = Result<ResponseBody, Error>> + Send + 'static,
        impl Future<Output = ()> + Send + 'static,
    ) {
        let Self {
            mut sender,
            connection,
            request,
            options,
            progress,
            upload,
            #[cfg(feature = "test-support")]
            drivers,
        } = self;
        let (failure, mut failures) = watch::channel(None);
        let cancel = options.cancellation.clone();
        let deadline = options.deadline;
        let monitor = progress.clone();
        #[cfg(feature = "test-support")]
        let response_probe = drivers.clone();
        let driver = async move {
            #[cfg(feature = "test-support")]
            let _active = drivers.started();
            let error = tokio::select! {
                biased;
                _ = cancel.cancelled() => Error::Cancelled,
                _ = sleep_until(deadline) => Error::DeadlineExceeded,
                error = monitor.wait_for_expiry() => error,
                _ = connection => return,
            };
            failure.send_replace(Some(error));
        };
        let response = async move {
            let response = tokio::select! {
                biased;
                error = wait_for_failure(&mut failures) => return Err(error),
                result = sender.send_request(request) => result.map_err(|error| classify(error, Error::Transport))?,
            };
            #[cfg(feature = "test-support")]
            response_probe
                .0
                .headers
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let (parts, body) = response.into_parts();
            if !parts.status.is_success() {
                progress.rejected();
                upload.stop();
            }
            Ok(ResponseBody {
                status: parts.status,
                headers: parts.headers,
                body,
                options,
                progress,
                failures,
                received: 0,
            })
        };
        (response, driver)
    }
}

impl Default for HttpUpstream {
    fn default() -> Self {
        Self::new(None)
    }
}

/// Headers and optional body from a completed buffered exchange.
pub struct BufferedResponse {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Result<Option<Bytes>, Error>,
}

/// Owns one live upstream response. Dropping it cancels outstanding connection I/O.
pub struct Response {
    inner: ResponseBody,
    driver: Option<Driver>,
}

struct ResponseBody {
    status: StatusCode,
    headers: HeaderMap,
    body: Incoming,
    options: ExchangeOptions,
    progress: Progress,
    failures: watch::Receiver<Option<Error>>,
    received: usize,
}

impl fmt::Debug for Response {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Response")
            .field("status", &self.inner.status)
            .finish_non_exhaustive()
    }
}

impl Response {
    pub fn status(&self) -> StatusCode {
        self.inner.status
    }

    pub fn headers(&self) -> &HeaderMap {
        &self.inner.headers
    }

    /// Mark an effective SSE event. Callers should exclude comments, empty deltas and heartbeats.
    pub fn mark_response_progress(&mut self) -> Result<(), Error> {
        self.inner.check_deadline()?;
        if self.driver.is_some() && self.inner.status.is_success() {
            self.inner.progress.response_progress();
        }
        Ok(())
    }

    /// Pull the next nonempty body chunk. EOF is HTTP framing evidence; provider completion
    /// must be checked by the caller. On EOF or error, the response stops driving the connection.
    pub async fn next_chunk(&mut self) -> Result<Option<Bytes>, Error> {
        if self.driver.is_none() {
            return Ok(None);
        }
        let result = self.inner.read_chunk().await;
        if !matches!(&result, Ok(Some(_))) {
            self.stop().await;
        }
        result
    }

    /// Collect the remaining body within the exchange's configured byte limit.
    pub async fn collect(mut self) -> Result<Bytes, Error> {
        if self.driver.is_none() {
            return Ok(Bytes::new());
        }
        let result = self.inner.collect().await;
        self.stop().await;
        result
    }

    /// Close the exchange and wait for its connection task to leave.
    pub async fn close(mut self) {
        self.stop().await;
    }

    async fn stop(&mut self) {
        if let Some(driver) = self.driver.take() {
            driver.close().await;
        }
    }
}

impl ResponseBody {
    async fn collect(&mut self) -> Result<Bytes, Error> {
        let mut output = bytes::BytesMut::new();
        while let Some(chunk) = self.read_chunk().await? {
            output.extend_from_slice(&chunk);
        }
        Ok(output.freeze())
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
}

#[cfg(feature = "test-support")]
#[derive(Clone, Default)]
pub struct DriverProbe(Arc<DriverCounts>);

#[cfg(feature = "test-support")]
#[derive(Default)]
struct DriverCounts {
    started: std::sync::atomic::AtomicUsize,
    headers: std::sync::atomic::AtomicUsize,
    exited: std::sync::atomic::AtomicUsize,
}

#[cfg(feature = "test-support")]
impl DriverProbe {
    /// Number of drivers polled and number of driver futures exited or dropped.
    pub fn counts(&self) -> (usize, usize) {
        use std::sync::atomic::Ordering::SeqCst;
        (self.0.started.load(SeqCst), self.0.exited.load(SeqCst))
    }

    pub fn received_headers(&self) -> usize {
        self.0.headers.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn started(&self) -> DriverExit {
        self.0
            .started
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        DriverExit(self.0.clone())
    }
}

#[cfg(feature = "test-support")]
struct DriverExit(Arc<DriverCounts>);

#[cfg(feature = "test-support")]
impl Drop for DriverExit {
    fn drop(&mut self) {
        self.0
            .exited
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
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
    loop {
        let error = *failures.borrow_and_update();
        if let Some(error) = error {
            return error;
        }
        if failures.changed().await.is_err() {
            // A complete HTTP response can still have pending bytes after the driver exits.
            return pending().await;
        }
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
