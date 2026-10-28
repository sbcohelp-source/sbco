# Implementation status — 28 October 2026

The current delivery uses a fresh local PostgreSQL 18.6 database. Old `sbco-live/` and `sbco/` Frappe application trees have been removed; `sources/` remains read-only. No production database has been migrated or replaced. The requested deployment arrangements are a Linux or Windows 10/11 server with installed Windows clients, plus a separate standalone offline mode. See [deployment plan](DEPLOYMENT_PLAN.md) and [connected desktop design](CONNECTED_DESKTOP_DESIGN.md).

## Completed and checked locally

| Area                         | Implemented and verified                                                                                                                                                                                                                                                   |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Foundation                   | Rust application/domain/infrastructure crates; shared Next.js/Tailwind/shadcn UI; pinned dependencies, generated contracts, rustfmt and Prettier. Core Rust tests/Clippy, frontend types/lint/unit checks and builds pass locally.                                         |
| Accounts and permissions     | Office-scoped sessions, PA/supervisor/administrator roles, allocations, password changes/resets, disable/session revocation, last-admin protection and local operator recovery. Concurrent administrator-demotion and recovery checks pass.                                |
| Import templates             | Setup, SO and BO Excel templates; atomic administrator setup preview/import; repeat/conflict/permission/rollback tests; leading-zero accounts and exact money preserved.                                                                                                   |
| Import reliability           | 5,000-row fixture, six concurrent identical uploads, multiple workers, semantic duplicates, worker termination, lease expiry/reclaim and exhausted-job retry pass. Concurrent identical uploads now return the existing batch. See [reliability evidence](RELIABILITY.md). |
| Verification                 | Search/pagination beyond 200 records, PA verification, supervisor review, mandatory reasons, corrections, idempotency and retained history.                                                                                                                                |
| Keyboard operation           | Configurable Alt+Shift shortcuts under My account, saved per user/browser/device. Focused-form validation, typing/composition/modal safeguards and shortcut reference are implemented.                                                                                     |
| Correspondence and reports   | Incidents, issue/remind/compliance, immutable issued PDFs, DPR/MPR/history rules, embedded Unicode fonts and long-field wrapping. Synthetic operator review PDFs are ready.                                                                                                |
| Browser acceptance           | Chromium, Firefox and WebKit journeys; keyboard sign-in, mobile focus/Escape, 320/390/1440 layouts, report downloads and automated accessibility checks pass in tested states. See [acceptance checklist](ACCEPTANCE_CHECKLIST.md).                                        |
| Desktop recovery             | Private PostgreSQL 18 cluster, single-instance lock, daily checked backups while open, 14-copy retention, status/failure reporting, checksum validation, restore into a new database and session clearing. Focused real-cluster lifecycle tests pass.                      |
| Linux distribution           | Ubuntu 26.04 x86_64 prototype; native offline setup/import/verification/report workflow, native template Save dialogs and same-version reinstall with retained data tested. Full prerequisite bundle installed in a clean container with networking disabled.              |
| PostgreSQL upgrade rehearsal | Disposable PostgreSQL 17.11 → 18.6 logical dump/restore preserves accounts/hashes, migrations, Unicode, leading-zero accounts, exact amounts, source workbooks and PDF bytes. This is not a migration of real office data.                                                 |
| Local shared stack           | Separate `sbco-local` web/API/worker/PostgreSQL stack at localhost:3092, private database ports, scheduled daily backups and a verified restore into a temporary database. Initial credentials are in ignored `data/local-access.txt`.                                     |
| Deployment planning          | Linux server and native Windows 10/11 service layouts, HTTPS-only installed clients, server-held database credentials, distinct offline mode, rollout and acceptance gates documented.                                                                                     |

All automated fixtures use isolated test databases/profiles. The fresh local delivery is not populated with test office records. See the [README](../README.md) for repeatable checks; test logs and private credentials are ignored or stored under `/tmp`.

## First-run setup and onboarding

The standalone desktop now starts with a two-step welcome and administrator-creation wizard, including password confirmation and safe retry. Shared-server users sign in through the existing operator-created administrator account. There is no public bootstrap endpoint.

New administrators get six guided steps: welcome, offices, team, preferences, first import and readiness. The guide supports manual first-office creation, the setup workbook, staff creation, PA pool assignment, existing settings and transaction imports. PA and supervisor accounts get role-specific introductions without administrator controls. Progress and completion are stored per account and role in PostgreSQL; role changes restart the correct guide. Users can leave, resume and reopen onboarding. Finishing administrator setup requires at least one office; outstanding allocation/import work is explained rather than silently marked ready.

Database tests cover permission boundaries, counts, idempotent saves, invalid steps, empty-office completion, per-user isolation, restart persistence and role changes. The installed Linux wizard and persisted progress pass reload/reinstall checks. Browser acceptance covers form entry, real staff/allocation changes, completion/resume, responsive layouts and simulated request failure; fixtures stay in the isolated test installation.

## Help, demo data and training mode

