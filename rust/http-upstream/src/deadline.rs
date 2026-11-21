use std::{future::pending, time::Duration};

use tokio::{
    sync::watch,
    time::{Instant, sleep_until},
};

use crate::{Error, ExchangeOptions};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Uploading(Option<Instant>),
    FirstResponse(Instant),
    Responding(Option<Instant>),
    Rejected,
}

impl Stage {
    fn expiry(self) -> Option<(Instant, Error)> {
        match self {
            Self::Uploading(deadline) | Self::Responding(deadline) => {
                deadline.map(|deadline| (deadline, Error::ProgressTimeout))
            }
            Self::FirstResponse(deadline) => Some((deadline, Error::FirstResponseTimeout)),
            Self::Rejected => None,
        }
    }
}

#[derive(Clone)]
pub(crate) struct Progress {
    stage: watch::Sender<Stage>,
    first_response: Duration,
    upload_idle: Option<Duration>,
    response_idle: Option<Duration>,
}

impl Progress {
    pub(crate) fn new(options: &ExchangeOptions) -> Self {
        Self {
            stage: watch::Sender::new(Stage::Uploading(None)),
            first_response: options.first_response_timeout,
            upload_idle: options.upload_idle_timeout,
            response_idle: options.response_idle_timeout,
        }
    }

    pub(crate) fn upload_progress(&self) {
        if let Some(idle) = self.upload_idle {
            self.update(|stage| match stage {
                Stage::Uploading(_) => Stage::Uploading(Some(Instant::now() + idle)),
                stage => stage,
            });
        }
    }

    pub(crate) fn uploaded(&self) {
        self.update(|stage| match stage {
            Stage::Uploading(_) => Stage::FirstResponse(Instant::now() + self.first_response),
            stage => stage,
        });
    }

    pub(crate) fn response_progress(&self) {
        self.update(|stage| match stage {
            Stage::Rejected => stage,
            _ => Stage::Responding(self.response_idle.map(|idle| Instant::now() + idle)),
        });
    }

    pub(crate) fn rejected(&self) {
        self.update(|_| Stage::Rejected);
    }

    pub(crate) fn expired(&self) -> Option<Error> {
        self.stage
            .borrow()
            .expiry()
            .filter(|(deadline, _)| *deadline <= Instant::now())
            .map(|(_, error)| error)
    }

    pub(crate) async fn wait_for_expiry(&self) -> Error {
        let mut changes = self.stage.subscribe();
        loop {
            let expiry = changes.borrow_and_update().expiry();
            tokio::select! {
                biased;
                _ = changes.changed() => {}
                error = wait_until(expiry) => return error,
            }
        }
    }

    fn update(&self, change: impl FnOnce(Stage) -> Stage) {
        self.stage.send_if_modified(|stage| {
            let next = change(*stage);
            let changed = *stage != next;
            *stage = next;
            changed
        });
    }
}

async fn wait_until(expiry: Option<(Instant, Error)>) -> Error {
    match expiry {
        Some((deadline, error)) => {
            sleep_until(deadline).await;
            error
        }
        None => pending().await,
    }
}
