use std::{sync::Arc, time::Duration};

use codexone_http_upstream::CancellationToken;
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore},
    time::timeout,
};

use crate::{ExecutionOutcome, ImageError};

/// One fair pool per data service. The caller bounds waiting requests via ingress capacity and
/// holds the permit through delivery and finalization, independently of durable accounting.
#[derive(Clone)]
pub struct ImageCapacity(Arc<Semaphore>);

pub struct ImagePermit {
    _permit: OwnedSemaphorePermit,
}

impl Default for ImageCapacity {
    fn default() -> Self {
        Self::new(2).expect("default Images capacity is valid")
    }
}

impl ImageCapacity {
    pub fn new(limit: usize) -> Result<Self, ImageError> {
        if !(1..=8).contains(&limit) {
            return Err(ImageError::new(
                500,
                "invalid_image_capacity",
                ExecutionOutcome::NotDispatched,
            ));
        }
        Ok(Self(Arc::new(Semaphore::new(limit))))
    }

    /// Acquire after authorization checks and before creating an execution intent.
    pub async fn acquire(
        &self,
        cancellation: &CancellationToken,
    ) -> Result<ImagePermit, ImageError> {
        tokio::select! {
            biased;
            _ = cancellation.cancelled() => Err(ImageError::cancelled(ExecutionOutcome::NotDispatched)),
            permit = timeout(Duration::from_secs(30), self.0.clone().acquire_owned()) => match permit {
                Ok(Ok(permit)) => Ok(ImagePermit { _permit: permit }),
                Ok(Err(_)) => unreachable!("the Images capacity pool is never closed"),
                Err(_) => {
                    let mut error = ImageError::new(429, "image_capacity_exhausted", ExecutionOutcome::NotDispatched);
                    error.retry_after = Some("1".to_owned());
                    error.cooldown_seconds = Some(1);
                    Err(error)
                }
            }
        }
    }
}
