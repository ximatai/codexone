use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use codexone_storage::{
    AccountCredentialCipher, AccountCredentialContext, Database, DatabaseError,
    ReencryptionCheckpoint, reencryption_checkpoint, require_free_space,
};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};

use crate::files;
use crate::record::read_record;
use crate::snapshot::{backup_locked, open_snapshot, require_integrity, verify_backup};
use crate::{
    Error, MIB, Result, audit, audit_reference, new_id, now, require_complete_reencryption,
};

struct CredentialRow {
    id: String,
    namespace: String,
    version: i64,
    revision: i64,
    envelope: String,
}

impl CredentialRow {
    fn context(&self) -> Result<AccountCredentialContext<'_>> {
        Ok(AccountCredentialContext::new(
            &self.id,
            &self.namespace,
            self.version,
        )?)
    }
}

fn credentials(db: &Connection, filter: Option<&str>) -> Result<Vec<CredentialRow>> {
    let mut statement = db.prepare(
        "SELECT CASE WHEN length(CAST(id AS BLOB))<=64 THEN id END,
                CASE WHEN length(CAST(namespace AS BLOB))<=512 THEN namespace END,
                credential_version,revision,
                CASE WHEN length(CAST(sealed_credential AS BLOB))<=49152 THEN sealed_credential END
           FROM accounts WHERE ?1 IS NULL OR sealed_credential NOT LIKE ?1
           ORDER BY id LIMIT ?2",
    )?;
    let limit = if filter.is_some() { 8 } else { 65 };
    let mut rows = statement.query(params![filter, limit])?;
    let mut credentials = Vec::new();
    while let Some(row) = rows.next()? {
        if credentials.len() == 64 {
            return Err(Error::Capacity);
        }
        credentials.push(CredentialRow {
            id: row.get::<_, Option<_>>(0)?.ok_or(Error::Capacity)?,
            namespace: row.get::<_, Option<_>>(1)?.ok_or(Error::Capacity)?,
            version: row.get(2)?,
            revision: row.get(3)?,
            envelope: row.get::<_, Option<_>>(4)?.ok_or(Error::Capacity)?,
        });
    }
    Ok(credentials)
}

pub(crate) fn verify_credentials(
    db: &Connection,
    protection: Option<&AccountCredentialCipher>,
) -> Result<Vec<String>> {
    let mut required = BTreeSet::new();
    for row in credentials(db, None)? {
        let key = protection.ok_or(Error::Credential)?;
        key.open(&row.envelope, &row.context()?)?;
        required.insert(AccountCredentialCipher::envelope_key_id(&row.envelope)?.to_owned());
    }
    Ok(required.into_iter().collect())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct KeyStatus<'a> {
    #[serde(rename = "activeKeyID")]
    active_key_id: &'a str,
    #[serde(rename = "availableKeyIDs")]
    available_key_ids: Vec<&'a str>,
    #[serde(rename = "requiredCurrentKeyIDs")]
    required_current_key_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    checkpoint: Option<ReencryptionCheckpoint>,
    backup_inventory_required: bool,
}

pub(crate) fn key_status<'a>(
    path: &Path,
    protection: &'a AccountCredentialCipher,
) -> Result<KeyStatus<'a>> {
    status(
        Database::open_for_credential_maintenance(path)?.connection(),
        protection,
    )
}

fn status<'a>(db: &Connection, protection: &'a AccountCredentialCipher) -> Result<KeyStatus<'a>> {
    Ok(KeyStatus {
        active_key_id: protection.key_id(),
        available_key_ids: protection.available_key_ids(),
        required_current_key_ids: verify_credentials(db, Some(protection))?,
        checkpoint: reencryption_checkpoint(db)?,
        backup_inventory_required: true,
    })
}

pub(crate) fn reencrypt<'a>(
    path: &Path,
    protection: &'a AccountCredentialCipher,
    destination: Option<&Path>,
) -> Result<KeyStatus<'a>> {
    reencrypt_with_checkpoint(path, protection, destination, |_| Ok(()))
}