Help is an offline, searchable guide with role-aware navigation to the relevant screens. It includes setup, imports, verification, corrections, incidents, correspondence, reports, keyboard settings, recovery, training and troubleshooting. The author is S K Singh and the support email is sbcohelp@gmail.com.

Personal training uses an isolated PostgreSQL schema for each live account. First enable seeds synthetic offices, allocations, users, 24 vouchers, incidents and a draft letter. The user can practise all three roles, create additional records and settings, leave without losing work, and resume later. A visible banner and marked PDF outputs distinguish practice. Training cannot change live passwords or invoke native backup/restore controls.

Deletion requires reviewing the workspace counts and typing DELETE TRAINING. The server locks the selected generation until in-flight work finishes, then removes that complete personal schema. A stale selection fails closed. Live business records and lifecycle audit remain; existing backup/download files are not removed. Whole-database restores can restore backed-up training schemas.

## Pending work

1. **Connected Windows qualification:** HTTPS desktop mode is implemented and passed installed Linux acceptance. Execute its MSI and the same workflows on Windows clients against the intended Linux and Windows hosts.
2. **Windows delivery:** execute the separate branded server/client MSI action and standalone MSI workflow; validate installation, service lifecycle, PostgreSQL/WebView2 prerequisites, scheduled backup/recovery and signing. Source packaging and service configuration are implemented but have not run on Windows. No Windows machines or signing identities have been supplied. Verify actual Windows 10/11 edition/build and supported servicing before rollout.
3. **Office operator acceptance:** review the prepared DPR/MPR/letter samples and complete [the checklist](ACCEPTANCE_CHECKLIST.md), then reconcile authorized real office data and run a pilot. Synthetic tests do not replace approval.
4. **Target-machine checks:** Windows multi-client LAN use, reboot/recovery, printer behavior, manual screen-reader testing, real workload performance and future application-version upgrades. Same-version Linux reinstall is tested; future upgrades are not certified.
5. **Hosted delivery:** successful repository CI and Windows artifact results, server destination, HTTPS/DNS/certificates, external backup destination and production rehearsal. The first hosted CI and Windows MSI runs have been started; production deployment has not run.

Legacy-data extraction/reconciliation remains deferred under the fresh-database decision. macOS is outside the latest requested Linux/Windows office arrangements and remains deferred. The completed local checks do not constitute production release approval.

## Final local release check

The updated API, worker and web containers are running at `http://localhost:3092`. A pre-update backup passed its checksum check. Browser sign-in, all three template downloads, My account keyboard preferences, the shortcut reference and sign-out pass against the rebuilt release. Database counts remain one administrator, zero offices, zero transactions and zero imports; no test business records were added.

The final Linux installer also passes the offline native workflow, scheduled backup/checksum/private-permission checks, three real Save dialogs and same-version reinstall preservation. Its refreshed offline bundle has 271 verified manifest entries. Browser acceptance totals 18 passing tests across Chromium, Firefox and WebKit, including the keyboard settings. Workspace formatting, type/lint checks, Rust tests/Clippy, generated contracts and client tests pass locally. Hosted workflow execution remains unverified.

The onboarding release has now been built for both shared web and Linux desktop. All 18 onboarding browser cases pass across Chromium, Firefox and WebKit, in addition to three first-run UI cases using mocked native IPC and the actual installed Linux first-run/reload/reinstall checks. The offline prerequisite bundle was refreshed and all 271 manifest checksums pass. The separate local installation was backed up before applying migration 0003; no sample records are inserted by the wizard.

## Help, training and connected-client release evidence

Help and training are deployed locally. The administrator has a personal synthetic workspace with 24 vouchers; live office, transaction and import counts remain zero. The database training rehearsal covers provisioning rollback, concurrent enable/reset/imports, protected practice roles, stale generations, permissions, report marks and live-data preservation. Browser and installed Linux checks cover enable, role change, practice entry, disable, resume and deletion.

The optional connected-client build uses an HTTPS origin, Rust-held memory-only cookies and server compatibility checks. Its installed Linux rehearsal rejected an incorrect certificate hostname, signed in through trusted HTTPS, performed remote training operations, saved template and PDF outputs through native dialogs, preserved the server address across restart, discarded the login session and created no local PostgreSQL cluster. Four native transport tests and Clippy passed; 27 connection/Help/training browser cases passed across Chromium, Firefox and WebKit. The final standalone build also passed its installed workflow with networking disabled. Windows runtime results remain pending.

## Repository delivery

The application and installer workflows were pushed to `sbcohelp-source/sbco` on `main` as commit `4ac6c50`. [Application CI](https://github.com/sbcohelp-source/sbco/actions/runs/40676447623) and [Windows server/client MSI generation](https://github.com/sbcohelp-source/sbco/actions/runs/40676476898) were started on that commit. Their final result must be checked before claiming successful hosted validation or downloadable installers.

The final local server update exposes the compatible SBCO API version 1 endpoint. A fresh pre-update backup passed its SHA-256 check. Post-update verification found zero live offices, transactions and imports, with one personal training workspace preserved.
