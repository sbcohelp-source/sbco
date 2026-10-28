# Offline desktop backups and recovery

The standalone desktop installation keeps its PostgreSQL cluster, credentials, backup status, and automatic backups in the operating system's SBCO application-data directory. Settings displays the actual backup directory. A desktop connected through `DATABASE_URL` uses the server's backup procedure instead.

## Automatic backups

- After first setup, the app checks for a daily backup while it is running. It checks at startup, within a minute after first setup, and hourly after a successful check. Failed checks retry after five minutes.
- The backup date uses India time, independent of the computer's time-zone setting. Files are named `backups/auto-YYYY-MM-DD.dump`, with a matching `.sha256` checksum.
- A completed dump must pass PostgreSQL archive inspection and checksum verification. A damaged or missing current-day copy is regenerated. Partial copies never count as a successful backup.
- The latest 14 automatic daily copies are retained. Pruning happens only after the current copy validates. Manual exports and `before-restore_*.dump` safety copies are never pruned automatically.
- The status endpoint records the last attempt; Settings displays the last successful backup, backup folder and failures. Status survives app restarts. A current in-memory error also appears if a full disk prevents status from being saved.
- On Unix, the data and backup directories use mode `0700`; backup/status/configuration files use `0600`. Windows installations rely on the user's application-data directory permissions.

These are daily logical snapshots while the app is open. A closed app does not run a background backup service, and a backup on the same disk does not protect against disk loss. Use **Back up** to keep a separate copy on your normal backup storage. Backup files contain operational data and account password hashes.

## Restore a backup

1. Sign in as an administrator and choose **Restore** in the navigation menu.
2. Select a trusted SBCO `.dump` archive and confirm the restore. If a matching `.sha256` file is present beside it, the checksum must match.
3. The app checks that the archive can be read, saves a safety copy of the current database, and restores into a new database. It does not overwrite the current database.
4. SBCO connects to the restored database, applies any compatible application migrations, requires at least one SBCO account, and clears restored sessions. Only then does it switch the saved database configuration and restart.
5. Sign in with an account and password from the backup. Check offices, users, transactions, reports, and recent work before continuing.

A rejected or incomplete restore leaves the active database configuration unchanged. A failed restore can leave an isolated `restore_*` database for investigation; it is never activated automatically. Keep the original database and safety copy until the operator has accepted the result. An administrator who has lost all account passwords needs local operator account recovery; restoring a backup does not invent a new password.

## Application and database upgrades

An installer update must retain the same application identifier and application-data directory. Stop SBCO before replacing the installer, retain a manual export, then reopen it and verify the existing records. Current lifecycle tests cover stopping and restarting the bundled PostgreSQL 18 cluster and restoring a snapshot; they do not certify every OS installer update path or downgrades after schema migrations.

The launcher refuses any existing cluster whose `PG_VERSION` is not `18` before writing database configuration or invoking PostgreSQL tools. Never edit `PG_VERSION` to bypass this check. PostgreSQL major upgrades require a logical dump/restore or a separately planned `pg_upgrade`; replacing the executable alone is insufficient. See the [PostgreSQL 18 upgrade instructions](https://www.postgresql.org/docs/18/upgrading.html).

For an older supported installation, a technician should export a logical backup with a compatible PostgreSQL tool, preserve the complete stopped old installation, create a separate fresh SBCO PostgreSQL 18 installation, and restore the archive there. Verify record counts, decimal totals, reports, accounts, and workflows before switching users. Retain the stopped old installation for rollback. This document is an operating procedure, not evidence of a completed cross-major migration of a real office database.

## Windows and macOS porting requirements

The current source is packaged and tested for Ubuntu 26.04 x86_64. Merely changing the Tauri target from `deb` does not produce a verified Windows or macOS release. A source review found these concrete requirements:

| Area                 | Current implementation                                                                                 | Required platform work                                                                                                                                                                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PostgreSQL resources | `scripts/package-postgres.sh` copies Debian paths and discovers ELF libraries with `ldd`/`dpkg-query`. | Package native PostgreSQL binaries, shared libraries, data files, license notices, and hashes for each target architecture. Do not reuse the Linux resource directory.                                                                                                                    |
| Library loading      | The launcher sets `LD_LIBRARY_PATH`; only the executable suffix is conditional on Windows.             | Verify Windows DLL search paths and macOS library install names/rpaths, including any libraries loaded by PostgreSQL at runtime.                                                                                                                                                          |
| Locale               | Initialization requests `--locale=C.UTF-8` with the default libc provider.                             | Verify that locale on every target or deliberately select a supported provider and locale for new clusters. Do not silently change existing cluster collation. PostgreSQL documents these [initialization options](https://www.postgresql.org/docs/18/app-initdb.html).                   |
| File protection      | Unix files/directories receive explicit modes; Windows uses inherited application-data permissions.    | Verify Windows ACLs prevent other users reading database credentials and exports; test replace/rename behavior under antivirus and open-file contention.                                                                                                                                  |
| Installer/runtime    | `tauri.conf.json` currently targets only `deb` and names Ubuntu runtime packages.                      | Add platform-specific installer configuration and test ordinary-user installs, upgrades, uninstall data retention, and no-network startup. Windows must include WebView2 for offline installs using Tauri's [offline installer mode](https://v2.tauri.app/distribute/windows-installer/). |
| Signing              | No Windows/macOS signing identities or release hosts are configured.                                   | Build and sign with the owner's certificates on appropriate hosts; validate macOS nested PostgreSQL binaries/libraries and notarization with the [Tauri signing workflow](https://v2.tauri.app/distribute/sign/macos/).                                                                   |
| Recovery             | Linux tests cover lock, restart, snapshots, and atomic database selection.                             | Run the same tests natively on each target, including names/paths containing spaces, non-ASCII user directories, process termination, port conflicts, backup Save dialogs, and restored sessions.                                                                                         |

No untested platform-specific launcher change has been introduced. Windows and macOS completion requires the corresponding build/test hosts and the owner's signing material; these cannot be inferred from a Linux test pass.

## Automated evidence

`apps/desktop/src-tauri/src/postgres.rs` contains focused tests for:

- Refusing older, newer, and malformed cluster versions without changing cluster files or creating configuration.
- Keeping exactly the latest 14 automatic backups while preserving manual and safety files.
- Detecting checksum corruption, retaining one daily snapshot, and recreating damaged daily snapshots.
- Recording failures without losing the last successful status, then clearing the error after recovery.
- Rejecting damaged, invalid, and account-free restores without switching the active database.
- Restoring into a different database, clearing sessions, and surviving a full stop/restart.

The lifecycle test is ignored by default because it requires PostgreSQL tools and an unprivileged OS account. Run it in the Linux desktop builder with `SBCO_TEST_RESOURCES` pointing to the bundled resource directory and `--include-ignored --test-threads=1`. It creates only disposable clusters under the container's temporary directory; it must not target a user's application-data directory.

## Additional local release evidence

The Linux prototype passed native template Save dialogs and a same-version installer reinstall with accounts, transactions, imports and settings preserved. This does not certify future schema-changing application upgrades. The complete Ubuntu 26.04 x86_64 dependency bundle installed in a clean container with networking disabled.

`tests/postgres_upgrade.py` rehearses a logical PostgreSQL 17.11-to-18.6 upgrade using disposable containers and a private network. It compares migrated account hashes, schema migrations, Unicode office data, leading-zero accounts, exact decimal amounts, source workbook bytes and issued PDF bytes, and confirms the original source remains unchanged. This rehearsal passed; no real office cluster was upgraded. Never point acceptance tests at an office database.
