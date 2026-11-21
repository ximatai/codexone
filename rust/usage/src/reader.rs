use std::{
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use rusqlite::{Connection, OpenFlags, Transaction};
use tokio::sync::Semaphore;

use crate::{Error, Result};

#[derive(Clone)]
pub struct Reader {
    connection: Arc<Mutex<Option<Connection>>>,
    slot: Arc<Semaphore>,
    timeout: Duration,
    optional_allowed: Arc<dyn Fn() -> bool + Send + Sync>,
}

struct CancelOnDrop(Arc<AtomicBool>);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

impl Reader {
    /// Call once for the active writer's canonical path, off the network runtime.
    /// Wire the writer's cached health and shutdown state into `optional_allowed`.
    pub fn open(
        path: &Path,
        timeout: Duration,
        optional_allowed: impl Fn() -> bool + Send + Sync + 'static,
    ) -> Result<Self> {
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(Duration::ZERO)?;
        connection.pragma_update(None, "query_only", true)?;
        let journal: String =
            connection.pragma_query_value(None, "journal_mode", |row| row.get(0))?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if journal != "wal" || version != 19 {
            return Err(Error::Unavailable);
        }
        Ok(Self {
            connection: Arc::new(Mutex::new(Some(connection))),
            slot: Arc::new(Semaphore::new(1)),
            timeout,
            optional_allowed: Arc::new(optional_allowed),
        })
    }

    pub async fn close(&self) -> Result<()> {
        self.slot.close();
        let connection = self.connection.clone();
        tokio::task::spawn_blocking(move || {
            let mut connection = connection.lock().map_err(|_| Error::Unavailable)?;
            if let Some(connection) = connection.take() {
                connection.close().map_err(|(_, error)| error)?;
            }
            Ok(())
        })
        .await
        .map_err(|_| Error::Unavailable)?
    }

    pub async fn read<T: Send + 'static>(
        &self,
        operation: impl FnOnce(&Transaction<'_>) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let permit = self
            .slot
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::Capacity)?;
        let connection = self.connection.clone();
        let slot = self.slot.clone();
        let optional_allowed = self.optional_allowed.clone();
        let deadline = Instant::now()
            .checked_add(self.timeout)
            .ok_or(Error::Invalid)?;
        let cancelled = Arc::new(AtomicBool::new(false));
        let _cancel = CancelOnDrop(cancelled.clone());
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let stop = move || {
                cancelled.load(Ordering::Relaxed)
                    || slot.is_closed()
                    || Instant::now() >= deadline
                    || !optional_allowed()
            };
            if stop() {
                return Err(Error::Capacity);
            }
            let mut guard = connection.lock().map_err(|_| Error::Unavailable)?;
            let connection = guard.as_mut().ok_or(Error::Capacity)?;
            connection.progress_handler(1_000, Some(stop.clone()))?;
            let result = (|| {
                let transaction = connection.unchecked_transaction()?;
                let result = operation(&transaction);
                if stop() {
                    return Err(Error::Capacity);
                }
                let value = result?;
                transaction.commit()?;
                Ok(value)
            })();
            connection.progress_handler(0, None::<fn() -> bool>)?;
            result
        })
        .await
        .map_err(|_| Error::Unavailable)?
    }
}
