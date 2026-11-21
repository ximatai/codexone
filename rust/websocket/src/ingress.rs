use std::{pin::Pin, sync::Arc};

use tokio::{
    io::{AsyncRead, AsyncReadExt},
    time::{Instant, sleep_until},
};
use tokio_tungstenite::tungstenite::{
    Utf8Bytes,
    protocol::{CloseFrame, frame::coding::CloseCode},
};

use crate::{QUEUE_TIMEOUT, SocketEnd, SocketIo};

const MAX_MESSAGE: usize = codexone_responses::MAX_REQUEST_BYTES;
const MAX_FRAGMENTS: usize = 1024;
const MAX_WAITING_BYTES: usize = 256 * 1024;
const READ_CHUNK: usize = 8192;

/// Implemented by the data service's shared body budget. A lease releases its full reservation
/// on drop, including when an initial capacity wait is cancelled.
pub trait IngressBudget: Send + Sync {
    fn lease(&self) -> Box<dyn IngressLease>;
}

#[derive(Clone, Copy, Debug)]
pub struct CapacityExhausted;

pub trait IngressLease: Send {
    /// Reserve the first frame's full declared length. The service owns wait-ticket policy.
    fn reserve_first(
        &mut self,
        bytes: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), CapacityExhausted>> + Send + '_>>;

    /// Grow to the declared total message size without waiting while holding bytes.
    fn grow(&mut self, total_bytes: usize) -> Result<(), CapacityExhausted>;
}

pub struct DownstreamSocket {
    pub(crate) io: Box<dyn SocketIo>,
    pub(crate) budget: Arc<dyn IngressBudget>,
}

/// Wrap the HTTP server's upgraded stream after local authorization and connection admission.
/// Supply the process-wide budget shared with HTTP, including any read-ahead after the upgrade.
pub fn downstream_socket(
    io: impl SocketIo + 'static,
    budget: Arc<dyn IngressBudget>,
) -> DownstreamSocket {
    DownstreamSocket {
        io: Box::new(io),
        budget,
    }
}

pub(crate) struct IngressMessage {
    pub text: Utf8Bytes,
    pub lease: Box<dyn IngressLease>,
}

#[derive(Clone, Copy)]
pub(crate) enum Rejection {
    Capacity,
    TooLarge,
}

pub(crate) enum FrameEvent {
    Text(IngressMessage),
    Ping(Vec<u8>),
    Close(Option<CloseFrame>),
    Rejected(Rejection),
}

struct Header {
    final_frame: bool,
    opcode: u8,
    length: u64,
    mask: [u8; 4],
}

struct Fragmented {
    lease: Box<dyn IngressLease>,
    bytes: Vec<u8>,
    fragments: usize,
}

enum MessageState {
    Idle,
    Receiving(Fragmented),
    Discarding,
}

pub(crate) struct FrameReader<R> {
    io: R,
    budget: Arc<dyn IngressBudget>,
    state: MessageState,
    discard: Option<Header>,
    staged: Vec<u8>,
    staged_offset: usize,
    overflow: Option<u8>,
}

impl<R: AsyncRead + Unpin> FrameReader<R> {
    pub fn new(io: R, budget: Arc<dyn IngressBudget>) -> Self {
        Self {
            io,
            budget,
            state: MessageState::Idle,
            discard: None,
            staged: Vec::new(),
            staged_offset: 0,
            overflow: None,
        }
    }

