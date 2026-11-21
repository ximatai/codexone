use std::path::Path;

use codexone_storage::{
    AccountCredential, AccountCredentialCipher, AccountCredentialContext, Database, DatabaseError,
    bearer_digest,
};
use rusqlite::params;

#[test]
#[ignore = "spawned by tests/verify-swift.sh with a synthetic Swift database"]
fn swift_database() {
    let path = std::env::var_os("CODEXONE_STORAGE_DB").unwrap();
    let phase = std::env::var("CODEXONE_STORAGE_PHASE").unwrap();
    match phase.as_str() {
        "locked" => {
            assert_eq!(
                Database::open_existing(&path).err(),
                Some(DatabaseError::InstanceLocked)
            );
            assert_eq!(
                Database::open_or_create(&path).err(),
                Some(DatabaseError::InstanceLocked)
            );
            assert_eq!(Database::migrate(&path), Err(DatabaseError::InstanceLocked));
        }
        "startup" => drop(Database::open_or_create(&path).unwrap()),
        "startup-incompatible" => assert_eq!(
            Database::open_or_create(&path).err(),
            Some(DatabaseError::IncompatibleSchema)
        ),
        "migrate" => Database::migrate(&path).unwrap(),
        "rewrite" => rewrite(Path::new(&path)),
        _ => panic!("unknown interoperability phase"),
    }
}

fn rewrite(path: &Path) {
    let mut database = Database::open_existing(path).unwrap();
    let connection = database.connection();
    let (namespace, version, envelope): (String, i64, String) = connection
        .query_row(
            "SELECT namespace, credential_version, sealed_credential FROM accounts WHERE id=?1",
            ["synthetic-account"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    let keyring = std::env::var_os("CODEXONE_STORAGE_KEYRING").unwrap();
    let cipher = AccountCredentialCipher::load(Path::new(&keyring), None, None).unwrap();
    let context = AccountCredentialContext::new("synthetic-account", &namespace, version).unwrap();
    let old_key = AccountCredentialCipher::envelope_key_id(&envelope).unwrap();
    assert_ne!(old_key, cipher.key_id());
    assert!(cipher.available_key_ids().contains(&old_key));
    let credential = cipher.open(&envelope, &context).unwrap();
    assert_eq!(credential.access_token(), "swift/access+1=");
    assert_eq!(credential.refresh_token(), "swift.refresh~1");
    assert_eq!(credential.id_token(), Some("swift_id-1"));
    assert_eq!(credential.expires_at_unix_seconds(), 2_000_000_000);
    let wrong_version =
        AccountCredentialContext::new("synthetic-account", &namespace, version + 1).unwrap();
    assert!(cipher.open(&envelope, &wrong_version).is_err());

    let old_digest = bearer_digest(&["Bearer co1_synthetic-swift-managed-key"]).unwrap();
    let new_digest = bearer_digest(&["Bearer co1_synthetic-rust-managed-key"]).unwrap();
    let replacement = AccountCredential::new(
        "rust/access+2=".into(),
        "rust.refresh~2".into(),
        None,
        2_000_000_001,
    )
    .unwrap();
    let replacement = cipher.seal(&replacement, &context).unwrap();
    assert_eq!(
        AccountCredentialCipher::envelope_key_id(&replacement),
        Ok(cipher.key_id())
    );
    // Exercise the file format with direct writes to synthetic data only.
    let transaction = database.begin_immediate().unwrap();
    assert_eq!(
        transaction
            .execute(
                "UPDATE accounts SET sealed_credential=?1 WHERE id=?2 AND credential_version=?3",
                params![replacement, "synthetic-account", version],
            )
            .unwrap(),
        1
    );
    assert_eq!(
        transaction
            .execute(
                "UPDATE managed_keys SET digest=?1 WHERE id=?2 AND digest=?3",
                params![new_digest, "synthetic-key", old_digest],
            )
            .unwrap(),
        1
    );
    transaction.commit().unwrap();
}