fn reencrypt_with_checkpoint<'a>(
    path: &Path,
    protection: &'a AccountCredentialCipher,
    destination: Option<&Path>,
    after_commit: impl Fn(&ReencryptionCheckpoint) -> Result<()>,
) -> Result<KeyStatus<'a>> {
    let mut db = Database::open_for_credential_maintenance(path)?;
    let directory = files::parent(db.path())?.to_owned();
    let old = reencryption_checkpoint(db.connection())?;
    verify_credentials(db.connection(), Some(protection))?;

    let mut checkpoint = if let Some(destination) = destination {
        if old.is_some_and(|job| !job.complete) {
            return Err(DatabaseError::IncompleteReencryption.into());
        }
        let count: i64 =
            db.connection()
                .query_row("SELECT COUNT(*) FROM maintenance_events", [], |row| {
                    row.get(0)
                })?;
        if count > 990 {
            return Err(Error::Capacity);
        }
        let backup = backup_locked(db.connection(), db.path(), destination, Some(protection))?;
        let checkpoint = ReencryptionCheckpoint {
            job_id: new_id(db.connection())?,
            backup_id: backup.id,
            target_key_id: protection.key_id().into(),
            started_unix_seconds: now()?,
            rewritten: 0,
            complete: false,
        };
        let tx = db.begin_immediate()?;
        save_checkpoint(&tx, &checkpoint)?;
        tx.commit()?;
        after_commit(&checkpoint)?;
        checkpoint
    } else {
        let checkpoint = old.ok_or(Error::Conflict)?;
        if checkpoint.target_key_id != protection.key_id() {
            return Err(Error::WrongActiveKey);
        }
        checkpoint
    };

    let active_prefix = format!("v1.{}.%", protection.key_id());
    while !checkpoint.complete {
        require_free_space(&directory, 8 * MIB, true)?;
        let tx = db.begin_immediate()?;
        if reencryption_checkpoint(&tx)?.as_ref() != Some(&checkpoint) {
            return Err(Error::Conflict);
        }

        let rows = credentials(&tx, Some(&active_prefix))?;
        for row in &rows {
            let context = row.context()?;
            let credential = protection.open(&row.envelope, &context)?;
            let envelope = protection.seal(&credential, &context)?;
            protection.open(&envelope, &context)?;
            let changed = tx.execute(
                "UPDATE accounts SET sealed_credential=?1
                   WHERE id=?2 AND namespace=?3 AND credential_version=?4 AND revision=?5 AND sealed_credential=?6",
                params![envelope, row.id, row.namespace, row.version, row.revision, row.envelope],
            )?;
            if changed != 1 {
                return Err(Error::Conflict);
            }
        }
        checkpoint.rewritten += rows.len() as i64;
        let remaining: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE sealed_credential NOT LIKE ?1)",
            [&active_prefix],
            |row| row.get(0),
        )?;
        checkpoint.complete = !remaining;
        if checkpoint.complete
            && verify_credentials(&tx, Some(protection))?
                .iter()
                .any(|id| id != protection.key_id())
        {
            return Err(Error::Conflict);
        }
        save_checkpoint(&tx, &checkpoint)?;
        tx.commit()?;
        after_commit(&checkpoint)?;
    }
    status(db.connection(), protection)
}

