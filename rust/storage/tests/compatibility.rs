use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use codexone_storage::{
    AccountCredential, AccountCredentialCipher, AccountCredentialContext, Database, DatabaseError,
    bearer_digest, key_digest,
};
use rusqlite::Connection;

#[test]
fn rejects_missing_and_incompatible_ledger_without_switching_journal() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("ledger.sqlite");
    assert_eq!(
        Database::open_existing(&path).err(),
        Some(DatabaseError::StorageUnavailable)
    );
    assert!(!path.exists());
    let sqlite = Connection::open(&path).unwrap();
    for schema in [0, 18, 20, 19] {
        sqlite.pragma_update(None, "user_version", schema).unwrap();
        assert_eq!(
            Database::open_existing(&path).err(),
            Some(DatabaseError::IncompatibleSchema)
        );
        assert_eq!(
            sqlite
                .pragma_query_value(None, "journal_mode", |row| row.get::<_, String>(0))
                .unwrap(),
            "delete",
        );
    }
}

#[test]
fn rejects_restore_marker_and_an_unsafe_sqlite_sidecar() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("ledger.sqlite");
    fs::File::create(&path).unwrap();
    let marker = directory.path().join("ledger.sqlite.restore-pending");
    fs::File::create(&marker).unwrap();
    assert_eq!(
        Database::open_existing(&path).err(),
        Some(DatabaseError::IncompleteRestore)
    );
    fs::remove_file(marker).unwrap();
    symlink(&path, directory.path().join("ledger.sqlite-wal")).unwrap();
    assert_eq!(
        Database::open_existing(&path).err(),
        Some(DatabaseError::StorageUnavailable)
    );
}

#[test]
fn parses_only_the_swift_managed_bearer_shape() {
    let secret = "co1_synthetic-storage-key";
    let valid = format!("Bearer {secret}");
    assert_eq!(bearer_digest(&[&valid]).unwrap(), key_digest(secret));
    for headers in [
        vec![],
        vec![valid.as_str(), valid.as_str()],
        vec!["Bearer too-short"],
        vec!["bearer co1_synthetic-storage-key"],
        vec!["Bearer co1_synthetic-storage-key "],
        vec!["Bearer co1_synthetic-storage-key\u{7f}"],
    ] {
        assert!(bearer_digest(&headers).is_err());
    }
}

#[test]
fn envelopes_bind_identity_namespace_and_version_and_reject_tampering() {
    let master = "1A".repeat(32);
    let cipher = AccountCredentialCipher::from_hex(&master, &[]).unwrap();
    assert!(AccountCredentialCipher::from_hex(&master, &[&master.to_lowercase()]).is_err());
    let context = AccountCredentialContext::new("account", "https://example.test/sub", 1).unwrap();
    let credential =
        AccountCredential::new("synthetic+a/".into(), "synthetic-r".into(), None, 1).unwrap();
    let sealed = cipher.seal(&credential, &context).unwrap();
    assert_ne!(sealed, cipher.seal(&credential, &context).unwrap());
    assert_eq!(
        cipher.open(&sealed, &context).unwrap().access_token(),
        credential.access_token()
    );
    for (identity, namespace, version) in [
        ("elsewhere", "https://example.test/sub", 1),
        ("account", "https://example.test/other", 1),
        ("account", "https://example.test/sub", 2),
    ] {
        let wrong = AccountCredentialContext::new(identity, namespace, version).unwrap();
        assert!(cipher.open(&sealed, &wrong).is_err());
    }
    let (header, body) = sealed.rsplit_once('.').unwrap();
    assert!(
        cipher
            .open(&format!("{header}.{body}\n"), &context)
            .is_err()
    );
    assert!(
        cipher
            .open(
                &format!("{header}.{}", body.trim_end_matches('=')),
                &context
            )
            .is_err()
    );
    let mut bytes = STANDARD.decode(body).unwrap();
    *bytes.last_mut().unwrap() ^= 1;
    assert!(
        cipher
            .open(&format!("{header}.{}", STANDARD.encode(bytes)), &context)
            .is_err()
    );
}

#[test]
fn master_file_requires_private_ownership_and_distinct_material() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("master");
    let alias = directory.path().join("alias");
    let master = "1A".repeat(32);
    fs::write(&path, format!("{master}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
    assert!(AccountCredentialCipher::load(&path, None, None).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    symlink(&path, &alias).unwrap();
    assert!(AccountCredentialCipher::load(&alias, None, None).is_err());
    assert!(AccountCredentialCipher::load(&path, Some(&path), None).is_err());
    assert!(
        AccountCredentialCipher::load(&path, None, Some(&key_digest(&master.to_lowercase())))
            .is_err()
    );
    assert_eq!(
        AccountCredentialCipher::load(&path, None, None)
            .unwrap()
            .key_id(),
        AccountCredentialCipher::from_hex(&master, &[])
            .unwrap()
            .key_id(),
    );
}
