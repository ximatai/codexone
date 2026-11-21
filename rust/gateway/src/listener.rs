use std::{
    future::Future,
    io,
    net::{IpAddr, Ipv4Addr},
    num::NonZeroU16,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};

use bytes::{Bytes, BytesMut};
use codexone_config::Network;
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
    gateway::Application,
    reply::{self, FlushDeliveries, Reply},
};

const READ_IDLE: Duration = Duration::from_secs(10);
const DATA_UPLOAD_LIMIT: Duration = Duration::from_secs(120);
const DRAIN_LIMIT: Duration = Duration::from_secs(4);
const DATA_WRITE_IDLE: Duration = Duration::from_secs(5);

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
        let slots = Arc::new(Semaphore::new(max_connections));
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
            connections.spawn(async move {
                let _permit = permit;
                serve_connection(socket, application, plane, draining, Instant::now()).await;
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
    let service = service_fn(move |request| {
        let app = app.clone();
        let pending = pending.clone();
        async move {
            let response = match plane {
                Plane::Data => app.data(request, pending).await,
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
    let mut connection = std::pin::pin!(http.serve_connection(io, service));
    tokio::select! {
        _ = &mut connection => {}
        _ = draining.cancelled() => {
            connection.as_mut().graceful_shutdown();
            let _ = connection.await;
        }
    }
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

#[derive(Clone, Copy)]
pub enum ReadError {
    TooLarge,
    Timeout,
    Interrupted,
    Capacity,
}

pub struct DataBodies(Arc<Semaphore>);

impl DataBodies {
    pub fn new() -> Self {
        Self(Arc::new(Semaphore::new(
            codexone_responses::MAX_REQUEST_BYTES,
        )))
    }

    pub async fn read(&self, body: Incoming) -> Result<(Bytes, OwnedSemaphorePermit), ReadError> {
        use codexone_responses::MAX_REQUEST_BYTES;
        let declared = body
            .size_hint()
            .exact()
            .map(|length| {
                usize::try_from(length)
                    .ok()
                    .filter(|length| *length <= MAX_REQUEST_BYTES)
                    .ok_or(ReadError::TooLarge)
            })
            .transpose()?;
        let mut permit = self.reserve(declared.unwrap_or(0))?;
        let bytes = collect_body(
            body,
            declared.unwrap_or(MAX_REQUEST_BYTES),
            Instant::now() + DATA_UPLOAD_LIMIT,
            |received| {
                if declared.is_none() {
                    permit.merge(self.reserve(received)?);
                }
                Ok(())
            },
        )
        .await?;
        Ok((bytes, permit))
    }

    fn reserve(&self, bytes: usize) -> Result<OwnedSemaphorePermit, ReadError> {
        self.0
            .clone()
            .try_acquire_many_owned(bytes as u32)
            .map_err(|_| ReadError::Capacity)
    }
}

pub async fn read_body(
    body: Incoming,
    maximum: usize,
    deadline: Instant,
) -> Result<Bytes, ReadError> {
    collect_body(body, maximum, deadline, |_| Ok(())).await
}

async fn collect_body(
    mut body: Incoming,
    maximum: usize,
    deadline: Instant,
    mut reserve: impl FnMut(usize) -> Result<(), ReadError>,
) -> Result<Bytes, ReadError> {
    if body.size_hint().lower() > maximum as u64 {
        return Err(ReadError::TooLarge);
    }
    let mut contents = BytesMut::new();
    loop {
        let limit = deadline.min(Instant::now() + READ_IDLE);
        let Some(frame) = timeout_at(limit, body.frame())
            .await
            .map_err(|_| ReadError::Timeout)?
        else {
            return Ok(contents.freeze());
        };
        if let Ok(bytes) = frame.map_err(|_| ReadError::Interrupted)?.into_data() {
            if bytes.len() > maximum - contents.len() {
                return Err(ReadError::TooLarge);
            }
            reserve(bytes.len())?;
            contents.extend_from_slice(&bytes);
        }
    }
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
    ) -> Poll<io::Result<usize>> {
        if self.entire_write || poll.is_pending() {
            let duration = if self.entire_write {
                codexone_admin::RESPONSE_WRITE_DEADLINE
            } else {
                DATA_WRITE_IDLE
            };
            let timer = self
                .deadline
                .get_or_insert_with(|| Box::pin(sleep_until(Instant::now() + duration)));
            if timer.as_mut().poll(context).is_ready() {
                return Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "downstream write timed out",
                )));
            }
        } else {
            self.deadline = None;
        }
        poll
    }
}

impl AsyncRead for DownstreamIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_read(context, buffer)
    }
}

impl AsyncWrite for DownstreamIo {
    fn poll_write(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let poll = Pin::new(&mut self.socket).poll_write(context, data);
        self.write_deadline(context, poll)
    }

    fn poll_flush(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        let poll = Pin::new(&mut self.socket).poll_flush(context);
        let poll = self.write_deadline(context, poll.map_ok(|()| 0));
        if matches!(poll, Poll::Ready(Ok(_))) {
            self.pending.submitted();
        }
        poll.map_ok(|_| ())
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_shutdown(context)
    }
}
