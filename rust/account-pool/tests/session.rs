use std::{
    future::Future,
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};

use codexone_account_pool::{
    Error, Identity, PacingWaiters, SessionAffinity, SessionLabel, TurnStateOwners,
};

fn account(id: &str) -> Identity {
    Identity {
        id: id.into(),
        namespace: format!("synthetic:{id}"),
    }
}

#[test]
fn soft_labels_are_key_scoped_with_distinct_thread_and_session_behavior() {
    let affinity = SessionAffinity::default();
    let now = Instant::now();
    let a = account("a");
    let b = account("b");
    let labels = [
        (SessionLabel::SessionId, "same"),
        (SessionLabel::ThreadId, "same"),
    ];
    affinity.observe("key-a", &labels, &a, now);
    affinity.observe("key-a", &labels, &b, now + Duration::from_secs(1));
    assert_eq!(affinity.preferred("key-a", &labels, now), Some(b));
    assert_eq!(affinity.preferred("key-a", &labels[..1], now), Some(a));
    assert_eq!(affinity.preferred("key-b", &labels, now), None);
    assert_eq!(
        affinity.preferred("key-a", &labels, now + Duration::from_secs(3601)),
        None
    );
}

#[test]
fn turn_state_ownership_is_bounded_key_scoped_and_fails_closed_on_collision() {
    let states = TurnStateOwners::default();
    let now = Instant::now();
    let a = account("a");
    let b = account("b");
    states.observe("key-a", "shared", &a, now);
    assert_eq!(
        states.owner("key-b", "shared", now),
        Err(Error::ContinuationOwnerUnavailable)
    );
    assert_eq!(states.owner("key-a", "shared", now), Ok(a.clone()));
    states.observe("key-a", "shared", &b, now);
    states.observe("key-a", "shared", &a, now);
    assert_eq!(
        states.owner("key-a", "shared", now),
        Err(Error::ContinuationOwnerUnavailable)
    );
    for label in 0..1024 {
        states.observe(
            "key-a",
            &format!("state-{label}"),
            &a,
            now + Duration::from_secs(1),
        );
    }
    assert_eq!(
        states.owner("key-a", "state-0", now + Duration::from_secs(1)),
        Ok(a)
    );
    states.observe("key-a", "shared", &b, now + Duration::from_secs(1));
    assert_eq!(
        states.owner("key-a", "shared", now + Duration::from_secs(1)),
        Ok(b)
    );
}

#[tokio::test(start_paused = true)]
async fn waits_are_bounded_and_cancellation_and_close_release_slots() {
    let waiters = PacingWaiters::default();
    let duration = Duration::from_secs(15);
    let mut context = Context::from_waker(Waker::noop());
    let mut pending = Vec::new();
    for _ in 0..64 {
        let mut wait = Box::pin(waiters.wait(duration));
        assert_eq!(wait.as_mut().poll(&mut context), Poll::Pending);
        pending.push(wait);
    }
    assert_eq!(waiters.wait(duration).await, Err(Error::Capacity));
    pending.pop();
    assert_eq!(waiters.wait(Duration::from_secs(1)).await, Ok(()));
    let mut close = Box::pin(waiters.close());
    assert_eq!(close.as_mut().poll(&mut context), Poll::Pending);
    for mut wait in pending {
        assert_eq!(
            wait.as_mut().poll(&mut context),
            Poll::Ready(Err(Error::Closed))
        );
    }
    close.await;
    assert_eq!(waiters.wait(duration).await, Err(Error::Closed));
}
