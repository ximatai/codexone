use std::{
    future::ready,
    sync::{Arc, Mutex},
};

use codexone_execution::{Execution, Failure, Outcome};
use codexone_responses as protocol;
use codexone_websocket::{
    self as websocket, BridgeEvidence, BridgeFailure, BridgeOptions, ConnectFailure, Socket,
    SocketEnd, Utf8Bytes,
};
use tokio::time::Instant;

use super::attempt::{Evidence, connect_error};
use crate::response::{ResponseError, Transfer};

/// Execute a background turn in an already dispatched priming lease. The quota
/// worker owns the durable window barrier and the finalization of that same lease.
pub async fn discard_priming(
    connect: impl Future<Output = Result<Socket, ConnectFailure>>,
    frame: Utf8Bytes,
    lease: &mut Execution,
    transfer: Transfer,
    options: BridgeOptions,
) -> Outcome {
    let deadline = options.deadline;
    let evidence = Arc::new(Mutex::new(Evidence::default()));
    let observer = evidence.clone();
    let usage = transfer.usage;
    let began = transfer.began;
    let result = websocket::bridge(
        connect,
        frame,
        options,
        move |event| {
            let mut observation = observer.lock().unwrap();
            match event {
                BridgeEvidence::Event(event) => observation.event(event, usage, began),
                BridgeEvidence::PossibleProcessing => observation.possible_processing(),
            }
        },
        |output| ready(protocol::correlated_bindings(&output.document, false).map(|_| ())),
    )
    .await;

    let state = Arc::into_inner(evidence)
        .expect("reader stopped")
        .into_inner()
        .unwrap();
    let (failure, source, size_refusal) = match &result {
        Ok(()) => (None, None, false),
        Err(BridgeFailure::UnprocessedSizeRefusal { .. }) => {
            (Some(Failure::InvalidRequest), None, true)
        }
        Err(
            BridgeFailure::Provider(error)
            | BridgeFailure::BeforeSend(ConnectFailure::Rejected(error)),
        ) => (
            Some(ResponseError::from(error.protocol).failure()),
            Some(error.as_ref()),
            false,
        ),
        Err(BridgeFailure::BeforeSend(ConnectFailure::Cancelled))
        | Err(BridgeFailure::Interrupted {
            socket: Some(SocketEnd::Cancelled),
            ..
        }) => {
            let failure = if lease.was_force_stopped() {
                Failure::AccountUnavailable
            } else if Instant::now() >= deadline {
                Failure::DeadlineExceeded
            } else {
                Failure::ClientCancelled
            };
            (Some(failure), None, false)
        }
        Err(BridgeFailure::BeforeSend(_)) => {
            let Err(BridgeFailure::BeforeSend(error)) = result else {
                unreachable!()
            };
            let failure = connect_error(error, deadline).failure();
            (Some(failure), None, false)
        }
        Err(BridgeFailure::Interrupted { protocol, .. }) => {
            (Some(ResponseError::from(*protocol).failure()), None, false)
        }
    };
    state.outcome(lease, usage, began, failure, source, size_refusal)
}
