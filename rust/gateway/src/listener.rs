use std::{
    future::Future,
    io,
    net::{IpAddr, Ipv4Addr},
    num::NonZeroU16,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
    time::Duration,
};

use bytes::{Bytes, BytesMut};
use codexone_config::Network;
use codexone_image_service::DeliveryAbort;
use http::{Request, Response, header};
use http_body::Body;
use http_body_util::BodyExt;
use hyper::{body::Incoming, server::conn::http1, service::service_fn};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::{TcpListener, TcpStream},
    sync::{OwnedSemaphorePermit, Semaphore},
    task::JoinSet,
    time::{Instant, Sleep, sleep_until, timeout, timeout_at},
};
use tokio_util::sync::CancellationToken;

use crate::{
    body_budget::BodyPermit,
    body_staging::{BodyStaging, StageError, StagedBody},
    gateway::Application,
    reply::{self, FlushDeliveries, Reply},
};

pub use crate::body_budget::DataBodies;

const READ_IDLE: Duration = Duration::from_secs(10);
const DATA_UPLOAD_LIMIT: Duration = Duration::from_secs(120);
const DRAIN_LIMIT: Duration = Duration::from_secs(4);
const DATA_WRITE_IDLE: Duration = Duration::from_secs(5);
const DATA_REFUSAL_SLOTS: usize = 16;

#[derive(Clone, Copy)]
pub enum Plane {
    Data,
    Admin,
}

pub struct Listeners {
    name: &'static str,
    loopback: TcpListener,
    additional: Option<TcpListener>,
    pub port: NonZeroU16,
}

impl Listeners {
    pub async fn bind(
        name: &'static str,
        port: u16,
        additional: Option<IpAddr>,
    ) -> io::Result<Self> {
        let loopback = TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await?;
        let port = NonZeroU16::new(loopback.local_addr()?.port()).expect("bound port");
        let additional = match additional {
            Some(address) => Some(TcpListener::bind((address, port.get())).await?),
            None => None,
        };
        Ok(Self {
            name,
            loopback,
            additional,
            port,
        })
    }

    pub fn announce(&self) {
        println!("LISTENING {} 127.0.0.1:{}", self.name, self.port);
    }

    pub async fn serve(
        self,
        app: Arc<Application>,
        plane: Plane,
        allowed: Arc<[Network]>,
        stopping: CancellationToken,
        max_connections: usize,
    ) -> io::Result<()> {
        let Self {
            loopback,
            additional,
            ..
        } = self;
        let data = matches!(plane, Plane::Data);
        let slots = Arc::new(Semaphore::new(max_connections + if data { DATA_REFUSAL_SLOTS } else { 0 }));
        let ordinary = data.then(|| Arc::new(Semaphore::new(max_connections)));
        let draining = CancellationToken::new();
        let mut connections = JoinSet::new();
        let result = loop {
            let accepted = tokio::select! {
                biased;
                _ = stopping.cancelled() => break Ok(()),
                joined = connections.join_next(), if !connections.is_empty() => {
                    if joined.is_some_and(|result| result.is_err()) {
                        break Err(io::Error::other("connection task failed"));
                    }
                    continue;
                }
                accepted = loopback.accept() => accepted.map(|(socket, peer)| (socket, peer, false)),
                accepted = accept_additional(additional.as_ref()) => accepted.map(|(socket, peer)| (socket, peer, true)),
            };
            let (socket, peer, restrict) = match accepted {
                Ok(connection) => connection,
                Err(error) if error.kind() == io::ErrorKind::ConnectionAborted => continue,
                Err(error) => break Err(error),
            };
            if restrict && !allowed.iter().any(|network| network.contains(peer.ip())) {
                continue;
            }
            let Ok(permit) = slots.clone().try_acquire_owned() else {
                continue;
            };
            let application = app.clone();
            let draining = draining.clone();
            let ordinary = ordinary.clone();
            connections.spawn(async move {
                let _permit = permit;
                serve_connection(
                    socket,
                    application,
                    plane,
                    draining,
                    Instant::now(),
                    ordinary,
                )
                .await;
            });
        };
        drop(loopback);
        drop(additional);
        draining.cancel();
        if timeout(DRAIN_LIMIT, async {
            while connections.join_next().await.is_some() {}
        })
        .await
        .is_err()
        {
            connections.shutdown().await;
        }
        result
    }
}

