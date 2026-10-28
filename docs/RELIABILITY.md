# Local reliability rehearsal

Executed on 28 October 2026 against PostgreSQL 18.6 using the Rust API and worker binaries. The rehearsal creates a uniquely named disposable database on the existing test PostgreSQL instance at port 55438, starts its own API and worker processes, and drops that database when finished. It does not change the fresh `sbco-local` database or restart shared services.

## Verified behavior

| Scenario                                                                                 | Observed result                                                                                                                                 |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Last administrator disabled or demoted                                                   | Rejected; an active administrator remains.                                                                                                      |
| Two administrators demote themselves concurrently                                        | One change succeeds and the other is rejected; exactly one administrator remains.                                                               |
| PA becomes a supervisor                                                                  | Both existing sessions are revoked and the PA's pool assignment is removed.                                                                     |
| Non-admin changes user access                                                            | Rejected.                                                                                                                                       |
| Administrator resets a password                                                          | Old password and existing sessions stop working; replacement password works.                                                                    |
| User changes a password                                                                  | Incorrect current password is rejected; successful change revokes the session.                                                                  |
| Disabled account signs in                                                                | Rejected.                                                                                                                                       |
| Local operator recovers an active administrator                                          | Password replaced, sessions revoked, login lockout cleared and one recovery audit event recorded.                                               |
| Operator attempts to recover a supervisor                                                | Rejected; existing supervisor access is unaffected.                                                                                             |
| Six concurrent uploads of the same delivered transaction workbook                        | All return the same import ID; exactly one batch and job are created.                                                                           |
| 5,000 rows entered into a copy of the delivered SO template                              | All are retained, with leading-zero account IDs, source row numbers and an exact credit total of 51,250.00.                                     |
| Worker killed after 100 committed rows                                                   | Committed rows survive. A replacement does not steal the unexpired lease.                                                                       |
| Expired worker lease and a second semantically identical workbook processed concurrently | Two workers finish; exactly 5,000 distinct transactions remain. Across both batches, 5,000 inserted and 5,000 duplicate rows are accounted for. |
| Fifth abandoned attempt expires                                                          | Batch becomes Failed; operator retry resets attempts and completes successfully.                                                                |

The complete automated rehearsal passed in 25.3 seconds. The worker-kill timing is deliberately made reproducible by a temporary insert-delay trigger in the disposable database. The test expires the abandoned lease explicitly instead of waiting five minutes. It also simulates an exhausted attempt count; it does not repeatedly crash the process five times. All temporary database objects are removed with the test database.

## Defect found and fixed

The initial simultaneous-upload test reproduced HTTP 409 when two requests both passed the file-hash lookup before either inserted its batch. The import command now handles a conflict on `file_hash` by returning the batch committed by the other request. It creates a processing job only for a newly inserted batch. The full rehearsal passed after this change.

Rust formatting and Clippy checks for infrastructure, API and worker passed with warnings treated as errors.

## Re-run

From the project directory, with the existing isolated test PostgreSQL container running:

```bash
source scripts/env.sh
CARGO_BUILD_JOBS=2 cargo build -p sbco-api -p sbco-worker
python3 tests/reliability.py
```

The script refuses a database endpoint other than loopback port 55438. It uses the `sbco-next-test-pg` Docker container by default; `SBCO_TEST_POSTGRES_CONTAINER` can select another isolated test container. Credentials are inherited from the private test environment and are never printed. Docker access is required.

This establishes the tested 5,000-row and two-worker scenarios, not a throughput guarantee at the 200,000-row parser ceiling. Real office acceptance, extended-duration load testing and user approval of report content are separate release checks.

## Native Save dialog and reinstall

`tests/native_release.py` passed against the installed Linux `SBCO_0.1.0_amd64.deb` inside an Ubuntu 26.04 test container with networking disabled. WebKitWebDriver exercised the installed application's rendered controls; X11 keyboard events operated the genuine GTK file dialog. Native dialogs require this native test harness rather than browser-only automation.

The preparation phase created a new offline administrator, opened the setup, SO and BO template links, entered destinations in each Save dialog and verified that every saved file exactly matched the shipped workbook bytes. It imported two transactions and saved a distinctive signatory setting. After closing the application, the same package was installed again and the verification phase reopened the same disposable profile. Original administrator credentials, transactions, completed import history and the setting were preserved. Both phases checked the SBCO page title, native IPC availability and absence of visible application alerts.

Run the `prepare` and `verify` phases as an unprivileged user under `xvfb-run`, reinstalling the package between phases. Both phases must share `XDG_DATA_HOME`, `XDG_CONFIG_HOME` and `SBCO_NATIVE_RELEASE_STATE` under `/tmp`. Set `SBCO_NATIVE_DRIVER` to the installed `tauri-driver`; optional `SBCO_NATIVE_EVIDENCE` controls screenshot output. The test refuses a profile or state path outside `/tmp`. Use a new disposable container for each run; no host profile is used.

This verifies a **same-version reinstall**, not a future application-version migration, cross-version PostgreSQL upgrade, Windows/macOS installer, signed release or unattended update. Screenshot evidence was captured for all three native dialogs and both application phases; the setup dialog was visually inspected.

Both native suites passed again against the final 28 October Linux build. `tests/native_desktop.py` additionally waits up to 90 seconds for the first scheduled backup after setup, checks successful backup status and 14-day retention, verifies the PostgreSQL archive header and checksum, and confirms that other local accounts have no file permissions. The 251-row import, PA assignment, verification and DPR/MPR checks also passed with container networking disabled.

The offline Linux bundle was refreshed with this final installer (SHA-256 `e738f95a9e8d2652b42e049b4911271aa8ba1f5d034f19c7aa39f7dfd7238c8b`). All 271 files in its regenerated checksum manifest passed validation. The packaging script removes the empty restricted APT staging directory after download so the delivered bundle remains traversable by the workspace owner.
