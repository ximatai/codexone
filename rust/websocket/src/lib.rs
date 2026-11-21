//! Bounded Responses WebSocket transport. The application owns authorization, durable admission,
//! object binding, usage and settlement.
mod bridge;
mod handshake;
mod ingress;
mod native;
mod peer;
mod protocol;
mod turns;

pub use bridge::*;
pub use codexone_http_upstream::CancellationToken;
pub use handshake::*;
pub use ingress::{
    CapacityExhausted, DownstreamSocket, IngressBudget, IngressLease, downstream_socket,
};
pub use native::*;
pub use protocol::*;

use std::time::Duration;

pub(crate) const QUEUE_TIMEOUT: Duration = Duration::from_secs(5);
pub const WS_ROUTING_BYTES: usize = 12 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SocketEnd {
    Close(u16),
    Eof,
    InvalidFrame,
    MessageTooLarge,
    Congested,
    Write,
    Cancelled,
}

#[derive(Clone, Copy, Debug)]
pub struct ExecutionBudget {
    pub total: Duration,
    pub first_response: Duration,
    pub idle: Duration,
}

impl Default for ExecutionBudget {
    fn default() -> Self {
        Self {
            total: Duration::from_secs(600),
            first_response: Duration::from_secs(30),
            idle: Duration::from_secs(60),
        }
    }
}

pub use tokio_tungstenite::tungstenite::Utf8Bytes;