async fn accept_additional(
    listener: Option<&TcpListener>,
) -> io::Result<(TcpStream, std::net::SocketAddr)> {
    match listener {
        Some(listener) => listener.accept().await,
        None => std::future::pending().await,
    }
}

async fn serve_connection(
    socket: TcpStream,
    app: Arc<Application>,
    plane: Plane,
    draining: CancellationToken,
    accepted: Instant,
    ordinary: Option<Arc<Semaphore>>,
) {
    let _ = socket.set_nodelay(true);
    let admin = matches!(plane, Plane::Admin);
    let pending = FlushDeliveries::default();
    let io = TokioIo::new(DownstreamIo {
        socket,
        pending: pending.clone(),
        deadline: None,
        entire_write: admin,
    });
    let (upgrades, mut upgraded) = tokio::sync::mpsc::channel(1);
    let connection_slot = Arc::new(Mutex::new(None::<OwnedSemaphorePermit>));
    let reservation = connection_slot.clone();
    let service = service_fn(move |request: Request<Incoming>| {
        let ordinary_capacity = ordinary.as_ref().is_none_or(|slots| {
            if crate::control::Route::recognize(request.method(), request.uri().path()).is_some() {
                return true;
            }
            let mut lease = reservation.lock().unwrap();
            if lease.is_none() {
                *lease = slots.clone().try_acquire_owned().ok();
            }
            lease.is_some()
        });
        let app = app.clone();
        let pending = pending.clone();
        let upgrades = upgrades.clone();
        async move {
            if !ordinary_capacity {
                let response = Response::builder()
                    .status(503)
                    .header(header::CONNECTION, "close")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Bytes::from_static(br#"{"error":{"message":"Data connection capacity exhausted.","type":"server_error","code":"capacity_exceeded"}}"#))
                    .expect("connection capacity response");
                return Ok(reply::from_bytes(response));
            }
            let response = match plane {
                Plane::Data => app.data(request, pending, &upgrades).await,
                Plane::Admin => admin_response(&app, request, accepted).await,
            };
            Ok::<_, std::convert::Infallible>(response)
        }
    });
    let mut http = http1::Builder::new();
    http.timer(TokioTimer::new())
        .header_read_timeout(READ_IDLE)
        .keep_alive(!admin)
        .max_headers(if admin { 32 } else { 64 })
        .max_buf_size(if admin { 8 * 1024 } else { 64 * 1024 })
        .auto_date_header(false);
    let mut connection = std::pin::pin!(http.serve_connection(io, service).with_upgrades());
    tokio::select! {
        _ = &mut connection => {}
        _ = draining.cancelled() => {
            connection.as_mut().graceful_shutdown();
            let _ = connection.await;
        }
    }
    if let Ok(upgrade) = upgraded.try_recv() {
        upgrade.serve(&draining).await;
    }
    drop(connection_slot);
}

async fn admin_response(app: &Application, request: Request<Incoming>, accepted: Instant) -> Reply {
    use codexone_admin::{MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, REQUEST_READ_DEADLINE};
    let (parts, body) = request.into_parts();
    let collected = read_body(body, MAX_REQUEST_BYTES, accepted + REQUEST_READ_DEADLINE).await;
    let mut response = match collected {
        Ok(body) => app.admin(&Request::from_parts(parts, body)).await,
        Err(ReadError::TooLarge) => codexone_admin::request_too_large(),
        Err(_) => Response::builder()
            .status(408)
            .body(Bytes::new())
            .expect("admin timeout"),
    };
    if response.body().len() > MAX_RESPONSE_BYTES {
        response = Response::builder()
            .status(503)
            .body(Bytes::new())
            .expect("admin limit");
    }
    response
        .headers_mut()
        .insert(header::CONNECTION, http::HeaderValue::from_static("close"));
    reply::from_bytes(response)
}

#[derive(Clone, Copy, Debug)]
pub enum ReadError {
    TooLarge,
    Timeout,
    Interrupted,
    Capacity,
}

impl DataBodies {
    pub async fn read(
        &self,
        body: Incoming,
        key: Option<&str>,
        request_id: &str,
    ) -> Result<(Bytes, BodyPermit), ReadError> {
        self.read_with_limit(
            body,
            key,
            request_id,
            codexone_responses::MAX_REQUEST_BYTES,
            false,
        )
        .await
    }

    pub async fn read_control(
        &self,
        body: Incoming,
        key: &str,
        request_id: &str,
        limit: usize,
    ) -> Result<(Bytes, BodyPermit), ReadError> {
        self.read_with_limit(body, Some(key), request_id, limit, true)
            .await
    }

    async fn read_with_limit(
        &self,
        mut body: Incoming,
        key: Option<&str>,
        request_id: &str,
        maximum: usize,
        shared_only: bool,
    ) -> Result<(Bytes, BodyPermit), ReadError> {
        let declared = body
            .size_hint()
            .exact()
            .map(|length| {
                usize::try_from(length)
                    .ok()
                    .filter(|length| *length <= maximum)
                    .ok_or(ReadError::TooLarge)
            })
            .transpose()?;
        let deadline = Instant::now() + DATA_UPLOAD_LIMIT;
        let reservation =
            self.reserve_http_with_pool(declared.unwrap_or(0), key, deadline, shared_only);
        tokio::pin!(reservation);
        let mut prefetched = None;
        let mut permit = if declared.is_some_and(|length| length > 0) {
            // Hyper polls the socket for an incomplete body when its receiver
            // requests a frame. Keep one bounded frame so an abandoned upload
            // can release its waiting ticket before the capacity timeout.
            tokio::select! {
                biased;
                permit = &mut reservation => permit?,
                frame = body.frame() => {
                    prefetched = Some(frame.ok_or(ReadError::Interrupted)?
                        .map_err(|_| ReadError::Interrupted)?);
                    reservation.await?
                }
            }
        } else {
            reservation.await?
        };
        let bytes = collect_body(
            body,
            declared.unwrap_or(maximum),
            deadline,
            Some(request_id),
            prefetched,
            |received| {
                if declared.is_none() {
                    self.grow_with_pool(&mut permit, received, shared_only)?;
                }
                Ok(())
            },
        )
        .await?;
        Ok((bytes, permit))
    }
}

pub(crate) enum StagedReadError {
    Read(ReadError),
    Stage(StageError),
}

impl From<StageError> for StagedReadError {
    fn from(error: StageError) -> Self {
        Self::Stage(error)
    }
}

pub(crate) async fn read_staged(
    mut body: Incoming,
    stage: &BodyStaging,
    length: usize,
    request_id: &str,
) -> Result<StagedBody, StagedReadError> {
    use StagedReadError::Read;
    if length > codexone_responses::MAX_REQUEST_BYTES {
        return Err(Read(ReadError::TooLarge));
    }
    let deadline = Instant::now() + DATA_UPLOAD_LIMIT;
    let mut writer = timeout_at(deadline, stage.begin(length))
        .await
        .map_err(|_| Read(ReadError::Timeout))??;
    let mut received = 0;
    while let Some(frame) = data_frame(&mut body, deadline, Some(request_id), received)
        .await
        .map_err(Read)?
    {
        if let Ok(mut bytes) = frame.into_data() {
            if bytes.len() > length - received {
                return Err(Read(ReadError::TooLarge));
            }
            received += bytes.len();
            while !bytes.is_empty() {
                let chunk =
                    bytes.split_to(bytes.len().min(codexone_http_upstream::UPLOAD_CHUNK_BYTES));
                writer = timeout_at(deadline, writer.append(chunk))
                    .await
                    .map_err(|_| Read(ReadError::Timeout))??;
            }
        }
    }
    timeout_at(deadline, writer.seal())
        .await
        .map_err(|_| Read(ReadError::Timeout))?
        .map_err(Into::into)
}

async fn data_frame(
    body: &mut Incoming,
    deadline: Instant,
    request_id: Option<&str>,
    received: usize,
) -> Result<Option<http_body::Frame<Bytes>>, ReadError> {
    let limit = deadline.min(Instant::now() + READ_IDLE);
    timeout_at(limit, body.frame())
        .await
        .map_err(|_| {
            if let Some(request_id) = request_id {
                record_upload_timeout(request_id, received, limit == deadline);
            }
            ReadError::Timeout
        })?
        .transpose()
        .map_err(|_| ReadError::Interrupted)
}

pub async fn read_body(
    body: Incoming,
    maximum: usize,
    deadline: Instant,
) -> Result<Bytes, ReadError> {
    collect_body(body, maximum, deadline, None, None, |_| Ok(())).await
}

async fn collect_body(
    mut body: Incoming,
    maximum: usize,
    deadline: Instant,
    request_id: Option<&str>,
    mut prefetched: Option<http_body::Frame<Bytes>>,
    mut reserve: impl FnMut(usize) -> Result<(), ReadError>,
) -> Result<Bytes, ReadError> {
    if body.size_hint().lower() > maximum as u64 {
        return Err(ReadError::TooLarge);
    }
    let mut contents = BytesMut::new();
    loop {
        let frame = if let Some(frame) = prefetched.take() {
            Some(frame)
        } else {
            data_frame(&mut body, deadline, request_id, contents.len()).await?
        };
        let Some(frame) = frame else {
            return Ok(contents.freeze());
        };
        if let Ok(bytes) = frame.into_data() {
            if bytes.len() > maximum - contents.len() {
                return Err(ReadError::TooLarge);
            }
            reserve(contents.len() + bytes.len())?;
            contents.extend_from_slice(&bytes);
        }
    }
}

fn record_upload_timeout(request_id: &str, received: usize, total: bool) {
    use std::time::Instant as Monotonic;
    static LIMIT: Mutex<Option<(Monotonic, u8)>> = Mutex::new(None);
    let now = Monotonic::now();
    let mut gate = LIMIT
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (window, count) = gate.get_or_insert((now, 0));
    if now.duration_since(*window) >= Duration::from_secs(60) {
        (*window, *count) = (now, 0);
    }
    if *count >= 16 {
        return;
    }
    *count += 1;
    drop(gate);
    let mib = 1024 * 1024;
    let bucket = if received <= 16 * mib {
        "at_most_16_mib"
    } else if received <= 24 * mib {
        "16_to_24_mib"
    } else if received <= 32 * mib {
        "24_to_32_mib"
    } else {
        "over_32_mib"
    };
    let reason = if total { "total" } else { "idle" };
    eprintln!(
        "Request body read timed out request_id={request_id} timeout_reason={reason} received_size_bucket={bucket} body_started={}",
        received > 0
    );
}

struct DownstreamIo {
    socket: TcpStream,
    pending: FlushDeliveries,
    deadline: Option<Pin<Box<Sleep>>>,
    entire_write: bool,
}

impl DownstreamIo {
    fn write_deadline(
        &mut self,
        context: &mut Context<'_>,
        poll: Poll<io::Result<usize>>,
        image_limit: Option<Instant>,
    ) -> Poll<io::Result<usize>> {
        if matches!(&poll, Poll::Ready(Err(_))) {
            self.pending.abort_image_write(DeliveryAbort::Disconnected);
            return poll;
        }
        if self.entire_write || poll.is_pending() {
            let duration = if self.entire_write {
                codexone_admin::RESPONSE_WRITE_DEADLINE
            } else {
                DATA_WRITE_IDLE
            };
            let timer = self.deadline.get_or_insert_with(|| {
                let idle = Instant::now() + duration;
                Box::pin(sleep_until(
                    image_limit.map_or(idle, |limit| limit.min(idle)),
                ))
            });
            if timer.as_mut().poll(context).is_ready() {
                return Poll::Ready(Err(self.timed_out()));
            }
        } else {
            self.deadline = None;
        }
        poll
    }

    fn image_write_limit(&self) -> io::Result<Option<Instant>> {
        let deadline = self.pending.image_write_deadline();
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            return Err(self.timed_out());
        }
        Ok(deadline)
    }

    fn timed_out(&self) -> io::Error {
        self.pending.abort_image_write(DeliveryAbort::WriteTimeout);
        io::Error::new(io::ErrorKind::TimedOut, "downstream write timed out")
    }
}

impl AsyncRead for DownstreamIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buffer.filled().len();
        let remaining = buffer.remaining();
        let result = Pin::new(&mut self.socket).poll_read(context, buffer);
        if matches!(&result, Poll::Ready(Err(_)))
            || (remaining > 0 && result.is_ready() && buffer.filled().len() == before)
        {
            self.pending.abort_image_write(DeliveryAbort::Disconnected);
        }
        result
    }
}

impl AsyncWrite for DownstreamIo {
    fn poll_write(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let image_limit = self.image_write_limit()?;
        let poll = Pin::new(&mut self.socket).poll_write(context, data);
        self.write_deadline(context, poll, image_limit)
    }

    fn poll_flush(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        let image_limit = self.image_write_limit()?;
        let poll = Pin::new(&mut self.socket).poll_flush(context);
        let poll = self.write_deadline(context, poll.map_ok(|()| 0), image_limit);
        if matches!(poll, Poll::Ready(Ok(_))) {
            self.pending.submitted();
        }
        poll.map_ok(|_| ())
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_shutdown(context)
    }
}