    pub async fn next(&mut self) -> Result<FrameEvent, SocketEnd> {
        loop {
            if let Some(header) = self.discard.take() {
                self.discard_payload(header.length).await?;
                if header.final_frame {
                    self.state = MessageState::Idle;
                }
            }
            let header = self.read_header().await?;
            if header.opcode >= 8 {
                let mut payload = vec![0; header.length as usize];
                self.read_exact(&mut payload).await?;
                unmask(&mut payload, header.mask);
                match header.opcode {
                    8 => {
                        let close = close_frame(payload)?;
                        self.state = MessageState::Idle;
                        return Ok(FrameEvent::Close(close));
                    }
                    9 => return Ok(FrameEvent::Ping(payload)),
                    _ => continue,
                }
            }
            if matches!(self.state, MessageState::Discarding) {
                self.discard = Some(header);
                continue;
            }
            if let Some(rejection) = self.accept_header(&header).await? {
                self.state = MessageState::Discarding;
                self.discard = Some(header);
                return Ok(FrameEvent::Rejected(rejection));
            }
            let MessageState::Receiving(mut message) =
                std::mem::replace(&mut self.state, MessageState::Idle)
            else {
                unreachable!("validated data frame must own a lease");
            };
            let start = message.bytes.len();
            // Capacity for these bytes was acquired from the shared service before allocating.
            let length = header.length as usize;
            message.bytes.reserve_exact(length);
            message.bytes.resize(start + length, 0);
            self.read_exact(&mut message.bytes[start..]).await?;
            unmask(&mut message.bytes[start..], header.mask);
            if header.final_frame {
                let text =
                    Utf8Bytes::try_from(message.bytes).map_err(|_| SocketEnd::InvalidFrame)?;
                return Ok(FrameEvent::Text(IngressMessage {
                    text,
                    lease: message.lease,
                }));
            }
            self.state = MessageState::Receiving(message);
        }
    }

    async fn accept_header(&mut self, header: &Header) -> Result<Option<Rejection>, SocketEnd> {
        if header.length > MAX_MESSAGE as u64 {
            return Ok(Some(Rejection::TooLarge));
        }
        let length = header.length as usize;
        match &mut self.state {
            MessageState::Receiving(message) => {
                if length > MAX_MESSAGE - message.bytes.len() || message.fragments >= MAX_FRAGMENTS
                {
                    return Ok(Some(Rejection::TooLarge));
                }
                if message.lease.grow(message.bytes.len() + length).is_err() {
                    return Ok(Some(Rejection::Capacity));
                }
                message.fragments += 1;
            }
            MessageState::Idle => {
                let mut lease = self.budget.lease();
                if !self.wait_for_first_frame(lease.as_mut(), length).await? {
                    return Ok(Some(Rejection::Capacity));
                }
                self.state = MessageState::Receiving(Fragmented {
                    lease,
                    bytes: Vec::new(),
                    fragments: 1,
                });
            }
            MessageState::Discarding => unreachable!("discarded message handled before admission"),
        }
        Ok(None)
    }

    async fn wait_for_first_frame(
        &mut self,
        lease: &mut dyn IngressLease,
        length: usize,
    ) -> Result<bool, SocketEnd> {
        // A previous refusal may have read ahead into this message. Restore its tail
        // before reading any additional transport bytes for the new wait.
        if let Some(byte) = self.overflow.take() {
            self.staged.drain(..self.staged_offset);
            self.staged_offset = 0;
            debug_assert!(self.staged.len() < MAX_WAITING_BYTES);
            self.staged.reserve_exact(1);
            self.staged.push(byte);
        }
        let deadline = Instant::now() + QUEUE_TIMEOUT;
        let reservation = lease.reserve_first(length);
        tokio::pin!(reservation);
        let mut scratch = [0; READ_CHUNK];
        loop {
            // Only these bounded transport bytes may be staged while a ticket is pending.
            let remaining = self.staged.len() - self.staged_offset;
            let room = MAX_WAITING_BYTES - remaining;
            let limit = scratch.len().min(room + 1);
            tokio::select! {
                biased;
                _ = sleep_until(deadline) => return Ok(false),
                reserved = &mut reservation => return Ok(reserved.is_ok() && Instant::now() < deadline),
                read = self.io.read(&mut scratch[..limit]) => {
                    let read = read.map_err(|_| SocketEnd::Eof)?;
                    if read == 0 {
                        return Err(SocketEnd::Eof);
                    }
                    self.staged.drain(..self.staged_offset);
                    self.staged_offset = 0;
                    let staged = read.min(room);
                    self.staged.reserve_exact(staged);
                    self.staged.extend_from_slice(&scratch[..staged]);
                    if read > staged {
                        // Preserve the look-ahead byte so discarding keeps frame alignment.
                        self.overflow = Some(scratch[staged]);
                        return Ok(false);
                    }
                }
            }
        }
    }

