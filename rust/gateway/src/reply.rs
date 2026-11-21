use std::{
    convert::Infallible,
    pin::Pin,
    sync::{Arc, Mutex, OnceLock},
    task::{Context, Poll},
};

use bytes::Bytes;
use codexone_execution::{Execution, Outcome};
use codexone_image_service::DeliveryAbort;
use codexone_responses::{self as protocol, ProtocolError, ProviderFailure};
use codexone_wire::JsonValue;
use futures_util::Stream;
use http::{HeaderMap, HeaderValue, Response, StatusCode, header};
use http_body::{Body, Frame, SizeHint};
use http_body_util::{Full, StreamBody};
use tokio::{sync::oneshot, time::Instant};

pub type ReplyBody = Pin<Box<dyn Body<Data = Bytes, Error = Infallible> + Send>>;
pub type Reply = Response<ReplyBody>;

/// A successful terminal is recorded when Hyper flushes its bytes to the socket.
/// A disconnected or aborted connection drops any pending delivery with its usage intact.
#[derive(Clone, Default)]
pub struct FlushDeliveries(Arc<FlushState>);

#[derive(Default)]
struct FlushState {
    pending: Mutex<Vec<Delivery>>,
    flushed: tokio::sync::Notify,
    image_write: Mutex<Option<ImageWrite>>,
}

impl FlushDeliveries {
    pub fn enqueue(&self, delivery: Delivery) {
        self.0.pending.lock().unwrap().push(delivery);
    }

    pub fn submitted(&self) {
        let image_frame = self
            .0
            .image_write
            .lock()
            .unwrap()
            .as_mut()
            .and_then(|write| write.frame.take());
        if let Some(frame) = image_frame {
            let _ = frame.send(());
        }
        let pending = std::mem::take(&mut *self.0.pending.lock().unwrap());
        if pending.is_empty() {
            return;
        }
        for delivery in pending {
            delivery.submit();
        }
        self.0.flushed.notify_waiters();
    }

    pub fn limit_image_write(
        &self,
        deadline: Option<Instant>,
        abort: Arc<OnceLock<DeliveryAbort>>,
    ) -> ImageWriteGuard {
        let previous = self.0.image_write.lock().unwrap().replace(ImageWrite {
            deadline,
            abort,
            frame: None,
        });
        debug_assert!(previous.is_none());
        ImageWriteGuard(self.0.clone())
    }

    pub fn image_write_deadline(&self) -> Option<Instant> {
        self.0
            .image_write
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|write| write.deadline)
    }

    pub fn abort_image_write(&self, reason: DeliveryAbort) {
        if let Some(write) = self.0.image_write.lock().unwrap().as_ref() {
            let _ = write.abort.set(reason);
        }
    }

    pub async fn wait(&self) {
        loop {
            let flushed = self.0.flushed.notified();
            if self.0.pending.lock().unwrap().is_empty() {
                return;
            }
            flushed.await;
        }
    }
}

struct ImageWrite {
    deadline: Option<Instant>,
    abort: Arc<OnceLock<DeliveryAbort>>,
    frame: Option<oneshot::Sender<()>>,
}

pub struct ImageWriteGuard(Arc<FlushState>);

impl ImageWriteGuard {
    /// Register before returning a head or frame to Hyper. The socket flush acknowledges it.
    pub fn flush_ticket(&self) -> oneshot::Receiver<()> {
        let (send, receive) = oneshot::channel();
        let mut active = self.0.image_write.lock().unwrap();
        let write = active.as_mut().expect("guard owns the active Images write");
        let previous = write.frame.replace(send);
        debug_assert!(previous.is_none());
        receive
    }
}

impl Drop for ImageWriteGuard {
    fn drop(&mut self) {
        self.0.image_write.lock().unwrap().take();
    }
}

pub struct Delivery {
    execution: Option<Execution>,
    outcome: Outcome,
}

impl Delivery {
    pub fn new(execution: Execution, outcome: Outcome) -> Self {
        Self {
            execution: Some(execution),
            outcome,
        }
    }

    fn submit(mut self) {
        if let Some(execution) = self.execution.take() {
            let _ = execution.finish(Some(self.outcome.clone()));
        }
    }
}

impl Drop for Delivery {
    fn drop(&mut self) {
        if let Some(execution) = self.execution.take() {
            let _ = execution.cancel(crate::unix_time());
        }
    }
}

struct TrackedBody {
    body: Full<Bytes>,
    delivery: Option<Delivery>,
    pending: FlushDeliveries,
}

impl Body for TrackedBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        let frame = Pin::new(&mut self.body).poll_frame(context);
        if matches!(frame, Poll::Ready(Some(Ok(_))))
            && let Some(delivery) = self.delivery.take()
        {
            self.pending.enqueue(delivery);
        }
        frame
    }

    fn is_end_stream(&self) -> bool {
        self.body.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.body.size_hint()
    }
}

pub fn from_bytes(response: Response<Bytes>) -> Reply {
    response.map(|body| -> ReplyBody { Box::pin(Full::new(body)) })
}

pub fn json(
    status: StatusCode,
    document: Bytes,
    mut headers: HeaderMap,
    request_id: &str,
    delivery: Option<(Delivery, FlushDeliveries)>,
) -> Reply {
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json; charset=utf-8"),
    );
    let body = Full::new(document);
    let body: ReplyBody = match delivery {
        Some((delivery, pending)) => Box::pin(TrackedBody {
            body,
            delivery: Some(delivery),
            pending,
        }),
        None => Box::pin(body),
    };
    response(status, headers, request_id, body)
}

pub fn sse(
    mut headers: HeaderMap,
    request_id: &str,
    stream: impl Stream<Item = Result<Frame<Bytes>, Infallible>> + Send + 'static,
) -> Reply {
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/event-stream"),
    );
    headers.insert("x-accel-buffering", HeaderValue::from_static("no"));
    response(
        StatusCode::OK,
        headers,
        request_id,
        Box::pin(StreamBody::new(stream)),
    )
}

pub fn error(
    error: ProtocolError,
    provider: Option<&ProviderFailure>,
    request_id: &str,
    mut headers: HeaderMap,
) -> Reply {
    if let Some(retry_after) = provider.and_then(|provider| provider.client_retry_after.as_ref())
        && let Ok(value) = retry_after.parse()
    {
        headers.insert(header::RETRY_AFTER, value);
    }
    let status = StatusCode::from_u16(error.status).expect("valid protocol status");
    let body = protocol::error_envelope(error, provider, request_id);
    json(status, encode(&body), headers, request_id, None)
}

pub fn encode(document: &JsonValue) -> Bytes {
    Bytes::from(document.encode(true))
}

pub fn response(
    status: StatusCode,
    mut headers: HeaderMap,
    request_id: &str,
    body: ReplyBody,
) -> Reply {
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        "x-request-id",
        request_id.parse().expect("request UUID header"),
    );
    let mut response = Response::new(body);
    *response.status_mut() = status;
    *response.headers_mut() = headers;
    response
}
