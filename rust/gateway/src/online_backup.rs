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
    pub(crate) fn start(backup: OnlineBackup, execution: ExecutionService) -> Self {
        Self::start_after(backup, execution, INITIAL_DELAY)
    }

    fn start_after(
        mut backup: OnlineBackup,
        execution: ExecutionService,
        initial_delay: std::time::Duration,
    ) -> Self {
        let status = backup.status();
        let stopping = CancellationToken::new();
        let cancel = stopping.clone();
        let worker = tokio::spawn(async move {
            let mut delay = initial_delay;
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

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use codexone_config::{Configuration, RuntimeConfiguration};

    use super::BackupTask;

    // Executed as a child process by scripts/rust_compat/online_backup.py.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn serve_backup_probe() {
        if std::env::var_os("CODEXONE_TEST_ONLINE_BACKUP").is_none() {
            return;
        }
        let runtime = RuntimeConfiguration::from_process().unwrap();
        let config = Configuration::load(runtime, crate::unix_time()).unwrap();
        // libtest can write the test name without a trailing newline.
        println!("\nONLINE_BACKUP_PROBE");
        let result = crate::gateway::run_with_backup(config, |mut backup, execution| {
            backup.after_first_batch(|| {
                println!("ONLINE_BACKUP_FIRST_BATCH");
                let mut line = String::new();
                std::io::stdin().read_line(&mut line).unwrap();
                assert_eq!(line.trim_end(), "continue");
            });
            BackupTask::start_after(backup, execution, Duration::ZERO)
        })
        .await;
        assert!(result.is_ok(), "gateway did not shut down cleanly");
    }
}
