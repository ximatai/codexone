use std::{io, sync::Arc, time::Instant};

use bytes::{Buf, Bytes};
use codexone_http_upstream::{
    self as upstream, CompressionTime, RequestBody, UPLOAD_CHUNK_BYTES, UploadError,
};
use http::{Request, StatusCode, header};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::{CancellationToken, DropGuard};
use zstd::stream::raw::{CParameter, Encoder, Operation, OutBuffer};

use crate::{body_staging::StagedBody, upload_workers::UploadWorkers};

/// Each permit reserves up to 5 MiB of encoder workspace and I/O buffers.
pub(crate) struct HttpUploads {
    workers: UploadWorkers,
    workspace: Arc<Semaphore>,
}

impl HttpUploads {
    pub(crate) fn new() -> io::Result<Self> {
        Ok(Self {
            workers: UploadWorkers::new("http-upload-zstd")?,
            workspace: Arc::new(Semaphore::new(4)),
        })
    }

    pub(crate) async fn send(
        self: &Arc<Self>,
        upstream: &upstream::HttpUpstream,
        request: Request<Payload>,
        options: upstream::ExchangeOptions,
        zstd_minimum: Option<u64>,
    ) -> Result<upstream::Response, upstream::Error> {
        let (mut parts, payload) = request.into_parts();
        parts.headers.remove(header::CONTENT_ENCODING);
        let compression = zstd_minimum
            .filter(|&minimum| payload.len() as u64 > minimum)
            .and_then(|_| self.workspace.clone().try_acquire_owned().ok());
        if let Some(permit) = compression {
            let released = CancellationToken::new();
            let workspace = Workspace {
                _permit: permit,
                _released: released.clone().drop_guard(),
            };
            let mut compressed =
                Request::from_parts(parts.clone(), self.compressed(payload.clone(), workspace));
            compressed.headers_mut().insert(
                header::CONTENT_ENCODING,
                http::HeaderValue::from_static("zstd"),
            );
            let result = upstream.send(compressed, options.clone()).await;
            if !result
                .as_ref()
                .is_ok_and(|response| response.status().is_success())
            {
                // Rejection or transport failure drops the producer. A worker
                // still owns its workspace until that last bounded job returns.
                released.cancelled().await;
            }
            let response = result?;
            if response.status() != StatusCode::UNSUPPORTED_MEDIA_TYPE {
                return Ok(response);
            }
            // The rejected exchange owns its socket. Stop it before negotiating
            // once using these same bytes, headers, admission and absolute deadline.
            response.close().await;
        }
        upstream
            .send(Request::from_parts(parts, payload.plain()), options)
            .await
    }

    fn compressed(self: &Arc<Self>, payload: Payload, workspace: Workspace) -> RequestBody {
        let uploads = self.clone();
        let time = CompressionTime::default();
        let clock = time.clone();
        let length = payload.len();
        let chunks = async_stream::try_stream! {
            let mut offset = 0;
            let mut step = CompressionStep { encoder: None, input: Bytes::new(), _workspace: workspace };
            loop {
                if step.input.is_empty() && offset < length {
                    step.input = payload.block(offset).await?;
                    offset += step.input.len();
                }
                let end = step.input.is_empty() && offset == length;
                let clock = clock.clone();
                let (next, output, finished) = uploads.workers.run(UploadError, move || {
                    let began = Instant::now();
                    let result = step.encode(end);
                    clock.record(began.elapsed());
                    result
                }).await?;
                step = next;
                if !output.is_empty() {
                    yield output;
                }
                if finished {
                    break;
                }
            }
        };
        RequestBody::chunked(chunks).with_diagnostics(length, Some(time))
    }
}

#[derive(Clone)]
pub(crate) enum Payload {
    Memory(Bytes),
    Staged(StagedBody),
}

impl Payload {
    fn len(&self) -> usize {
        match self {
            Self::Memory(bytes) => bytes.len(),
            Self::Staged(body) => body.len(),
        }
    }

    async fn block(&self, offset: usize) -> Result<Bytes, UploadError> {
        match self {
            // Jobs retain only their bounded input if the response owner drops early.
            Self::Memory(bytes) => Ok(Bytes::copy_from_slice(
                &bytes[offset..bytes.len().min(offset + UPLOAD_CHUNK_BYTES)],
            )),
            Self::Staged(body) => body.read_block(offset).await.map_err(|_| UploadError),
        }
    }

    fn plain(self) -> RequestBody {
        let length = self.len();
        let body = match self {
            Self::Memory(bytes) => RequestBody::bytes(bytes),
            Self::Staged(body) => {
                let chunks = async_stream::try_stream! {
                    for offset in (0..length).step_by(UPLOAD_CHUNK_BYTES) {
                        yield body.read_block(offset).await.map_err(|_| UploadError)?;
                    }
                };
                RequestBody::sized(chunks, length as u64)
            }
        };
        body.with_diagnostics(length, None)
    }
}

struct Workspace {
    _permit: OwnedSemaphorePermit,
    _released: DropGuard,
}

struct CompressionStep {
    encoder: Option<Encoder<'static>>,
    input: Bytes,
    _workspace: Workspace,
}

impl CompressionStep {
    fn encode(mut self, end: bool) -> Result<(Self, Bytes, bool), UploadError> {
        let mut output = Vec::with_capacity(UPLOAD_CHUNK_BYTES);
        let finished = self
            .encode_block(end, &mut output)
            .map_err(|_| UploadError)?;
        Ok((self, Bytes::from(output), finished))
    }

    fn encode_block(&mut self, end: bool, output: &mut Vec<u8>) -> io::Result<bool> {
        if self.encoder.is_none() {
            let mut encoder = Encoder::new(3)?;
            encoder.set_parameter(CParameter::ChecksumFlag(false))?;
            encoder.set_parameter(CParameter::ContentSizeFlag(false))?;
            self.encoder = Some(encoder);
        }
        // zstd is built without zstdmt; one bounded invocation runs per job.
        let encoder = self.encoder.as_mut().expect("initialized encoder");
        let mut buffer = OutBuffer::around(output);
        if end {
            return Ok(encoder.finish(&mut buffer, false)? == 0);
        }
        let mut input = zstd::stream::raw::InBuffer::around(&self.input);
        encoder.run(&mut input, &mut buffer)?;
        let read = input.pos();
        self.input.advance(read);
        Ok(false)
    }
}
