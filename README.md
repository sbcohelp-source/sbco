# SBCO migration workspace

Rust and PostgreSQL application core with a shared Next.js/Tailwind/shadcn interface for web and Tauri desktop. The old Frappe application code has been removed; this implementation uses a fresh PostgreSQL database. The approved [project migration plan](../MIGRATION_PLAN.md) remains the acceptance baseline.

## What is available

Accounts and office-scoped sessions; office/pool allocation; durable Excel imports; database pagination; primary verification, high-value supervisor review, and approved corrections; incidents; letters, reminders and compliance rollups; report previews with complete totals; retained decision history; generated TypeScript command definitions; and local PostgreSQL initialization, backup and restore.

The desktop restore process makes a safety backup, restores into a new database, validates its migrations and accounts, then switches the local configuration for restart. The original database is retained. Backups contain the entire database, including workbook bytes and issued PDF bytes. Keep backups private because they contain operational data and account password hashes.

## Requirements and local development

Use Rust 1.99.1, Node 26.12.1, Yarn 1.22.22 and PostgreSQL 18.6. `rust-toolchain.toml`, `Cargo.lock`, the desktop `Cargo.lock`, and `yarn.lock` pin the tested dependencies. Compatible TypeScript 6.0.3 is used with the chosen ESLint/Next versions.

```sh
yarn install --frozen-lockfile
cargo build --workspace --locked
```

Configure `DATABASE_URL`, `SBCO_ADMIN_NAME`, `SBCO_ADMIN_EMAIL`, and `SBCO_ADMIN_PASSWORD` through your private environment. The administrator password must be at least 12 characters. Bootstrap only works when the database contains no users:

```sh
cargo run -p sbco-api -- --bootstrap
cargo run -p sbco-api
cargo run -p sbco-worker
yarn dev
```

Run the API, worker and frontend in separate terminals. For a production-build preview, run `yarn build:web` then `yarn start`; this uses the standalone server and binds to loopback by default. The frontend is at `http://localhost:3091`; its API proxy targets `127.0.0.1:8091`. Set `SBCO_INSECURE_LOCAL_HTTP=1` for loopback HTTP development only. Shared deployments require HTTPS and the default secure cookies. No default account/password is shipped.

This local project also has ignored workspace tool installations and `.env.local`; `source scripts/env.sh` enables them for this machine. They are conveniences, not deployment prerequisites. Do not use that script to launch a standalone desktop: its development `DATABASE_URL` would select the shared test database.

