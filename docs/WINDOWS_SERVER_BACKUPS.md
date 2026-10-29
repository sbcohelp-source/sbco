# Windows server backups and recovery checks

The Windows server package includes a manual PostgreSQL backup and an opt-in daily Task Scheduler job. The connected client has no local database backup. These operations preserve the running database and do not stop office services.

## Enable and manage the daily backup

After server setup, use an elevated **Windows PowerShell** window on the host. The examples use the default installation directory; replace it with the actual owned installation directory if different.

```powershell
$serverScripts = 'C:\Program Files\SBCO Server\server'
& "$serverScripts\Set-BackupSchedule.ps1" -Action Enable -Time '02:00' -Retention 14
& "$serverScripts\Set-BackupSchedule.ps1" -Action Status | Format-List
```

`Time` is a daily 24-hour time in the Windows host's local time zone. `Retention` is the number of successful, verified scheduled archives to keep, from 1 through 365. Running Enable again updates both values; omitted values revert to 02:00 and 14. Choose a time when the host is normally powered on. The guided server setup offers the default schedule after the server is ready; declining leaves it disabled.

The task is **SBCO Server Daily Backup** at the Task Scheduler root. It runs as SYSTEM without storing an operator password. It starts missed work when the computer becomes available, rejects overlapping instances, and retries a failed run three times at five-minute intervals. Its execution limit is six hours. This does not wake a powered-off machine. Task settings use Microsoft's [ScheduledTasks module](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset) and [service-account principal](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtaskprincipal).

To run a scheduled backup immediately and inspect its outcome:

```powershell
Start-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\'
& "$serverScripts\Set-BackupSchedule.ps1" -Action Status | ConvertTo-Json -Depth 6
```

Wait for the task to finish and confirm a new `last_backup.completed_at` and `last_backup.result` of `succeeded`. A last task result of zero alone does not prove a new backup exists: a queued invocation after Disable deliberately does nothing. Status reports the last invocation, which may have been manual. During a running backup, the control script asks you to retry once the maintenance lock is released. Task Scheduler itself can show its current state.

To disable future runs, preserving existing archives:

```powershell
& "$serverScripts\Set-BackupSchedule.ps1" -Action Disable
```

To make an additional manual backup:

```powershell
& "$serverScripts\Backup-Server.ps1"
```

A failed MSI uninstall has a separate rollback path: before removing the owned task, the installer records its task definition, schedule preferences and actual enabled/disabled state in protected `backup-removal.json`. Only rollback restores that record, and it refuses an unrelated replacement task. A successful uninstall can leave this recovery journal with the preserved data; ordinary resume clears it before starting services, and explicit Enable/Disable clears it after ownership checks. It does not automatically enable backups after a normal reinstall.

Manual backups use `sbco-` names and are never removed by scheduled retention. No scheduled task is created merely by invoking the manual command. Re-enable explicitly after an uninstall/reinstall; repair at the same location preserves the existing task. Never rename or repurpose the reserved task. An unexpected owner, command, account or installation path causes refusal instead of takeover.

## Files, verification and retention

Files are under `%ProgramData%\SBCO Server\backups`, protected for SYSTEM and Windows administrators. Each completed archive has:

- A PostgreSQL custom-format `.dump` file.
- A `.dump.sha256` checksum naming that exact file.
- A `.dump.backup.json` provenance record identifying the installation, archive and manual/scheduled mode.

A dump is first written to a unique `.partial` file. Only after `pg_dump` succeeds and `pg_restore --list` can read the archive are the completed file, checksum and provenance published. The checksum is SHA-256. This verifies archive structure and file integrity; it is not a restore rehearsal.

Retention runs only after all three new files are present. It removes older archives with the exact scheduled naming pattern, matching installation/provenance and a valid current checksum. Unknown files, another installation's files, corrupt archives, incomplete output and manual backups remain for operator review. Lowering retention takes effect after the next successful scheduled backup. Disabling or uninstalling the task does not delete any archive. Backups interrupted by forced shutdown may leave an incomplete file; inspect it before removing it manually.

