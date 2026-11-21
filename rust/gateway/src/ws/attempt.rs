use std::sync::Mutex;

use codexone_execution::{Execution, Failure, IncompleteReason, Outcome};
use codexone_responses::{self as protocol, JsonValue, ProtocolError, Terminal, UsageConfig};
use tokio::{sync, time::Instant};

use crate::response::{self, ResponseError};

const INDETERMINATE: ProtocolError = ProtocolError::new(502, "execution_indeterminate");

/// The socket reader owns evidence independently of any asynchronous binding or write.
pub struct Attempt {
    lease: sync::Mutex<Option<Execution>>,
    usage: UsageConfig<'static>,
    began: Instant,
    pub encoded_bytes: usize,
    pub request_id: Option<String>,
    pub credential_version: Option<i64>,
    evidence: Mutex<Evidence>,
}

#[derive(Default)]
pub(super) struct Evidence {
    processed: bool,
    first_event: Option<i64>,
    usage: Vec<protocol::UsageEvidence>,
    terminal: Option<(Terminal, Option<String>)>,
    completed_id: Option<String>,
    error: Option<ProtocolError>,
}

impl Attempt {
    pub fn new(
        lease: Execution,
        usage: UsageConfig<'static>,
        began: Instant,
        encoded_bytes: usize,
    ) -> Self {
        let request_id = lease.admission().request_id.clone();
        let credential_version = lease
            .admission()
            .account_snapshot
            .as_ref()
            .map(|account| account.credential_version);
        Self {
            request_id,
            credential_version,
            lease: sync::Mutex::new(Some(lease)),
            usage,
            began,
            encoded_bytes,
            evidence: Mutex::default(),
        }
    }

    pub fn images(&self) -> bool {
        self.usage.image.is_some()
    }

    pub fn possible_processing(&self) {
        self.evidence.lock().unwrap().possible_processing();
    }

    pub fn event(&self, event: &JsonValue) {
        self.evidence
            .lock()
            .unwrap()
            .event(event, self.usage, self.began);
    }

    pub fn has_first_event(&self) -> bool {
        self.evidence.lock().unwrap().first_event.is_some()
    }

    pub async fn bind(&self, document: &JsonValue, unwrapped: bool) -> Result<(), ProtocolError> {
        if let Some(error) = self.evidence.lock().unwrap().error {
            return Err(error);
        }
        let bindings = if unwrapped {
            protocol::terminal_bindings(document, self.images())?
        } else {
            protocol::correlated_bindings(document, self.images())?
        };
        if !bindings.is_empty() {
            self.lease
                .lock()
                .await
                .as_mut()
                .expect("active execution")
                .bind(&response::bindings(bindings))
                .await
                .map_err(|error| ResponseError::from(error).protocol)?;
        }
        Ok(())
    }

    pub fn finish(
        mut self,
        failure: Option<Failure>,
        provider: Option<&protocol::ProviderFailure>,
        size_refusal: bool,
    ) -> (Execution, Outcome) {
        let lease = self.take_lease();
        self.finalize(lease, failure, provider, size_refusal)
    }

    fn finalize(
        &mut self,
        mut lease: Execution,
        failure: Option<Failure>,
        provider: Option<&protocol::ProviderFailure>,
        size_refusal: bool,
    ) -> (Execution, Outcome) {
        let state = std::mem::take(self.evidence.get_mut().unwrap());
        let outcome = state.outcome(
            &mut lease,
            self.usage,
            self.began,
            failure,
            provider,
            size_refusal,
        );
        (lease, outcome)
    }

    pub async fn begin_dispatch(&self) -> Result<(), ProtocolError> {
        self.lease
            .lock()
            .await
            .as_mut()
            .expect("active execution")
            .begin_dispatch()
            .map_err(|error| ResponseError::from(error).protocol)
    }

    pub fn dispatch(&mut self) -> Result<(), ProtocolError> {
        self.lease
            .get_mut()
            .as_mut()
            .expect("active execution")
            .begin_dispatch()
            .map_err(|error| ResponseError::from(error).protocol)
    }

    pub fn completed_id(&mut self) -> Option<String> {
        self.evidence.get_mut().unwrap().completed_id.take()
    }

    pub fn id(&mut self) -> &str {
        &self
            .lease
            .get_mut()
            .as_ref()
            .expect("active execution")
            .admission()
            .attempt
    }

    pub fn take_lease(&mut self) -> Execution {
        self.lease.get_mut().take().expect("active execution")
    }
}

