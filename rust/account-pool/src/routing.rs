use std::{collections::HashSet, time::Duration};

use rusqlite::{Connection, Transaction, params};

use crate::{
    ACCOUNT_CAPACITY, Error, Health, Identity, MAX_ACCOUNTS, MAX_PACING_WAIT, MAX_TIME, Reference,
    Result, health::Availability, unix_seconds, valid_field,
};

const BINDING_TTL_SECONDS: i64 = 30 * 86_400;
const PREFERRED_WAIT: Duration = Duration::from_secs(3);

/// Prepared from a trusted account record and decrypted credential outside the writer.
#[derive(Clone, Debug)]
pub struct Candidate {
    pub identity: Identity,
    pub revision: i64,
    pub credential_version: i64,
    pub access_expires_at_unix_seconds: i64,
    pub continuation: bool,
}

impl Candidate {
    fn valid(&self) -> bool {
        self.identity.valid()
            && (1..=1_000_000).contains(&self.revision)
            && (1..=1_000_000).contains(&self.credential_version)
            && (1..=MAX_TIME).contains(&self.access_expires_at_unix_seconds)
    }
}

pub struct Selection<'a> {
    pub principal: &'a str,
    pub model: &'a str,
    /// Request ID, falling back to the attempt ID.
    pub seed: &'a str,
    pub candidates: &'a [Candidate],
    pub references: &'a [Reference<'a>],
    pub connection: Option<&'a Identity>,
    /// Verified turn-state owner. It restricts selection without granting draining access.
    pub required: Option<&'a Identity>,
    pub preferred: Option<&'a Identity>,
}

fn binding_owners(
    db: &Connection,
    principal: &str,
    reference: Reference<'_>,
    connection: Option<&Identity>,
    now: i64,
    limit: i64,
) -> Result<HashSet<Identity>> {
    let mut stmt = db.prepare_cached(
        "SELECT DISTINCT b.identity,b.namespace FROM bindings b
         JOIN accounts a ON a.id=b.identity AND a.namespace=b.namespace
         WHERE b.principal=?1 AND b.object_type=?2 AND b.raw_id=?3 AND b.expires_at_epoch>?4
           AND (?5 IS NULL OR (b.identity=?5 AND b.namespace=?6)) LIMIT ?7",
    )?;
    let rows = stmt.query_map(
        params![
            principal,
            reference.kind,
            reference.raw_id,
            now,
            connection.map(|owner| &owner.id),
            connection.map(|owner| &owner.namespace),
            limit
        ],
        |row| {
            Ok(Identity {
                id: row.get(0)?,
                namespace: row.get(1)?,
            })
        },
    )?;
    let mut owners = HashSet::new();
    for row in rows {
        let identity = row?;
        if !identity.valid() {
            return Err(Error::StorageUnavailable);
        }
        owners.insert(identity);
    }
    Ok(owners)
}