fn save_checkpoint(db: &Connection, checkpoint: &ReencryptionCheckpoint) -> Result<()> {
    checkpoint.validate()?;
    audit(db, "credential_reencryption", checkpoint, now()?)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RetirementInventory {
    format: i64,
    inventory_complete: bool,
    audit_reference: String,
    retained_backups: Vec<PathBuf>,
    restore_drills: Vec<PathBuf>,
    legacy_databases: Vec<PathBuf>,
    legacy_restore_audit_reference: Option<String>,
}

impl RetirementInventory {
    fn validate(&self) -> Result<()> {
        if self.format != 1 || !self.inventory_complete || !audit_reference(&self.audit_reference) {
            return Err(Error::Invalid);
        }
        for paths in [
            &self.retained_backups,
            &self.restore_drills,
            &self.legacy_databases,
        ] {
            if paths.len() > 32
                || paths.iter().collect::<BTreeSet<_>>().len() != paths.len()
                || paths.iter().any(|path| {
                    let bytes = path.as_os_str().as_encoded_bytes();
                    !path.is_absolute() || bytes.contains(&0) || bytes.len() > 4096
                })
            {
                return Err(Error::Invalid);
            }
        }
        if !self.legacy_databases.is_empty()
            && !self
                .legacy_restore_audit_reference
                .as_deref()
                .is_some_and(audit_reference)
        {
            return Err(Error::Invalid);
        }
        Ok(())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RetirementEvidence<'a> {
    audit_reference: String,
    #[serde(rename = "activeKeyID")]
    active_key_id: &'a str,
    #[serde(rename = "availableKeyIDs")]
    available_key_ids: Vec<&'a str>,
    #[serde(rename = "requiredCurrentKeyIDs")]
    required_current_key_ids: Vec<String>,
    #[serde(rename = "requiredBackupKeyIDs")]
    required_backup_key_ids: BTreeSet<String>,
    #[serde(rename = "verifiedBackupIDs")]
    verified_backup_ids: BTreeSet<String>,
    #[serde(rename = "verifiedRestoreIDs")]
    verified_restore_ids: BTreeSet<String>,
    #[serde(rename = "verifiedLegacySHA256")]
    verified_legacy_sha256: BTreeSet<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    legacy_restore_audit_reference: Option<String>,
}

pub(crate) fn check_retirement<'a>(
    path: &Path,
    protection: &'a AccountCredentialCipher,
    inventory_path: &Path,
) -> Result<RetirementEvidence<'a>> {
    let inventory: RetirementInventory =
        serde_json::from_slice(&files::read_bounded(inventory_path, 32768)?)?;
    inventory.validate()?;

    let mut db = Database::open_existing(path)?;
    let current_keys = verify_credentials(db.connection(), Some(protection))?;
    let mut backups = BTreeSet::new();
    let mut backup_keys = BTreeSet::new();
    for bundle in inventory.retained_backups {
        let manifest = verify_backup(&bundle, Some(protection))?;
        backup_keys.extend(manifest.required_key_ids);
        if !backups.insert(manifest.id) {
            return Err(Error::Conflict);
        }
    }
    let mut legacy_hashes = BTreeSet::new();
    let have_legacy = !inventory.legacy_databases.is_empty();
    for file in inventory.legacy_databases {
        files::require_absent(
            &file,
            &["-wal", "-shm", "-journal", ".lock", ".restore-pending"],
        )?;
        let original = files::fingerprint(&file)?;
        let legacy = open_snapshot(&file)?;
        require_integrity(&legacy)?;
        require_complete_reencryption(&legacy)?;
        backup_keys.extend(verify_credentials(&legacy, Some(protection))?);
        if files::fingerprint(&file)? != original || !legacy_hashes.insert(original.1) {
            return Err(Error::Conflict);
        }
    }
    let mut drilled = BTreeSet::new();
    let mut restores = BTreeSet::new();
    for directory in inventory.restore_drills {
        let drill = Database::open_existing(directory.join("core.sqlite"))?;
        let record = read_record(drill.connection())?.ok_or(Error::Conflict)?;
        if !backups.contains(&record.backup_id) || !restores.insert(record.id) {
            return Err(Error::Conflict);
        }
        verify_credentials(drill.connection(), Some(protection))?;
        drilled.insert(record.backup_id);
    }
    if drilled != backups {
        return Err(Error::MissingRestoreEvidence);
    }

    let evidence = RetirementEvidence {
        audit_reference: inventory.audit_reference,
        active_key_id: protection.key_id(),
        available_key_ids: protection.available_key_ids(),
        required_current_key_ids: current_keys,
        required_backup_key_ids: backup_keys,
        verified_backup_ids: backups,
        verified_restore_ids: restores,
        verified_legacy_sha256: legacy_hashes,
        legacy_restore_audit_reference: inventory
            .legacy_restore_audit_reference
            .filter(|_| have_legacy),
    };
    let tx = db.begin_immediate()?;
    audit(&tx, "key_retirement_checked", &evidence, now()?)?;
    tx.commit()?;
    Ok(evidence)
}

#[cfg(test)]
mod tests {
    use super::*;
    use codexone_storage::AccountCredential;

