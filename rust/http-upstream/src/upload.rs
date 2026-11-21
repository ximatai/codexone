use std::{
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll, ready},
};

use bytes::Bytes;
use futures_core::Stream;
use http_body::{Body, Frame, SizeHint};

use crate::{Error, deadline::Progress};

/// Maximum size of one upload frame.
pub const UPLOAD_CHUNK_BYTES: usize = 64 * 1024;

/// An asynchronous request-body producer failed. Contains no payload or private error text.
#[derive(Clone, Copy, Debug)]
pub struct UploadError;

type Chunks = Pin<Box<dyn Stream<Item = Result<Bytes, UploadError>> + Send>>;

/// Owned upload bytes or a one-shot chunk producer.
pub struct RequestBody(Source);

enum Source {
    Bytes(Bytes),
    Chunks(Chunks),
}

impl RequestBody {
    /// Send bytes with Content-Length, using slices of the same allocation.
    pub fn bytes(bytes: Bytes) -> Self {
        Self(Source::Bytes(bytes))
    }

    /// Send an unknown-length body with HTTP/1.1 chunked framing.
    ///
    /// Yield nonempty chunks of at most [UPLOAD_CHUNK_BYTES]. The transport pulls the
    /// stream on demand and drops it on rejection or teardown.
    pub fn chunked(
        chunks: impl Stream<Item = Result<Bytes, UploadError>> + Send + 'static,
    ) -> Self {
        Self(Source::Chunks(Box::pin(chunks)))
    }
}

impl Default for RequestBody {
    fn default() -> Self {
        Self::bytes(Bytes::new())
    }
}

pub(crate) struct WireBody {
    source: UploadOwner,
    progress: Progress,
    finished: bool,
}

#[derive(Clone)]
pub(crate) struct UploadOwner(Arc<Mutex<Option<Source>>>);

impl UploadOwner {
    pub(crate) fn new(body: RequestBody) -> Self {
        Self(Arc::new(Mutex::new(Some(body.0))))
    }

    pub(crate) fn wire_body(&self, progress: Progress) -> WireBody {
        WireBody {
            source: self.clone(),
            progress,
            finished: false,
        }
    }

    pub(crate) fn stop(&self) {
        // Leave HTTP response reads active and drop the producer even if writes are stalled.
        let source = self.0.lock().unwrap().take();
        drop(source);
    }
}

impl Body for WireBody {
    type Data = Bytes;
    type Error = Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Error>>> {
        if self.finished {
            return Poll::Ready(None);
        }
        let mut source = self.source.0.lock().unwrap();
        let Some(body) = source.as_mut() else {
            // An early rejection leaves the declared request unfinished while we read
            // the error body. EOF here could turn that response into an HTTP write error.
            return Poll::Pending;
        };
        let (chunk, finished) = match body {
            Source::Bytes(bytes) => {
                let chunk = bytes.split_to(bytes.len().min(UPLOAD_CHUNK_BYTES));
                // The final fixed-length frame completes the upload without a separate EOF pull.
                (Some(Ok(chunk)), bytes.is_empty())
            }
            Source::Chunks(chunks) => {
                let chunk = ready!(chunks.as_mut().poll_next(cx));
                let finished = chunk.is_none();
                (chunk, finished)
            }
        };
        let completed = if finished { source.take() } else { None };
        drop(source);
        drop(completed);
        self.finished = finished;
        if finished {
            self.progress.uploaded();
        } else {
            self.progress.upload_progress();
        }
        Poll::Ready(chunk.map(|result| match result {
            Ok(bytes) if !bytes.is_empty() && bytes.len() <= UPLOAD_CHUNK_BYTES => {
                Ok(Frame::data(bytes))
            }
            _ => Err(Error::Upload),
        }))
    }

    fn is_end_stream(&self) -> bool {
        if self.finished {
            return true;
        }
        if matches!(&*self.source.0.lock().unwrap(), Some(Source::Bytes(bytes)) if bytes.is_empty())
        {
            self.progress.uploaded();
            return true;
        }
        false
    }

    fn size_hint(&self) -> SizeHint {
        match &*self.source.0.lock().unwrap() {
            Some(Source::Bytes(bytes)) => SizeHint::with_exact(bytes.len() as u64),
            _ => SizeHint::default(),
        }
    }
}
