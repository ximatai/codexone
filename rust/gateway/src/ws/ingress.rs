use std::pin::Pin;

use codexone_websocket::{CapacityExhausted, IngressBudget, IngressLease, IngressRefusal};

use crate::body_budget::{BodyPermit, DataBodies};

/// Both listeners and per-turn frame reservations refer to the data service's body budget.
pub(super) struct Ingress(pub DataBodies);

impl IngressBudget for Ingress {
    fn lease(&self) -> Box<dyn IngressLease> {
        Box::new(SocketBody {
            bodies: self.0.clone(),
            permit: None,
        })
    }
    fn rejected(&self, reason: IngressRefusal, bytes: usize) {
        let path = match reason {
            IngressRefusal::TooLarge => super::SizePath::Ingress,
            IngressRefusal::Capacity => super::SizePath::Budget,
        };
        super::record_size(path, bytes);
    }
}

struct SocketBody {
    bodies: DataBodies,
    permit: Option<BodyPermit>,
}

impl IngressLease for SocketBody {
    fn reserve_first(
        &mut self,
        bytes: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), CapacityExhausted>> + Send + '_>> {
        Box::pin(async move {
            self.permit = Some(
                self.bodies
                    .reserve_first(bytes)
                    .await
                    .map_err(|_| CapacityExhausted)?,
            );
            Ok(())
        })
    }

    fn grow(&mut self, total_bytes: usize) -> Result<(), CapacityExhausted> {
        self.bodies
            .grow(
                self.permit.as_mut().expect("first frame reserved"),
                total_bytes,
            )
            .map_err(|_| CapacityExhausted)
    }
}
