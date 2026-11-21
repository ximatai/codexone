use std::{
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll, ready},
};

use bytes::Bytes;
use futures_core::Stream;
use http_body::{Body, Frame, SizeHint};

use crate::{
    Error,
    deadline::Progress,
    upload_diagnostics::{CompressionTime, UploadDiagnostics},
};

/// Maximum size of one upload frame.
pub const UPLOAD_CHUNK_BYTES: usize = 64 * 1024;

/// An asynchronous request-body producer failed. Contains no payload or private error text.
#[derive(Clone, Copy, Debug)]
pub struct UploadError;

type Chunks = Pin<Box<dyn Stream<Item = Result<Bytes, UploadError>> + Send>>;

/// Owned upload bytes or a one-shot chunk producer.
pub struct RequestBody {
    source: Source,
    diagnostics: Option<UploadDiagnostics>,
}

enum Source {
    Bytes(Bytes),
    Chunks {
        stream: Chunks,
        remaining: Option<u64>,
    },
}

impl Source {
    fn remaining(&self) -> Option<u64> {
        match self {
            Self::Bytes(bytes) => Some(bytes.len() as u64),
            Self::Chunks { remaining, .. } => *remaining,
        }
    }
}

impl RequestBody {
    /// Send bytes with Content-Length, using slices of the same allocation.
    pub fn bytes(bytes: Bytes) -> Self {
        Self {
            source: Source::Bytes(bytes),
            diagnostics: None,
        }
    }

    /// Send an unknown-length body with HTTP/1.1 chunked framing.
    ///
    /// Yield nonempty chunks of at most [UPLOAD_CHUNK_BYTES]. The transport pulls the
    /// stream on demand and drops it on rejection or teardown.
    pub fn chunked(
        chunks: impl Stream<Item = Result<Bytes, UploadError>> + Send + 'static,
    ) -> Self {
        Self::streaming(chunks, None)
    }

    /// Pull one bounded chunk at a time with a declared Content-Length.
    pub fn sized(
        chunks: impl Stream<Item = Result<Bytes, UploadError>> + Send + 'static,
        length: u64,
    ) -> Self {
        Self::streaming(chunks, Some(length))
    }

    fn streaming(
        chunks: impl Stream<Item = Result<Bytes, UploadError>> + Send + 'static,
        remaining: Option<u64>,
    ) -> Self {
        Self {
            source: Source::Chunks {
                stream: Box::pin(chunks),
                remaining,
            },
            diagnostics: None,
        }
    }

    pub fn with_diagnostics(
        mut self,
        plaintext: usize,
        compression: Option<CompressionTime>,
    ) -> Self {
        self.diagnostics = UploadDiagnostics::new(plaintext, compression);
        self
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
pub(crate) struct UploadOwner(Arc<Mutex<Option<RequestBody>>>);

impl UploadOwner {
    pub(crate) fn new(body: RequestBody) -> Self {
        Self(Arc::new(Mutex::new(Some(body))))
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
        let chunk = match &mut body.source {
            Source::Bytes(bytes) if bytes.is_empty() => None,
            Source::Bytes(bytes) => Some(Ok(bytes.split_to(bytes.len().min(UPLOAD_CHUNK_BYTES)))),
            Source::Chunks { stream, remaining } => {
                let chunk = ready!(stream.as_mut().poll_next(cx));
                if let Some(left) = remaining {
                    match &chunk {
                        Some(Ok(bytes)) if bytes.len() as u64 <= *left => {
                            *left -= bytes.len() as u64
                        }
                        None if *left == 0 => {}
                        _ => return Poll::Ready(Some(Err(Error::Upload))),
                    }
                }
                chunk
            }
        };
        let chunk = match chunk {
            Some(Ok(bytes)) if !bytes.is_empty() && bytes.len() <= UPLOAD_CHUNK_BYTES => {
                Some(bytes)
            }
            Some(_) => return Poll::Ready(Some(Err(Error::Upload))),
            None => None,
        };
        // Hyper does not repoll a fixed-length body after the final declared byte.
        let finished = chunk.is_none() || body.source.remaining() == Some(0);
        if let Some(event) = &mut body.diagnostics {
            event.pulled(chunk.as_ref().map_or(0, Bytes::len), finished);
        }
        let completed = if finished { source.take() } else { None };
        drop(source);
        drop(completed);
        self.finished = finished;
        if finished {
            self.progress.uploaded();
        } else {
            self.progress.upload_progress();
        }
        Poll::Ready(chunk.map(|bytes| Ok(Frame::data(bytes))))
    }

    fn is_end_stream(&self) -> bool {
        if self.finished {
            return true;
        }
        if self
            .source
            .0
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|body| body.source.remaining() == Some(0))
        {
            self.progress.uploaded();
            return true;
        }
        false
    }

    fn size_hint(&self) -> SizeHint {
        match self
            .source
            .0
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|body| body.source.remaining())
        {
            Some(remaining) => SizeHint::with_exact(remaining),
            None => SizeHint::default(),
        }
    }
}