## Quality checks

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
yarn format:check
yarn lint
yarn typecheck
yarn test
yarn check:contracts
yarn build:web
yarn build:desktop-ui
```

Run `python3 tests/integration.py` against an isolated API/worker/database with the bootstrap administrator environment. It creates uniquely named fixture accounts/offices and does not delete existing data. Then run `yarn test:e2e`; it reads the private fixture session file produced in `/tmp`. Browser screenshots and logs stay outside the repository. The GitHub workflow runs these checks against a disposable database.

## Import templates

Download **Setup template**, **SO transactions** or **BO transactions** from **Excel imports**. Each Excel file includes blank input sheets, instructions and examples. Administrators can preview and import setup users, offices and pools together; passwords are set separately. See [template fields and usage](docs/IMPORT_TEMPLATES.md). `python3 tests/setup_import.py` validates filled copies of the distributed templates against an isolated test database.

## Shared web deployment

Copy `.env.example` to a private `.env`, fill in independently generated URL-safe secrets, then:

```sh
docker compose build
docker compose run --rm bootstrap
docker compose up -d database api worker web backup
```

The web container binds to loopback port 3092. Put your HTTPS gateway in front of it. PostgreSQL and the Rust API have no public host ports. Remove bootstrap credentials from the deployment environment after creating the administrator. Run `scripts/server-backup.sh /private/path/sbco.dump` for an atomic custom-format backup and checksum.

For this project's fresh local installation, `.env` selects the separate `sbco-local` Compose project and loopback HTTP access. Private initial sign-in details are in ignored `data/local-access.txt`. Do not source the test environment (`scripts/env.sh`) when operating this installation: it contains credentials for a different, isolated test database. Change the initial administrator password after sign-in.

The `backup` service keeps 14 daily, checksum-verified custom-format backups in its own volume. It retries failed backups and does not capture an uninitialized installation as the day's only backup. Backups on the same computer do not protect against loss of that computer; copy recovery files to the office's chosen backup destination.

Operator-only administrator recovery uses `sbco-api --recover-admin` with `DATABASE_URL`, `SBCO_RECOVERY_EMAIL` and `SBCO_RECOVERY_PASSWORD` supplied through a private environment. It resets only an existing active administrator, revokes sessions and records an audit event. No public password-recovery endpoint is exposed.

Server recovery must first restore to a separate database with PostgreSQL 18 tools, run the application migrations there, and reconcile counts/totals/files before switching `DATABASE_URL`. Never test a restore against the live database. Production deployment, gateway configuration and live-data cutover have not been performed.

## Offline desktop (Linux prototype)

The current build target is Ubuntu 26.04 x86_64. Other platforms are not validated. A native build needs GTK3/WebKitGTK 4.1 development libraries; `deploy/Dockerfile.desktop-builder` provides the isolated build environment.

```sh
yarn build:desktop-ui
scripts/package-postgres.sh
yarn desktop:build
```

Run packaging inside the prepared Linux builder with PostgreSQL 18.6 tools installed. The packaging script copies database binaries, data files, shared libraries, checksums and license notices into the ignored desktop resource directory. Do not commit generated PostgreSQL binaries. Tauri bundles the resources into the installer. The Ubuntu 26.04 x86_64 offline bundle includes the OS dependency packages. `scripts/package-linux-offline.sh` creates it and `scripts/install-linux-offline.sh` verifies checksums and installs without network access; this was rehearsed in a clean container. Other operating systems still need their own tested prerequisites.

With no `DATABASE_URL`, the app creates a private per-user PostgreSQL cluster listening only on loopback with a random port and private credentials. It rejects a second instance using the same profile. First launch asks you to create the administrator. Desktop sessions and database credentials remain in Rust. With `DATABASE_URL` explicitly set, the app uses that database directly. This is a technician mode and does not synchronize data. The separate SBCO Client build connects through HTTPS and does not start a local database.

The installed Linux prototype was also tested with external networking disabled: first-run setup, login, native IPC, a 251-row workbook import, PA allocation, search beyond row 200 and persisted verification passed. `tests/native_desktop.py` repeats that smoke test against a disposable installed profile with Tauri's driver and WebKitWebDriver. Do not run it against your everyday desktop profile.

The local recovery test can run in the builder without a graphical session:

```sh
SBCO_TEST_RESOURCES="$PWD/apps/desktop/src-tauri/resources" \
  cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml -- --ignored
