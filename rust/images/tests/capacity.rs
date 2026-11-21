use std::time::Duration;

use codexone_http_upstream::{CancellationToken, Instant};
use codexone_images::{ExecutionOutcome, ImageCapacity};

#[tokio::test(start_paused = true)]
async fn capacity_timeout_and_waiter_cancellation_do_not_leak_slots() {
    assert!(ImageCapacity::new(0).is_err());
    assert!(ImageCapacity::new(9).is_err());
    let pool = ImageCapacity::new(1).unwrap();
    let held = pool.acquire(&CancellationToken::new()).await.unwrap();
    let started = Instant::now();
    let error = pool.acquire(&CancellationToken::new()).await.err().unwrap();
    assert_eq!(Instant::now() - started, Duration::from_secs(30));
    assert_eq!(
        (error.status, error.code),
        (429, "image_capacity_exhausted")
    );
    assert_eq!(error.outcome, ExecutionOutcome::NotDispatched);
    assert_eq!(error.retry_header().as_deref(), Some("1"));

    let cancellation = CancellationToken::new();
    let peer = cancellation.clone();
    let cancelling = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(1)).await;
        peer.cancel();
    });
    let error = pool.acquire(&cancellation).await.err().unwrap();
    assert_eq!(error.outcome, ExecutionOutcome::NotDispatched);
    assert!(error.cancelled);
    cancelling.await.unwrap();
    drop(held);
    assert!(pool.acquire(&cancellation).await.is_err());
    let permit = pool.acquire(&CancellationToken::new()).await.unwrap();
    drop(permit);
    assert!(pool.acquire(&CancellationToken::new()).await.is_ok());
}
