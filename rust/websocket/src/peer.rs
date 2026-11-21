use std::sync::Arc;

use futures_util::{SinkExt, StreamExt, stream::SplitSink};
use tokio::{
    io::{AsyncWriteExt, WriteHalf},
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
    task::JoinSet,
    time::{Instant, timeout_at},
};
use tokio_tungstenite::tungstenite::{
    Error, Message, Utf8Bytes,
    protocol::{CloseFrame, frame::coding::CloseCode},
};

use crate::{
    CancellationToken, DownstreamSocket, QUEUE_TIMEOUT, Socket, SocketEnd, SocketIo,
    ingress::{FrameEvent, FrameReader, IngressMessage, IngressRefusal},
    protocol::websocket_ingress_error,
};

pub(crate) const DOWNSTREAM_QUEUE_BYTES: usize = 72 * 1024 * 1024;
const QUEUE_ITEMS: usize = 64;

pub(crate) struct Packet<T = Utf8Bytes> {
    pub event: T,
    _bytes: OwnedSemaphorePermit,
}

pub(crate) enum Read<T> {
    Deliver(T),
    Ignore,
    Stop(T),
}

enum Write {
    Frame(Message),
    Flush,
}

struct PendingWrite {
    command: Write,
    deadline: Instant,
    receipt: Option<oneshot::Sender<Result<Instant, SocketEnd>>>,
    _bytes: Option<OwnedSemaphorePermit>,
}

pub(crate) struct Receipt(oneshot::Receiver<Result<Instant, SocketEnd>>);

impl Receipt {
    pub async fn wait(self) -> Result<Instant, SocketEnd> {
        self.0.await.unwrap_or(Err(SocketEnd::Write))
    }
}

type WriteQueue = mpsc::Sender<PendingWrite>;

struct Reader<T> {
    input: mpsc::Sender<Result<Packet<T>, SocketEnd>>,
    output: WriteQueue,
    bytes: Arc<Semaphore>,
    closed: CancellationToken,
}

impl<T> Reader<T> {
    async fn push(&self, event: T, size: usize) -> Result<(), SocketEnd> {
        timeout_at(Instant::now() + QUEUE_TIMEOUT, async {
            let permit = self
                .bytes
                .clone()
                .acquire_many_owned(size as u32)
                .await
                .map_err(|_| SocketEnd::Congested)?;
            self.input
                .send(Ok(Packet {
                    event,
                    _bytes: permit,
                }))
                .await
                .map_err(|_| SocketEnd::Congested)
        })
        .await
        .unwrap_or(Err(SocketEnd::Congested))
    }
}

enum Writer {
    Provider(SplitSink<Socket, Message>),
    Downstream(WriteHalf<Box<dyn SocketIo>>),
}

impl Writer {
    async fn send(&mut self, command: Write) -> Result<(), SocketEnd> {
        match self {
            Self::Provider(sink) => match command {
                Write::Frame(frame) => sink.send(frame).await,
                Write::Flush => sink.flush().await,
            }
            .map_err(|_| SocketEnd::Write),
            Self::Downstream(io) => match command {
                Write::Frame(frame) => write_server_frame(io, frame)
                    .await
                    .map_err(|_| SocketEnd::Write),
                Write::Flush => io.flush().await.map_err(|_| SocketEnd::Write),
            },
        }
    }
}

/// A peer owns its reader and writer; queues bound both entries and payload bytes.
pub(crate) struct Peer<T = Utf8Bytes> {
    input: mpsc::Receiver<Result<Packet<T>, SocketEnd>>,
    output: WriteQueue,
    output_bytes: Arc<Semaphore>,
    tasks: JoinSet<()>,
    read_closed: CancellationToken,
}