impl Drop for Attempt {
    fn drop(&mut self) {
        if let Some(lease) = self.lease.get_mut().take() {
            let (lease, outcome) =
                self.finalize(lease, Some(Failure::ClientCancelled), None, false);
            let _ = lease.finish(Some(outcome));
        }
    }
}

impl Evidence {
    pub fn possible_processing(&mut self) {
        self.processed = true;
    }

    pub fn event(&mut self, event: &JsonValue, config: UsageConfig<'_>, began: Instant) {
        self.first_event
            .get_or_insert_with(|| response::milliseconds(began));
        if let Err(error) =
            protocol::correlated_usage(event, config, self.processed, &mut self.usage)
        {
            self.error = Some(error);
        }
        self.processed |= !protocol::EventSemantics::classify(event).connection_metadata;
        if let Some(terminal) = protocol::event_terminal(event) {
            if terminal.0 == Terminal::Completed
                && let Some(response) = event.get("response")
                && response.get("status").and_then(JsonValue::as_str) == Some("completed")
            {
                self.completed_id = response
                    .get("id")
                    .and_then(JsonValue::as_str)
                    .map(str::to_owned);
            }
            self.terminal = Some(terminal);
        }
    }

    pub fn outcome(
        self,
        lease: &mut Execution,
        config: UsageConfig<'_>,
        began: Instant,
        failure: Option<Failure>,
        provider: Option<&protocol::ProviderFailure>,
        size_refusal: bool,
    ) -> Outcome {
        let mut failure =
            failure.or_else(|| self.error.map(|error| ResponseError::from(error).failure()));
        for usage in self.usage {
            if lease.observe(response::evidence(usage)).is_err() {
                failure.get_or_insert(Failure::StorageUnavailable);
            }
        }
        if size_refusal {
            let _ = lease.observe(response::evidence(
                protocol::UsageEvidence::provider_rejection(config.image.is_some()),
            ));
        }
        let failure = failure
            .or_else(|| terminal_failure(self.terminal.as_ref().map(|(terminal, _)| *terminal)));
        let mut outcome = Outcome::new(failure, crate::unix_time());
        outcome.total_milliseconds = Some(response::milliseconds(began));
        outcome.first_event_milliseconds = self.first_event;
        if let Some((terminal, tier)) = self.terminal {
            outcome.actual_service_tier = tier;
            if let Terminal::Incomplete(reason) = terminal
                && outcome.failure == Some(Failure::Indeterminate)
            {
                use protocol::IncompleteReason as Wire;
                outcome.upstream_incomplete_reason = Some(match reason {
                    Wire::MaxOutputTokens => IncompleteReason::MaxOutputTokens,
                    Wire::MaxMessages => IncompleteReason::MaxMessages,
                    Wire::ContentFilter => IncompleteReason::ContentFilter,
                    Wire::Steered => IncompleteReason::Steered,
                    Wire::Unspecified => IncompleteReason::Unspecified,
                });
            }
        }
        if matches!(
            outcome.failure,
            Some(Failure::RateLimited | Failure::UpstreamUnavailable)
        ) {
            outcome.cooldown_seconds =
                provider.and_then(|error| error.account_cooldown(outcome.at_unix_seconds));
        }
        outcome
    }
}

fn terminal_failure(terminal: Option<Terminal>) -> Option<Failure> {
    match terminal {
        Some(Terminal::Completed) => None,
        Some(Terminal::Failed) => Some(Failure::UpstreamRejected),
        Some(Terminal::Incomplete(_)) | None => Some(Failure::Indeterminate),
    }
}

pub(super) fn connect_error(
    error: codexone_websocket::ConnectFailure,
    deadline: Instant,
) -> ResponseError {
    use codexone_websocket::ConnectFailure;
    match error {
        ConnectFailure::Rejected(failure) => ResponseError::from(failure),
        ConnectFailure::TransportSetup(error) => match error {
            codexone_http_upstream::Error::ProxyConnect
            | codexone_http_upstream::Error::ProxyAuthenticationRequired => error.into(),
            _ => ProtocolError::new(502, "upstream_connect_failed").into(),
        },
        ConnectFailure::TimedOut if Instant::now() >= deadline => {
            ProtocolError::new(504, "execution_deadline_exceeded").into()
        }
        ConnectFailure::Cancelled => INDETERMINATE.into(),
        _ => ProtocolError::new(502, "upstream_connect_failed").into(),
    }
}
