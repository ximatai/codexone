use std::{
    collections::VecDeque,
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

use codexone_responses::MAX_REQUEST_BYTES;
use tokio::{
    sync::Notify,
    time::{Instant, timeout_at},
};

use crate::listener::ReadError;

const SMALL: usize = 8 * 1024 * 1024;
const MAX_WAITERS: usize = 4;
const WAIT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Default)]
struct Reservation {
    bytes: usize,
    small: bool,
}

struct Waiter {
    id: u64,
    bytes: usize,
    key: Option<String>,
}

#[derive(Default)]
struct State {
    shared: usize,
    small: usize,
    next_id: u64,
    waiters: VecDeque<Waiter>,
}

impl State {
    fn available(
        &self,
        old: Reservation,
        bytes: usize,
        turn: impl Fn(bool) -> bool,
    ) -> Option<Reservation> {
        if bytes <= SMALL
            && turn(true)
            && bytes <= SMALL - self.small + if old.small { old.bytes } else { 0 }
        {
            Some(Reservation { bytes, small: true })
        } else if turn(false)
            && bytes <= MAX_REQUEST_BYTES - self.shared + if old.small { 0 } else { old.bytes }
        {
            Some(Reservation {
                bytes,
                small: false,
            })
        } else {
            None
        }
    }

    fn replace(&mut self, old: Reservation, new: Reservation) {
        if old.small {
            self.small -= old.bytes;
        } else {
            self.shared -= old.bytes;
        }
        if new.small {
            self.small += new.bytes;
        } else {
            self.shared += new.bytes;
        }
    }

    fn is_turn(&self, small: bool, ticket: Option<u64>) -> bool {
        let first = self
            .waiters
            .iter()
            .find(|waiter| !small || waiter.bytes <= SMALL);
        first.map(|waiter| waiter.id) == ticket
    }
}

#[derive(Default)]
struct Budget {
    state: Mutex<State>,
    changed: Notify,
}

impl Budget {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[derive(Clone, Default)]
pub struct DataBodies(Arc<Budget>);

impl DataBodies {
    pub fn new() -> Self {
        Self::default()
    }

    /// Reserve an empty lease for the first frame of a WebSocket message.
    pub async fn reserve_first(&self, total: usize) -> Result<BodyPermit, ReadError> {
        self.reserve_http(total, None, Instant::now() + WAIT).await
    }

    pub(crate) async fn reserve_http(
        &self,
        total: usize,
        key: Option<&str>,
        deadline: Instant,
    ) -> Result<BodyPermit, ReadError> {
        if total > MAX_REQUEST_BYTES {
            return Err(ReadError::TooLarge);
        }
        if total == 0 {
            return Ok(self.permit(Reservation::default()));
        }
        let deadline = deadline.min(Instant::now() + WAIT);
        let id = {
            let mut state = self.0.state();
            if Instant::now() >= deadline {
                return Err(ReadError::Capacity);
            }
            if let Some(reservation) = state.available(Reservation::default(), total, |small| {
                state.is_turn(small, None)
            }) {
                state.replace(Reservation::default(), reservation);
                return Ok(self.permit(reservation));
            }
            let key = key.filter(|_| total > SMALL);
            if state.waiters.len() >= MAX_WAITERS
                || key.is_some_and(|key| {
                    state
                        .waiters
                        .iter()
                        .any(|waiter| waiter.key.as_deref() == Some(key))
                })
            {
                return Err(ReadError::Capacity);
            }
            let id = state.next_id;
            state.next_id = state.next_id.wrapping_add(1);
            state.waiters.push_back(Waiter {
                id,
                bytes: total,
                key: key.map(str::to_owned),
            });
            id
        };
        let _ticket = WaitTicket {
            budget: &self.0,
            id,
        };
        loop {
            let changed = self.0.changed.notified();
            if let Some(reservation) = {
                let mut state = self.0.state();
                if Instant::now() >= deadline {
                    return Err(ReadError::Capacity);
                }
                let available = state.available(Reservation::default(), total, |small| {
                    state.is_turn(small, Some(id))
                });
                if let Some(reservation) = available {
                    state.replace(Reservation::default(), reservation);
                    state.waiters.retain(|waiter| waiter.id != id);
                }
                available
            } {
                self.0.changed.notify_waiters();
                return Ok(self.permit(reservation));
            }
            timeout_at(deadline, changed)
                .await
                .map_err(|_| ReadError::Capacity)?;
        }
    }

