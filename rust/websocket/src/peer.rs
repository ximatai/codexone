use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
    task::JoinSet,
    time::{Instant, timeout, timeout_at},
};
use tokio_tungstenite::tungstenite::{
    Error, Message, Utf8Bytes,
    protocol::{CloseFrame, frame::coding::CloseCode},
};

use crate::{QUEUE_TIMEOUT, Socket, SocketEnd};

pub(crate) const DOWNSTREAM_QUEUE_BYTES: usize = 72 * 1024 * 1024;
const QUEUE_ITEMS: usize = 64;

pub(crate) struct Packet {
    pub text: Utf8Bytes,
    _bytes: OwnedSemaphorePermit,
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

/// A peer owns its reader and writer; the queues count both entries and payload bytes.
pub(crate) struct Peer {
    input: mpsc::Receiver<Result<Packet, SocketEnd>>,
    output: mpsc::Sender<PendingWrite>,
    output_bytes: Arc<Semaphore>,
    tasks: JoinSet<()>,
    read_closed: crate::CancellationToken,
}

impl Peer {
    pub fn new(socket: Socket, input_bytes: usize, output_bytes: usize) -> Self {
        let (mut sink, mut stream) = socket.split();
        let (incoming, input) = mpsc::channel(QUEUE_ITEMS);
        let (output, mut outgoing) = mpsc::channel::<PendingWrite>(QUEUE_ITEMS);
        let reader_output = output.clone();
        let mut tasks = JoinSet::new();
        let read_closed = crate::CancellationToken::new();
        let reader_closed = read_closed.clone();
        tasks.spawn(async move {
            let bytes = Arc::new(Semaphore::new(input_bytes));
            let end = loop {
                let text = match stream.next().await {
                    Some(Ok(Message::Text(text))) => text,
                    // Tungstenite queues the pong/close reply on read. Only the writer flushes it.
                    Some(Ok(Message::Ping(_))) => {
                        if schedule_flush(&reader_output).await.is_err() {
                            break SocketEnd::Congested;
                        }
                        continue;
                    }
                    Some(Ok(Message::Pong(_))) => continue,
                    Some(Ok(Message::Close(frame))) => {
                        reader_closed.cancel();
                        let _ = schedule_flush(&reader_output).await;
                        break SocketEnd::Close(frame.map_or(1005, |frame| frame.code.into()));
                    }
                    Some(Err(error)) => break read_error(error),
                    Some(Ok(_)) => break SocketEnd::InvalidFrame,
                    None => break SocketEnd::Eof,
                };
                match timeout(QUEUE_TIMEOUT, async {
                    let size = text.len() as u32;
                    let permit = bytes
                        .clone()
                        .acquire_many_owned(size)
                        .await
                        .map_err(|_| ())?;
                    incoming
                        .send(Ok(Packet {
                            text,
                            _bytes: permit,
                        }))
                        .await
                        .map_err(|_| ())
                })
                .await
                {
                    Ok(Ok(())) => {}
                    _ => break SocketEnd::Congested,
                }
            };
            // Preserve preceding events and their order when EOF/close follows immediately.
            reader_closed.cancel();
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
                let result = if Instant::now() >= deadline {
                    Err(SocketEnd::Write)
                } else {
                    timeout_at(deadline, async {
                        match command {
                            Write::Frame(frame) => sink.send(frame).await,
                            Write::Flush => sink.flush().await,
                        }
                    })
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .map(|()| Instant::now())
                    .ok_or(SocketEnd::Write)
                };
                if let Some(receipt) = receipt {
                    let _ = receipt.send(result);
                }
                if result.is_err() {
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

    pub fn read_closed(&self) -> crate::CancellationToken {
        self.read_closed.clone()
    }

    pub async fn recv(&mut self) -> Result<Packet, SocketEnd> {
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
        self.submit(Message::Text(text), deadline, Some(permit))
            .await
    }

    async fn submit(
        &self,
        frame: Message,
        deadline: Instant,
        bytes: Option<OwnedSemaphorePermit>,
    ) -> Result<Receipt, SocketEnd> {
        let (receipt, ready) = oneshot::channel();
        timeout_at(
            deadline.min(Instant::now() + QUEUE_TIMEOUT),
            self.output.send(PendingWrite {
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

    pub async fn send(&self, text: Utf8Bytes, deadline: Instant) -> Result<Instant, SocketEnd> {
        self.queue(text, deadline).await?.wait().await
    }

    pub async fn close(&mut self, code: CloseCode) {
        let frame = Message::Close(Some(CloseFrame {
            code,
            reason: Utf8Bytes::default(),
        }));
        if let Ok(receipt) = self
            .submit(frame, Instant::now() + QUEUE_TIMEOUT, None)
            .await
        {
            let _ = receipt.wait().await;
        }
        self.stop().await;
    }

    pub async fn stop(&mut self) {
        self.tasks.shutdown().await;
    }
}

async fn schedule_flush(output: &mpsc::Sender<PendingWrite>) -> Result<(), ()> {
    timeout(
        QUEUE_TIMEOUT,
        output.send(PendingWrite {
            command: Write::Flush,
            deadline: Instant::now() + QUEUE_TIMEOUT,
            receipt: None,
            _bytes: None,
        }),
    )
    .await
    .map_err(|_| ())?
    .map_err(|_| ())
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