/// Resolve before preparing credentials. Admission recomputes the intersection under the writer.
pub fn resolve_affinity(
    db: &Connection,
    principal: &str,
    references: &[Reference<'_>],
    connection: Option<&Identity>,
    now: i64,
) -> Result<Option<Identity>> {
    if !valid_field(principal, 256)
        || references.len() > 32
        || references.iter().any(|reference| !reference.valid())
        || connection.is_some_and(|owner| !owner.valid())
        || !(1..=MAX_TIME).contains(&now)
    {
        return Err(Error::InvalidCommand);
    }
    let mut matching = connection.cloned().map(|owner| HashSet::from([owner]));
    for &reference in references {
        let mut owners = binding_owners(
            db,
            principal,
            reference,
            connection,
            now,
            MAX_ACCOUNTS as i64 + 1,
        )?;
        if owners.len() > MAX_ACCOUNTS {
            return Err(Error::AmbiguousObject);
        }
        if let Some(prior) = &matching {
            owners.retain(|owner| prior.contains(owner));
        }
        if owners.is_empty() {
            return Err(Error::UnknownObject);
        }
        matching = Some(owners);
    }
    match matching {
        Some(owners) if owners.len() != 1 => Err(Error::AmbiguousObject),
        Some(owners) => Ok(owners.into_iter().next()),
        None => Ok(None),
    }
}

/// Look at the most recent 64 soft hints. Missing or ambiguous hints grant no affinity.
pub fn resolve_hint(
    db: &Connection,
    principal: &str,
    hints: &[Reference<'_>],
    now: i64,
) -> Result<Option<Identity>> {
    if !valid_field(principal, 256) || !(1..=MAX_TIME).contains(&now) {
        return Err(Error::InvalidCommand);
    }
    for &hint in hints.iter().rev().take(64).filter(|hint| hint.valid()) {
        let owners = binding_owners(db, principal, hint, None, now, 2)?;
        if owners.len() == 1 {
            return Ok(owners.into_iter().next());
        }
    }
    Ok(None)
}

/// Select and insert the intent on the caller's immediate transaction. Roll back the transaction
/// on every error. `check_key` runs once before an eligible selection or a pacing response.
/// `allows_account` checks the current model catalog and any configured account pin.
/// `insert_intent` uses the already-verified owner and writes the normal ledger admission.
/// A `Wait` result holds neither an intent nor a database resource after the caller rolls back.
pub fn admit<T, E: From<Error>>(
    tx: &Transaction<'_>,
    health: &Health,
    selection: Selection<'_>,
    now_micros: i64,
    check_key: impl FnOnce(&Transaction<'_>, i64) -> std::result::Result<(), E>,
    allows_account: impl FnMut(&Transaction<'_>, &Candidate) -> std::result::Result<bool, E>,
    insert_intent: impl FnOnce(&Transaction<'_>, &Candidate, i64) -> std::result::Result<T, E>,
) -> std::result::Result<T, E> {
    let now = unix_seconds(now_micros)?;
    let mut ids = HashSet::new();
    if !(1..=MAX_ACCOUNTS).contains(&selection.candidates.len())
        || !valid_field(selection.model, 128)
        || !valid_field(selection.seed, 256)
        || [selection.preferred, selection.required]
            .into_iter()
            .flatten()
            .any(|id| !id.valid())
        || selection
            .candidates
            .iter()
            .any(|candidate| !candidate.valid() || !ids.insert(&candidate.identity.id))
    {
        return Err(Error::InvalidCommand.into());
    }
    let affinity = resolve_affinity(
        tx,
        selection.principal,
        selection.references,
        selection.connection,
        now,
    )?;
    let decision = rank(
        tx,
        health,
        &selection,
        affinity.as_ref(),
        now_micros,
        allows_account,
    )?;
    check_key(tx, now)?;
    let selected = match decision {
        Ranked::Account(candidate) => candidate,
        Ranked::Pacing(duration) if duration <= MAX_PACING_WAIT => {
            return Err(Error::Wait(duration).into());
        }
        Ranked::Pacing(duration) => {
            return Err(Error::Cooldown {
                retry_after_seconds: duration.as_micros().div_ceil(1_000_000) as u64,
            }
            .into());
        }
    };
    let output = insert_intent(tx, selected, now)?;
    if selection.references.is_empty() {
        return Ok(output);
    }
    let mut renew = tx
        .prepare_cached(
            "UPDATE bindings SET expires_at_epoch=?1 WHERE principal=?2 AND namespace=?3
         AND identity=?4 AND object_type=?5 AND raw_id=?6",
        )
        .map_err(Error::from)?;
    for reference in selection.references {
        renew
            .execute(params![
                now + BINDING_TTL_SECONDS,
                selection.principal,
                selected.identity.namespace,
                selected.identity.id,
                reference.kind,
                reference.raw_id
            ])
            .map_err(Error::from)?;
    }
    Ok(output)
}

enum Ranked<'a> {
    Account(&'a Candidate),
    Pacing(Duration),
}

fn rank<'a, E: From<Error>>(
    tx: &Transaction<'_>,
    health: &Health,
    selection: &Selection<'a>,
    affinity: Option<&Identity>,
    now_micros: i64,
    mut allows_account: impl FnMut(&Transaction<'_>, &Candidate) -> std::result::Result<bool, E>,
) -> std::result::Result<Ranked<'a>, E> {
    let now = unix_seconds(now_micros)?;
    let mut healthy = Vec::new();
    let mut shortest = None::<Duration>;
    let mut at_capacity = false;
    let mut preferred_wait = None;
    for candidate in selection.candidates {
        let identity = &candidate.identity;
        let continuation = affinity == Some(identity);
        if (affinity.is_some() && !continuation)
            || candidate.continuation != continuation
            || selection
                .required
                .is_some_and(|required| required != identity)
            || !current(tx, candidate, now)?
            || !allows_account(tx, candidate)?
        {
            continue;
        }
        let availability = health.availability(tx, candidate, selection.model, now_micros)?;
        if availability == Availability::Blocked {
            continue;
        }
        let active: i64 = tx.query_row(
            "SELECT COUNT(*) FROM attempts WHERE namespace=?1 AND identity=?2 AND state='intent'",
            params![identity.namespace, identity.id], |row| row.get(0),
        ).map_err(Error::from)?;
        if active >= ACCOUNT_CAPACITY {
            at_capacity = true;
            continue;
        }
        let preferred = selection.preferred == Some(identity);
        if let Availability::Pacing(delay) = availability {
            shortest = Some(shortest.map_or(delay, |previous| previous.min(delay)));
            if preferred && delay <= PREFERRED_WAIT {
                preferred_wait = Some(delay);
            }
        } else {
            healthy.push((
                !preferred,
                active,
                route_tie(selection.seed, identity),
                candidate,
            ));
        }
    }
    if let Some(wait) = preferred_wait {
        return Ok(Ranked::Pacing(wait));
    }
    if let Some((_, _, _, candidate)) = healthy.into_iter().min_by(|left, right| {
        (&left.0, &left.1, &left.2, &left.3.identity.id).cmp(&(
            &right.0,
            &right.1,
            &right.2,
            &right.3.identity.id,
        ))
    }) {
        return Ok(Ranked::Account(candidate));
    }
    if let Some(wait) = shortest {
        return Ok(Ranked::Pacing(wait));
    }
    Err(if at_capacity {
        Error::AccountConcurrency
    } else {
        Error::AccountUnavailable
    }
    .into())
}

fn current(tx: &Transaction<'_>, candidate: &Candidate, now: i64) -> Result<bool> {
    if candidate.access_expires_at_unix_seconds <= now {
        return Ok(false);
    }
    Ok(tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND namespace=?2 AND revision=?3
         AND credential_version=?4 AND authorization='ready'
         AND (mode='enabled' OR (mode='draining' AND ?5)))",
        params![
            candidate.identity.id,
            candidate.identity.namespace,
            candidate.revision,
            candidate.credential_version,
            candidate.continuation
        ],
        |row| row.get(0),
    )?)
}

fn route_tie(seed: &str, identity: &Identity) -> u64 {
    seed.bytes()
        .chain([0])
        .chain(identity.namespace.bytes())
        .chain([0])
        .chain(identity.id.bytes())
        .fold(14_695_981_039_346_656_037, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(1_099_511_628_211)
        })
}
