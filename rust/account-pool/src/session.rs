use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

use sha2::{Digest, Sha256};

use crate::{Error, Identity, Result, valid_field};

const TTL: Duration = Duration::from_secs(3600);
const CAPACITY: usize = 1024;
type Hash = [u8; 32];

struct Entry<T> {
    value: T,
    observed: Instant,
}

type Entries<T> = HashMap<Hash, Entry<T>>;

fn prune<T>(entries: &mut Entries<T>, now: Instant) {
    entries.retain(|_, entry| now.saturating_duration_since(entry.observed) < TTL);
}

fn insert<T>(entries: &mut Entries<T>, digest: Hash, value: T, now: Instant) {
    if entries.len() >= CAPACITY
        && !entries.contains_key(&digest)
        && let Some(oldest) = entries
            .iter()
            .min_by_key(|(hash, entry)| (entry.observed, *hash))
            .map(|(&hash, _)| hash)
    {
        entries.remove(&oldest);
    }
    entries.insert(
        digest,
        Entry {
            value,
            observed: now,
        },
    );
}

fn digest(key: &str, label: Option<SessionLabel>, value: &str) -> Hash {
    let mut hash = Sha256::new();
    hash.update(key);
    hash.update([0]);
    if let Some(label) = label {
        hash.update(label.name());
        hash.update([0]);
    }
    hash.update(value);
    hash.finalize().into()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionLabel {
    ThreadId,
    SessionId,
    SessionIdUnderscore,
    XSessionId,
    ConversationIdUnderscore,
    XConversationId,
}

impl SessionLabel {
    const PRIORITY: [Self; 6] = [
        Self::ThreadId,
        Self::SessionId,
        Self::SessionIdUnderscore,
        Self::XSessionId,
        Self::ConversationIdUnderscore,
        Self::XConversationId,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Self::ThreadId => "thread-id",
            Self::SessionId => "session-id",
            Self::SessionIdUnderscore => "session_id",
            Self::XSessionId => "x-session-id",
            Self::ConversationIdUnderscore => "conversation_id",
            Self::XConversationId => "x-conversation-id",
        }
    }
}

fn labels<'a>(
    key: &'a str,
    headers: &'a [(SessionLabel, &str)],
) -> impl Iterator<Item = (SessionLabel, Hash)> + 'a {
    SessionLabel::PRIORITY.into_iter().filter_map(move |label| {
        let (_, value) = headers.iter().find(|(name, _)| *name == label)?;
        (!value.is_empty() && value.len() <= 8192).then(|| (label, digest(key, Some(label), value)))
    })
}

/// Key-scoped soft preferences. Each transport supplies its first value for each known label.
#[derive(Default)]
pub struct SessionAffinity {
    entries: Mutex<Entries<Identity>>,
}

impl SessionAffinity {
    pub fn preferred(
        &self,
        key: &str,
        headers: &[(SessionLabel, &str)],
        now: Instant,
    ) -> Option<Identity> {
        if !valid_field(key, 256) {
            return None;
        }
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        prune(&mut entries, now);
        labels(key, headers)
            .find_map(|(_, hash)| entries.get(&hash).map(|entry| entry.value.clone()))
    }

    pub fn observe(
        &self,
        key: &str,
        headers: &[(SessionLabel, &str)],
        account: &Identity,
        now: Instant,
    ) {
        if !valid_field(key, 256) || !account.valid() {
            return;
        }
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        prune(&mut entries, now);
        for (label, hash) in labels(key, headers) {
            if label == SessionLabel::ThreadId || !entries.contains_key(&hash) {
                insert(&mut entries, hash, account.clone(), now);
            }
        }
    }
}

/// Key-scoped owners of trusted upstream turn-state. A token observed on different accounts
/// remains ambiguous until the entry expires. A token never grants object or draining access.
#[derive(Default)]
pub struct TurnStateOwners {
    entries: Mutex<Entries<Option<Identity>>>,
}

impl TurnStateOwners {
    pub fn valid_token(token: &str) -> bool {
        !token.is_empty()
            && token.len() <= 8192
            && token
                .bytes()
                .all(|byte| byte == 9 || (byte >= 32 && byte != 127))
    }

    pub fn owner(&self, key: &str, token: &str, now: Instant) -> Result<Identity> {
        if !valid_field(key, 256) || !Self::valid_token(token) {
            return Err(Error::InvalidCommand);
        }
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        prune(&mut entries, now);
        let owner = entries
            .get_mut(&digest(key, None, token))
            .ok_or(Error::ContinuationOwnerUnavailable)?;
        let account = owner
            .value
            .clone()
            .ok_or(Error::ContinuationOwnerUnavailable)?;
        owner.observed = now;
        Ok(account)
    }

    pub fn observe(&self, key: &str, token: &str, account: &Identity, now: Instant) {
        if !valid_field(key, 256) || !Self::valid_token(token) || !account.valid() {
            return;
        }
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        prune(&mut entries, now);
        let hash = digest(key, None, token);
        if let Some(entry) = entries.get_mut(&hash) {
            if entry.value.as_ref() != Some(account) {
                entry.value = None;
            }
            entry.observed = now;
        } else {
            insert(&mut entries, hash, Some(account.clone()), now);
        }
    }
}