    #[test]
    fn an_interrupted_rust_page_commits_its_checkpoint_and_resumes_without_rewriting_it() {
        let temporary = tempfile::tempdir().unwrap();
        let workspace = temporary.path().canonicalize().unwrap();
        let path = workspace.join("core.sqlite");
        let bundle = workspace.join("before");
        let old = AccountCredentialCipher::from_hex(&"a1".repeat(32), &[]).unwrap();
        let ring =
            AccountCredentialCipher::from_hex(&"b2".repeat(32), &[&"a1".repeat(32)]).unwrap();
        let wrong_active =
            AccountCredentialCipher::from_hex(&"a1".repeat(32), &[&"b2".repeat(32)]).unwrap();
        let reduced = AccountCredentialCipher::from_hex(&"b2".repeat(32), &[]).unwrap();
        let synthetic = AccountCredential::new(
            "synthetic-access".into(),
            "synthetic-refresh".into(),
            None,
            2_000_000_000,
        )
        .unwrap();
        let db = Database::open_or_create(&path).unwrap();
        for index in 0..9 {
            let id = format!("account-{index}");
            let namespace = format!("synthetic/{id}");
            let context = AccountCredentialContext::new(&id, &namespace, 1).unwrap();
            let envelope = old.seal(&synthetic, &context).unwrap();
            db.connection().execute(
                "INSERT INTO accounts(id,namespace,revision,credential_version,mode,authorization,
                    sealed_credential,refresh_intent,created_at_epoch)
                 VALUES (?1,?2,3,1,'enabled','refreshing',?3,'synthetic-refresh-intent',1)",
                params![id, namespace, envelope],
            ).unwrap();
        }
        drop(db);

        assert!(matches!(
            reencrypt_with_checkpoint(&path, &ring, Some(&bundle), |checkpoint| {
                if checkpoint.rewritten == 8 {
                    Err(Error::Storage)
                } else {
                    Ok(())
                }
            }),
            Err(Error::Storage)
        ));
        assert_eq!(
            Database::open_or_create(&path).err(),
            Some(DatabaseError::IncompleteReencryption)
        );
        let status = key_status(&path, &ring).unwrap();
        let checkpoint = status.checkpoint.unwrap();
        assert_eq!(checkpoint.rewritten, 8);
        assert!(!checkpoint.complete);
        assert_eq!(status.required_current_key_ids, ring.available_key_ids());
        assert_eq!(
            verify_backup(&bundle, Some(&old)).unwrap().id,
            checkpoint.backup_id
        );
        assert!(matches!(
            crate::Command::ResumeReencryption.run(&path, Some(&wrong_active), 0, None),
            Err(Error::WrongActiveKey)
        ));
        assert!(matches!(
            crate::Command::ResumeReencryption.run(&path, Some(&reduced), 0, None),
            Err(Error::Credential)
        ));
        let pending_backup = workspace.join("pending");
        assert!(matches!(
            crate::Command::Backup(pending_backup.clone()).run(&path, Some(&ring), 0, None),
            Err(Error::Database(DatabaseError::IncompleteReencryption))
        ));
        assert!(!pending_backup.exists());

        let first_page_envelope = |db: Database| -> String {
            db.connection()
                .query_row(
                    "SELECT sealed_credential FROM accounts WHERE id='account-0'",
                    [],
                    |row| row.get(0),
                )
                .unwrap()
        };
        let before_resume =
            first_page_envelope(Database::open_for_credential_maintenance(&path).unwrap());
        let resumed = reencrypt(&path, &ring, None).unwrap();
        assert_eq!(resumed.required_current_key_ids, [ring.key_id()]);
        let resumed = resumed.checkpoint.unwrap();
        assert_eq!(resumed.job_id, checkpoint.job_id);
        assert!(resumed.complete);
        assert_eq!(resumed.rewritten, 9);

        let db = Database::open_existing(&path).unwrap();
        assert_eq!(
            db.connection()
                .query_row(
                    "SELECT COUNT(*) FROM accounts WHERE revision=3 AND credential_version=1
               AND authorization='refreshing' AND refresh_intent='synthetic-refresh-intent'",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            9
        );
        assert_eq!(first_page_envelope(db), before_resume);
    }
}