`%ProgramData%\SBCO Server\backup-status.json` records the last attempt's mode, UTC start/completion times and result (`running`, `succeeded` or `failed`). A successful record also names the archive and hash. Failures do not write connection strings or passwords. A stale `running` record after a crash is not success. Review disk capacity, PostgreSQL service status and protected service configuration, then retry. `backup-schedule.json` stores only scheduling preferences and installation identity.

The backup reads the owned local database configuration privately and passes it to PostgreSQL through the process environment, never through scheduled-task arguments. The global maintenance mutex prevents setup/service maintenance and another backup from running concurrently. The scripts refuse symlink/junction backup paths and a database URL outside the configured local server endpoint.

## What is protected

The logical database dump includes all database schemas, accounts, office setup, transaction records, audit history, background-job records and isolated training workspaces. Import workbook bytes are stored in `imports.content`; issued correspondence PDF bytes are stored in `letters.pdf`, so both are included.

This is not a complete host image. It does not include PostgreSQL role definitions, Windows service registration, hostname configuration, the TLS private key/certificate, application binaries or external files. Maintain a separately protected recovery copy of the server configuration and TLS material, plus the exact installer and its checksum. Do not put secrets into the release repository or ordinary support logs. A same-disk backup does not protect against disk loss: copy completed archives and checksums to an office-approved separate protected destination. The scheduler does not invent or configure that destination.

## Recovery verification procedure

Perform a rehearsal on a disposable machine or isolated PostgreSQL cluster. Never restore over the running office database as a test.

1. Record the archive filename, SHA-256, database/application versions, backup timestamp and responsible operator. Copy the archive and checksum to the recovery environment; recompute SHA-256 and compare the filename and digest exactly.
2. Provision the tested PostgreSQL major version with the required database role, using a separate port/data directory and restricted account. Supply credentials through protected configuration or process environment, not command-line text. Create a new, empty, explicitly named recovery database. Do not reuse the office database name on its live connection.
3. Run the packaged `pg_restore --list` against the copy, then restore into the empty recovery database with `--exit-on-error --single-transaction --no-owner --no-privileges`. Point the connection only to the isolated recovery database. Check the exit code; a partial or failed restore is not acceptable.
4. Compare known fixture or office-approved reference counts, exact decimal amounts and audit records. Verify imported workbook bytes and issued PDF bytes against recorded SHA-256 values. Check training workspace metadata and schemas when training data is present. An empty schema or successful `--list` alone is insufficient.
5. Start a separate application instance of the matching version against the recovered database. Verify sign-in, office permissions, transaction search, reports and downloading an already-issued letter. Keep outbound access and office users away from this rehearsal instance.
6. Record results and failures, the actual restore duration and the last recoverable business timestamp. Remove only the disposable recovery resources after review. A real incident recovery requires a reviewed outage/cutover plan, preserved original data and operator approval.

## Evidence and qualification boundary

`scripts/test-windows-backups.ps1` executes portable tests using real temporary files and simulated Windows scheduler/ACL/PostgreSQL adapters. It verifies failure without retention, partial cleanup, durable status without secret details, checksum/provenance selection, retention bounds, preservation of manual/foreign/corrupt files, queued-disable behavior, environment restoration, schedule changes, refusal to replace or remove foreign tasks, enabled/disabled rollback restoration and stale-journal invalidation before ordinary service recovery. On Linux it additionally checks symlink ancestors. These tests passed locally on 29 October 2026.

`scripts/test-windows-initializer.ps1` and `scripts/test-windows-initializer-parent.ps1` also pass portable checks for the restricted initialization handshake: native exit-code capture, fresh nonce, atomic result, refusal to reinitialize a cluster, explicit service stop, stale/failure/timeout rejection and JSON integer handling. The hosted backup fixture uses the same installed initializer helper as guided setup.

The separate hosted Windows runtime rehearsal is intended to execute the real SYSTEM task, PostgreSQL dump and isolated restore. Its successful run must be recorded before claiming those Windows operations are verified. A Windows CI runner still does not qualify office Windows 10/11 builds, machine power policies, storage failure recovery, operator access or a production office restore. No live office database is changed by the portable test.