    /// Grow an existing lease immediately. Crossing the small reserve is an
    /// atomic move to the shared pool or a rejection with the old lease intact.
    pub fn grow(&self, permit: &mut BodyPermit, total: usize) -> Result<(), ReadError> {
        assert!(
            Arc::ptr_eq(&self.0, &permit.budget),
            "lease belongs to another body budget"
        );
        if total > MAX_REQUEST_BYTES {
            return Err(ReadError::TooLarge);
        }
        let old = permit.reservation;
        if total <= old.bytes {
            return Ok(());
        }
        let next = {
            let mut state = self.0.state();
            let next = state
                .available(old, total, |small| {
                    old.bytes > 0 || state.is_turn(small, None)
                })
                .ok_or(ReadError::Capacity)?;
            state.replace(old, next);
            next
        };
        permit.reservation = next;
        if old.small != next.small {
            self.0.changed.notify_waiters();
        }
        Ok(())
    }

    fn permit(&self, reservation: Reservation) -> BodyPermit {
        BodyPermit {
            budget: self.0.clone(),
            reservation,
        }
    }
}

pub struct BodyPermit {
    budget: Arc<Budget>,
    reservation: Reservation,
}

impl Drop for BodyPermit {
    fn drop(&mut self) {
        if self.reservation.bytes != 0 {
            self.budget
                .state()
                .replace(self.reservation, Reservation::default());
            self.budget.changed.notify_waiters();
        }
    }
}

struct WaitTicket<'a> {
    budget: &'a Budget,
    id: u64,
}

impl Drop for WaitTicket<'_> {
    fn drop(&mut self) {
        self.budget
            .state()
            .waiters
            .retain(|waiter| waiter.id != self.id);
        self.budget.changed.notify_waiters();
    }
}

#[cfg(test)]
mod tests {
    use futures_util::poll;

    use super::*;

    #[tokio::test]
    async fn waiters_are_bounded_and_keep_shared_fifo_with_small_headroom() {
        let budget = DataBodies::new();
        let full = budget.reserve_first(MAX_REQUEST_BYTES).await.unwrap();
        let deadline = Instant::now() + WAIT;
        let mut first = Box::pin(budget.reserve_http(SMALL + 1, Some("key-a"), deadline));
        assert!(poll!(&mut first).is_pending());
        assert!(matches!(
            budget
                .reserve_http(SMALL + 1, Some("key-a"), deadline)
                .await,
            Err(ReadError::Capacity)
        ));

        let mut other: Vec<_> = (0..3)
            .map(|_| Box::pin(budget.reserve_first(MAX_REQUEST_BYTES)))
            .collect();
        for waiter in &mut other {
            assert!(poll!(waiter).is_pending());
        }
        assert!(matches!(
            budget.reserve_first(MAX_REQUEST_BYTES).await,
            Err(ReadError::Capacity)
        ));
        let small = budget.reserve_first(SMALL).await.unwrap();
        assert!(small.reservation.small);
        drop(full);
        assert!(poll!(&mut other[0]).is_pending());
        drop(first);
        let next = other.remove(0).await.unwrap();
        assert_eq!(next.reservation.bytes, MAX_REQUEST_BYTES);
    }

    #[tokio::test]
    async fn a_failed_increment_keeps_its_lease_until_drop() {
        let budget = DataBodies::new();
        let shared = budget.reserve_first(MAX_REQUEST_BYTES).await.unwrap();
        let mut partial = budget.reserve_first(0).await.unwrap();
        budget.grow(&mut partial, SMALL).unwrap();
        assert!(matches!(
            budget.grow(&mut partial, SMALL + 1),
            Err(ReadError::Capacity)
        ));
        assert_eq!(partial.reservation.bytes, SMALL);
        assert!(partial.reservation.small);
        drop(shared);
        budget.grow(&mut partial, SMALL + 1).unwrap();
        assert!(!partial.reservation.small);
        assert!(budget.reserve_first(SMALL).await.unwrap().reservation.small);
    }
}
