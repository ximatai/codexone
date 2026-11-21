# CodexOne Rust maintenance

The [gateway executable](../gateway/README.md) dispatches the maintenance CLI before starting listeners. It uses the Swift file formats, SQLite schema, and shared instance lock. Use the established [snapshot](../../docs/operations/snapshot-maintenance.md), [master key](../../docs/operations/master-key-maintenance.md), and [managed-Key migration](../../docs/guide/migration.md) workflows.

- `--backup` and `--verify-backup` write or check format 1 bundles using SQLite's backup API, SHA-256, and authenticated credential reads.
- `--restore`, `--maintenance-status`, and `--reconcile-restored` restore into an empty private data directory, rotate the storage generation and old Key digests, invalidate bindings, and record the audit baseline and business-day freeze. A durable barrier rejects startup if the target was interrupted.
- `--key-status`, `--reencrypt-credentials`, and `--resume-reencryption` authenticate all existing credentials. Reencryption publishes an independent backup, then commits a checkpoint with each page of up to eight rewrites.
- `--check-key-retirement` checks current credentials, retained bundles, restore drills, and any attested pre-migration database copies.
- `--import-keys` imports disabled Keys in one transaction into an empty target ledger. `--migrate` remains a storage command.

```sh
cargo test --locked --manifest-path rust/maintenance/Cargo.toml
```

The [process fixture](../../scripts/rust_compat/README.md#离线维护互操作) uses separate temporary directories and synthetic accounts.

When `CODEXONE_BACKUP_DIRECTORY` is configured, the gateway runs one online backup worker. It uses a read-only WAL connection under the writer's instance lock and waits ten minutes after startup, then one day after each round. A new bundle must pass the same verification as `--verify-backup` before publication. Rotation keeps seven online bundles and preserves manual backups. The worker provides a read-only status handle with the Swift-compatible `BackupObservation` DTO.