```

## First-run setup and onboarding

A new standalone desktop starts with a welcome screen and administrator creation, including password confirmation. Shared servers retain their operator-controlled administrator bootstrap; there is no public account-creation endpoint. After sign-in, a new administrator sees a six-step guide: welcome, offices, team, preferences, first import and readiness. Postal Assistants and supervisors receive a shorter guide explaining their own work and permissions.

Use **Get started** to reopen the guide. **Continue** saves the current place in PostgreSQL for that account; **Do this later** opens the overview, and **Resume setup** returns to the guide. Forms must be saved before continuing. The guide uses the existing office/user/pool/settings/import commands and never inserts sample data. At least one office is required to finish administrator setup. Team allocation and first import may be completed later, with outstanding work shown on the readiness screen. Imported staff still need passwords set through Users.

Completing onboarding does not grant permissions or approve office reports. Progress is included in database backups. A change of role starts the guide appropriate to the new role. Keyboard preferences remain local to each browser/device as described below.

## Help and personal training

Open **Help** from the navigation or the question-mark button in the header. The searchable guide is bundled with the application, including the offline desktop, and covers setup, imports, verification, corrections, correspondence, reports, shortcuts, recovery and common problems. Links respect the current role. The author and support contact are **S K Singh**, **sbcohelp@gmail.com**; the email link opens the user's mail application and does not send a message automatically.

Open **Training** and choose **Enable training**. Each signed-in user gets a separate PostgreSQL workspace containing synthetic offices, practice users, allocations, 24 vouchers, incidents and a draft letter. Choose Administrator, Supervisor or Postal Assistant to practise those roles; this never changes the user's live permissions. Live accounts still control sign-in and access to personal training.

Training selection applies to the current browser tab or desktop session. A persistent banner identifies practice mode. Every workspace switch reloads the page, so a previously opened form cannot silently start writing to live data. **Disable training** returns to live work and keeps practice records for **Resume training**. Training reports and letters are marked **TRAINING — NOT FOR OFFICIAL USE**. Password changes and manual backup/restore controls are unavailable during training.

To remove demo data and everything created during practice, choose **Review training deletion**, review the counts and type **DELETE TRAINING**. Deletion removes only that user's training workspace, including its practice history. Existing live records, other users' practice, downloaded files and existing backup files remain. Old tabs receive an unavailable-workspace error; they cannot fall back to live operations. Enabling again creates a fresh practice workspace. Whole-database backups include existing training workspaces, so restoring an older backup can bring them back.

## Keyboard shortcuts

Open **My account → Keyboard shortcuts** to enable, change or reset shortcuts for the signed-in user on this browser/device. Defaults use **Alt+Shift** plus **S** (save the focused form), **F** (account search), **N/P** (next/previous voucher on the current page), **M** (match), **R** (reason), and **K** (shortcut reference). Form validation still applies. Verification shortcuts do not run while typing or composing text, or while a modal is open.

## Recovery and deployment evidence

Standalone desktop backups run daily while the app is open, retain 14 automatic copies and display status for administrators under Settings. Use **Back up** to keep a separate recovery copy. See [desktop recovery](docs/DESKTOP_RECOVERY.md).

[The deployment plan](docs/DEPLOYMENT_PLAN.md) covers Linux or Windows 10/11 hosts with installed Windows clients. [The connected-client design](docs/CONNECTED_DESKTOP_DESIGN.md) records the implemented HTTPS transport and remaining Windows qualification. Connected clients use the server database through the API; standalone offline installations retain local PostgreSQL. [Windows server and client packaging](docs/WINDOWS_SERVER_CLIENT.md) describes the separate branded MSI build action.

## Remaining release gates

- Unsigned Windows server, client and standalone MSIs have been built. Server/client install, repair and uninstall pass on Windows 2025; the configured shared-server and standalone PostgreSQL recovery rehearsals pass. Standalone installer checks also pass. Scheduled backup/restore also passes. Qualify the selected Windows 10/11 builds and obtain signing identities. Connected-client HTTPS workflows have passed installed Linux testing.
- Obtain office-operator approval and reconcile real office data using [the acceptance checklist](docs/ACCEPTANCE_CHECKLIST.md).
- Test Windows LAN clients, target OS/printers, manual screen-reader use, realistic workloads and future application-version upgrades.
- Hosted application and Linux recovery CI passed on commit `ac85c31` ([run evidence](https://github.com/sbcohelp-source/sbco/actions/runs/40881122497)). Complete office Windows qualification and a real HTTPS deployment with an approved backup destination.
- Legacy conversion remains deferred by the fresh-database decision; macOS is outside the latest requested deployment arrangements.

See [implementation status](docs/IMPLEMENTATION_STATUS.md) for completed local evidence and remaining gates. No production readiness is claimed.

Web builds use `.next-web`; desktop static assets use `.next-desktop`. The separate web directory preserves the server build when Next.js regenerates its static-export intermediate files.
