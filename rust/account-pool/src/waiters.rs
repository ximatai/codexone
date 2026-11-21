use std::time::Duration;

use tokio::sync::watch;

use crate::{Error, MAX_PACING_WAIT, Result};

const MAX_WAITERS: usize = 64;

#[derive(Clone, Copy, Default)]
struct State {
    closed: bool,
    active: usize,
}

/// One owner per execution service. Wait in the request task, outside the writer and its ticket.
/// Dropping the request's future releases the slot. `close` cancels and drains all registered waits.
#[derive(Default)]
pub struct PacingWaiters {
    state: watch::Sender<State>,
}

struct Slot<'a>(&'a watch::Sender<State>);

impl Drop for Slot<'_> {
    fn drop(&mut self) {
        self.0.send_modify(|state| state.active -= 1);
    }
}

impl PacingWaiters {
    pub async fn wait(&self, duration: Duration) -> Result<()> {
        if duration.is_zero() || duration > MAX_PACING_WAIT {
            return Err(Error::InvalidCommand);
        }
        let mut error = Error::Capacity;
        let registered = self.state.send_if_modified(|state| {
            if state.closed {
                error = Error::Closed;
                return false;
            }
            if state.active == MAX_WAITERS {
                return false;
            }
            state.active += 1;
            true
        });
        if !registered {
            return Err(error);
        }
        let _slot = Slot(&self.state);
        let mut state = self.state.subscribe();
        tokio::select! {
            biased;
            _ = state.wait_for(|state| state.closed) => Err(Error::Closed),
            _ = tokio::time::sleep(duration) => Ok(()),
        }
    }

    pub async fn close(&self) {
        let mut state = self.state.subscribe();
        self.state.send_modify(|state| state.closed = true);
        let _ = state.wait_for(|state| state.active == 0).await;
    }
}