impl Peer<IngressMessage> {
    pub fn ingress(socket: DownstreamSocket, output_bytes: usize) -> Self {
        let (read, write) = tokio::io::split(socket.io);
        let mut frames = FrameReader::new(read, socket.budget);
        Self::start(
            DOWNSTREAM_QUEUE_BYTES,
            output_bytes,
            Writer::Downstream(write),
            move |reader| async move {
                loop {
                    match frames.next().await {
                        Ok(FrameEvent::Text(message)) => {
                            let size = message.text.len();
                            if let Err(end) = reader.push(message, size).await {
                                return end;
                            }
                        }
                        Ok(FrameEvent::Rejected(reason)) => {
                            let (status, code) = match reason {
                                IngressRefusal::TooLarge => (413, "request_too_large"),
                                IngressRefusal::Capacity => (503, "capacity_exhausted"),
                            };
                            let command =
                                Write::Frame(Message::Text(websocket_ingress_error(status, code)));
                            if enqueue_control(&reader.output, command).await.is_err() {
                                return SocketEnd::Congested;
                            }
                        }
                        Ok(FrameEvent::Ping(payload)) => {
                            let command = Write::Frame(Message::Pong(payload.into()));
                            if enqueue_control(&reader.output, command).await.is_err() {
                                return SocketEnd::Congested;
                            }
                        }
                        Ok(FrameEvent::Close(frame)) => {
                            let code = frame.as_ref().map_or(1005, |frame| frame.code.into());
                            reader.closed.cancel();
                            if let Ok(receipt) = write_frame(
                                &reader.output,
                                Message::Close(frame),
                                Instant::now() + QUEUE_TIMEOUT,
                                None,
                            )
                            .await
                            {
                                let _ = receipt.wait().await;
                            }
                            return SocketEnd::Close(code);
                        }
                        Err(end) => return end,
                    }
                }
            },
        )
    }
}

impl<T: Send + 'static> Peer<T> {
    pub fn provider(
        socket: Socket,
        input_bytes: usize,
        output_bytes: usize,
        mut observe: impl FnMut(Utf8Bytes) -> Read<T> + Send + 'static,
    ) -> Self {
        let (sink, mut stream) = socket.split();
        Self::start(
            input_bytes,
            output_bytes,
            Writer::Provider(sink),
            move |reader| async move {
                loop {
                    let text = match stream.next().await {
                        Some(Ok(Message::Text(text))) => text,
                        // The Tungstenite reader queues protocol replies; only the writer flushes them.
                        Some(Ok(Message::Ping(_))) => {
                            if enqueue_control(&reader.output, Write::Flush).await.is_err() {
                                return SocketEnd::Congested;
                            }
                            continue;
                        }
                        Some(Ok(Message::Pong(_))) => continue,
                        Some(Ok(Message::Close(frame))) => {
                            reader.closed.cancel();
                            let _ = enqueue_control(&reader.output, Write::Flush).await;
                            return SocketEnd::Close(frame.map_or(1005, |frame| frame.code.into()));
                        }
                        Some(Err(error)) => return read_error(error),
                        Some(Ok(_)) => return SocketEnd::InvalidFrame,
                        None => return SocketEnd::Eof,
                    };
                    let size = text.len();
                    // Correlate and hand off durable evidence before attempting delivery queue admission.
                    let (event, stop) = match observe(text) {
                        Read::Deliver(event) => (event, false),
                        Read::Stop(event) => {
                            reader.closed.cancel();
                            (event, true)
                        }
                        Read::Ignore => continue,
                    };
                    if let Err(end) = reader.push(event, size).await {
                        return end;
                    }
                    if stop {
                        return SocketEnd::InvalidFrame;
                    }
                }
            },
        )
    }

    fn start<F>(
        input_bytes: usize,
        output_bytes: usize,
        mut writer: Writer,
        reader: impl FnOnce(Reader<T>) -> F,
    ) -> Self
    where
        F: Future<Output = SocketEnd> + Send + 'static,
    {
        let (incoming, input) = mpsc::channel(QUEUE_ITEMS);
        let (output, mut outgoing) = mpsc::channel::<PendingWrite>(QUEUE_ITEMS);
        let mut tasks = JoinSet::new();
        let read_closed = CancellationToken::new();
        let reader_closed = read_closed.clone();
        let read = reader(Reader {
            input: incoming.clone(),
            output: output.clone(),
            bytes: Arc::new(Semaphore::new(input_bytes)),
            closed: read_closed.clone(),
        });
        tasks.spawn(async move {
            let end = read.await;
            reader_closed.cancel();
            // Preserve already queued events before EOF or a reset.
            let _ = incoming.send(Err(end)).await;
        });
        tasks.spawn(async move {
            while let Some(message) = outgoing.recv().await {
                let PendingWrite {
                    command,
                    deadline,
                    receipt,
                    _bytes,
                } = message;
                let closing = matches!(&command, Write::Frame(Message::Close(_)));
                let result = if Instant::now() >= deadline {
                    Err(SocketEnd::Write)
                } else {
                    timeout_at(deadline, writer.send(command))
                        .await
                        .unwrap_or(Err(SocketEnd::Write))
                        .map(|()| Instant::now())
                };
                if let Some(receipt) = receipt {
                    let _ = receipt.send(result);
                }
                if result.is_err() || closing {
                    break;
                }
            }
        });
        Self {
            input,
            output,
            output_bytes: Arc::new(Semaphore::new(output_bytes)),
            tasks,
            read_closed,
        }
    }

    pub fn read_closed(&self) -> CancellationToken {
        self.read_closed.clone()
    }

    pub async fn recv(&mut self) -> Result<Packet<T>, SocketEnd> {
        self.input.recv().await.unwrap_or(Err(SocketEnd::Eof))
    }

    pub async fn queue(&self, text: Utf8Bytes, deadline: Instant) -> Result<Receipt, SocketEnd> {
        let permit = timeout_at(
            deadline.min(Instant::now() + QUEUE_TIMEOUT),
            self.output_bytes
                .clone()
                .acquire_many_owned(text.len() as u32),
        )
        .await
        .map_err(|_| SocketEnd::Congested)?
        .map_err(|_| SocketEnd::Write)?;
        write_frame(&self.output, Message::Text(text), deadline, Some(permit)).await
    }

    pub async fn send(&self, text: Utf8Bytes, deadline: Instant) -> Result<Instant, SocketEnd> {
        self.queue(text, deadline).await?.wait().await
    }

    pub async fn close(&mut self, code: CloseCode) {
        let frame = Message::Close(Some(CloseFrame {
            code,
            reason: Utf8Bytes::default(),
        }));
        if let Ok(receipt) =
            write_frame(&self.output, frame, Instant::now() + QUEUE_TIMEOUT, None).await
        {
            let _ = receipt.wait().await;
        }
        self.stop().await;
    }

    pub async fn stop(&mut self) {
        self.tasks.shutdown().await;
        self.input.close();
        while self.input.try_recv().is_ok() {}
    }
}

