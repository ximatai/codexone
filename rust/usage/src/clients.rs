use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use tokio::sync::watch;

use crate::ClientActivity;

pub struct DataClients {
    connected: Mutex<Connected>,
    revision: watch::Sender<u64>,
}

impl Default for DataClients {
    fn default() -> Self {
        Self {
            connected: Mutex::default(),
            revision: watch::channel(0).0,
        }
    }
}

#[derive(Default)]
struct Connected {
    next: u64,
    entries: BTreeMap<u64, (String, i64)>,
}

pub struct DataClient {
    owner: Arc<DataClients>,
    id: u64,
}

impl DataClients {
    // Called only by a connection that already owns a data listener slot.
    pub fn register(self: &Arc<Self>, key_id: &str) -> DataClient {
        let mut connected = self.connected.lock().expect("data client registry");
        let id = connected.next;
        connected.next = id.wrapping_add(1);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs() as i64)
            .unwrap_or(0);
        connected.entries.insert(id, (key_id.to_owned(), now));
        drop(connected);
        self.notify();
        DataClient {
            owner: self.clone(),
            id,
        }
    }

    pub fn revision(&self) -> watch::Receiver<u64> {
        self.revision.subscribe()
    }

    fn notify(&self) {
        if self.revision.receiver_count() > 0 {
            self.revision
                .send_modify(|revision| *revision = revision.wrapping_add(1));
        }
    }

    pub fn snapshot(&self) -> Vec<ClientActivity> {
        let connected = self.connected.lock().expect("data client registry");
        let mut keys = BTreeMap::<_, (u32, i64)>::new();
        for (key, at) in connected.entries.values() {
            let (count, earliest) = keys.entry(key).or_insert((0, *at));
            *count += 1;
            *earliest = (*earliest).min(*at);
        }
        keys.into_iter()
            .map(|(key, (count, at))| ClientActivity {
                key_id: key.clone(),
                display_name: None,
                count,
                connected_at_unix_seconds: at,
            })
            .collect()
    }
}

impl Drop for DataClient {
    fn drop(&mut self) {
        self.owner
            .connected
            .lock()
            .expect("data client registry")
            .entries
            .remove(&self.id);
        self.owner.notify();
    }
}
