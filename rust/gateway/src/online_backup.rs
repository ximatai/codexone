use codexone_execution::{ExecutionService, StoragePressure};
use codexone_maintenance::online::{
    BackupPressure, BackupStatus, INITIAL_DELAY, INTERVAL, OnlineBackup,
};
use tokio::{task::JoinHandle, time};
use tokio_util::sync::CancellationToken;

pub(crate) struct BackupTask {
    pub(crate) status: BackupStatus,
    stopping: CancellationToken,
    worker: JoinHandle<()>,
}

impl BackupTask {
    pub(crate) fn start(mut backup: OnlineBackup, execution: ExecutionService) -> Self {
        let status = backup.status();
        let stopping = CancellationToken::new();
        let cancel = stopping.clone();
        let worker = tokio::spawn(async move {
            let mut delay = INITIAL_DELAY;
            loop {
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => break,
                    _ = time::sleep(delay) => {}
                }
                let execution = execution.clone();
                // The blocking worker owns the lock lease until it exits, including on
                // cancellation. Wait for it even when shutdown arrives during the copy.
                match tokio::task::spawn_blocking(move || {
                    backup.perform(move || match execution.storage_pressure() {
                        StoragePressure::Normal => BackupPressure::Normal,
                        StoragePressure::Degraded => BackupPressure::Degraded,
                        StoragePressure::Blocked => BackupPressure::Blocked,
                        StoragePressure::Unknown => BackupPressure::Unknown,
                    });
                    backup
                })
                .await
                {
                    Ok(returned) => backup = returned,
                    Err(_) => {
                        eprintln!("Online backup worker stopped unexpectedly.");
                        break;
                    }
                }
                delay = INTERVAL;
            }
        });
        Self {
            status,
            stopping,
            worker,
        }
    }

    pub(crate) fn cancel(&self) {
        self.status.cancel();
        self.stopping.cancel();
    }

    pub(crate) async fn join(self) {
        let _ = self.worker.await;
    }
}