async fn write_frame(
    output: &WriteQueue,
    frame: Message,
    deadline: Instant,
    bytes: Option<OwnedSemaphorePermit>,
) -> Result<Receipt, SocketEnd> {
    let (receipt, ready) = oneshot::channel();
    timeout_at(
        deadline.min(Instant::now() + QUEUE_TIMEOUT),
        output.send(PendingWrite {
            command: Write::Frame(frame),
            deadline,
            receipt: Some(receipt),
            _bytes: bytes,
        }),
    )
    .await
    .map_err(|_| SocketEnd::Congested)?
    .map_err(|_| SocketEnd::Write)?;
    Ok(Receipt(ready))
}

async fn enqueue_control(output: &WriteQueue, command: Write) -> Result<(), SocketEnd> {
    let deadline = Instant::now() + QUEUE_TIMEOUT;
    timeout_at(
        deadline,
        output.send(PendingWrite {
            command,
            deadline,
            receipt: None,
            _bytes: None,
        }),
    )
    .await
    .map_err(|_| SocketEnd::Congested)?
    .map_err(|_| SocketEnd::Write)
}

async fn write_server_frame(
    io: &mut (impl tokio::io::AsyncWrite + Unpin),
    frame: Message,
) -> std::io::Result<()> {
    let mut close = [0; 125];
    let (opcode, bytes): (u8, &[u8]) = match &frame {
        Message::Text(text) => (1, text.as_bytes()),
        Message::Pong(data) => (10, data),
        Message::Close(Some(frame)) => {
            let code = u16::from(frame.code);
            close[..2].copy_from_slice(&code.to_be_bytes());
            close[2..2 + frame.reason.len()].copy_from_slice(frame.reason.as_bytes());
            (8, &close[..2 + frame.reason.len()])
        }
        Message::Close(None) => (8, &[]),
        _ => unreachable!("unsupported downstream frame"),
    };
    let mut header = [0; 10];
    header[0] = 0x80 | opcode;
    let header_len = match bytes.len() {
        len @ 0..=125 => {
            header[1] = len as u8;
            2
        }
        len @ 126..=65_535 => {
            header[1] = 126;
            header[2..4].copy_from_slice(&(len as u16).to_be_bytes());
            4
        }
        len => {
            header[1] = 127;
            header[2..].copy_from_slice(&(len as u64).to_be_bytes());
            10
        }
    };
    io.write_all(&header[..header_len]).await?;
    io.write_all(bytes).await?;
    io.flush().await
}

fn read_error(error: Error) -> SocketEnd {
    use tokio_tungstenite::tungstenite::error::ProtocolError;
    match error {
        Error::Capacity(_) => SocketEnd::MessageTooLarge,
        Error::ConnectionClosed
        | Error::AlreadyClosed
        | Error::Io(_)
        | Error::Protocol(ProtocolError::ResetWithoutClosingHandshake) => SocketEnd::Eof,
        _ => SocketEnd::InvalidFrame,
    }
}