    async fn read_exact(&mut self, buffer: &mut [u8]) -> Result<(), SocketEnd> {
        let mut ready = (self.staged.len() - self.staged_offset).min(buffer.len());
        buffer[..ready]
            .copy_from_slice(&self.staged[self.staged_offset..self.staged_offset + ready]);
        self.staged_offset += ready;
        if self.staged_offset == self.staged.len() {
            self.staged = Vec::new();
            self.staged_offset = 0;
            if ready < buffer.len()
                && let Some(byte) = self.overflow.take()
            {
                buffer[ready] = byte;
                ready += 1;
            }
        }
        self.io
            .read_exact(&mut buffer[ready..])
            .await
            .map(|_| ())
            .map_err(|_| SocketEnd::Eof)
    }

    async fn discard_payload(&mut self, mut length: u64) -> Result<(), SocketEnd> {
        let mut scratch = [0; READ_CHUNK];
        while length != 0 {
            let read = length.min(scratch.len() as u64) as usize;
            self.read_exact(&mut scratch[..read]).await?;
            length -= read as u64;
        }
        Ok(())
    }

    async fn read_header(&mut self) -> Result<Header, SocketEnd> {
        let mut prefix = [0; 2];
        self.read_exact(&mut prefix).await?;
        let final_frame = prefix[0] & 0x80 != 0;
        let opcode = prefix[0] & 15;
        let marker = prefix[1] & 127;
        if prefix[0] & 0x70 != 0
            || prefix[1] & 0x80 == 0
            || !matches!(opcode, 0 | 1 | 8 | 9 | 10)
            || (opcode >= 8 && (!final_frame || marker > 125))
            || (opcode == 0 && matches!(self.state, MessageState::Idle))
            || (opcode == 1 && !matches!(self.state, MessageState::Idle))
        {
            return Err(SocketEnd::InvalidFrame);
        }
        let length = match marker {
            126 => {
                let mut raw = [0; 2];
                self.read_exact(&mut raw).await?;
                let length = u64::from(u16::from_be_bytes(raw));
                if length < 126 {
                    return Err(SocketEnd::InvalidFrame);
                }
                length
            }
            127 => {
                let mut raw = [0; 8];
                self.read_exact(&mut raw).await?;
                let length = u64::from_be_bytes(raw);
                if !(65_536..=i64::MAX as u64).contains(&length) {
                    return Err(SocketEnd::InvalidFrame);
                }
                length
            }
            _ => u64::from(marker),
        };
        let mut mask = [0; 4];
        self.read_exact(&mut mask).await?;
        Ok(Header {
            final_frame,
            opcode,
            length,
            mask,
        })
    }
}

fn unmask(bytes: &mut [u8], mask: [u8; 4]) {
    for (byte, key) in bytes.iter_mut().zip(mask.into_iter().cycle()) {
        *byte ^= key;
    }
}

fn close_frame(payload: Vec<u8>) -> Result<Option<CloseFrame>, SocketEnd> {
    match payload.as_slice() {
        [] => Ok(None),
        [high, low, reason @ ..] => {
            let code = u16::from_be_bytes([*high, *low]);
            if !matches!(code, 1000..=1003 | 1007..=1014 | 3000..=4999) {
                return Err(SocketEnd::InvalidFrame);
            }
            let reason = std::str::from_utf8(reason).map_err(|_| SocketEnd::InvalidFrame)?;
            Ok(Some(CloseFrame {
                code: CloseCode::from(code),
                reason: reason.into(),
            }))
        }
        _ => Err(SocketEnd::InvalidFrame),
    }
}
