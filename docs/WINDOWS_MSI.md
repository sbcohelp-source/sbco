# Windows MSI preparation

Unsigned branded standalone MSI artifacts have been generated on Windows, including [build 40860043708](https://github.com/sbcohelp-source/sbco/actions/runs/40860043708), and their downloaded SHA-256 sidecars were verified. The complete native PostgreSQL lifecycle/recovery test passed on the hosted Windows 2025 runner in [run 40871866115](https://github.com/sbcohelp-source/sbco/actions/runs/40871866115), source `1ae6b61`, in 4.59 seconds. The [clean final MSI build](https://github.com/sbcohelp-source/sbco/actions/runs/40874922384) includes those fixes and passed its native lifecycle test; [installation, repair and uninstall](https://github.com/sbcohelp-source/sbco/actions/runs/40876658266) also pass with synthetic data and backup preservation. Windows 10/11 office qualification remains pending. The separate server/client packaging smoke has passed; it does not qualify this standalone edition.

The installer identifies the publisher as **S K Singh** and lists **sbcohelp@gmail.com** for support. It uses the existing SBCO icon and the banner/dialog artwork in `apps/desktop/src-tauri/installer/branding/`. The Windows configuration is separate from the tested Linux configuration.

## Scope and prerequisites

This package is the **standalone desktop edition**: application logic and PostgreSQL run on the user's computer, with data in the user's SBCO application-data directory. The current native implementation can also use an operator-provided `DATABASE_URL` for a direct database connection. These standalone modes differ from the separate server and HTTPS-connected client configurations described in [Windows server and client installers](WINDOWS_SERVER_CLIENT.md).

Use a Windows x64 build machine with:

- PowerShell 7, Git, Node.js 26.12.1, Yarn 1.22.22 and Rust 1.99.1 with `x86_64-pc-windows-msvc`.
- Visual Studio C++ Build Tools and the Windows SDK required by Tauri. MSI builds also require the Windows VBScript optional feature used by WiX. See [Tauri's Windows installer requirements](https://v2.tauri.app/distribute/windows-installer/).
- A trusted **PostgreSQL 18.6 Windows x64** distribution with `bin`, `lib` and `share`, plus its license and third-party notice/documentation directory. Obtain it through the [official PostgreSQL Windows download page](https://www.postgresql.org/download/windows/). Independently verify the exact downloaded archive's SHA-256 before running any included executable; a checksum downloaded beside an untrusted archive is not independent verification.
- Network access while building, to obtain locked dependencies, the WiX tools and the WebView2 offline installer. End-user offline installation is a separate acceptance test.

No signing certificate is configured. The workflow does not publish a release or imply that the resulting MSI is signed or trusted by Windows. The repository's existing root `LICENSE` is preserved and included by the Windows installer configuration. The publisher must review its distribution obligations and complete the bundled third-party notices before distribution; this preparation does not replace that license or invent an EULA.

## Build on Windows

Run from the repository root in PowerShell 7, replacing the paths with the verified extracted distribution and its license/documentation directory:

```powershell
./scripts/build-windows-msi.ps1 `
  -PostgresRoot 'C:\BuildInputs\pgsql' `
  -LicenseDirectory 'C:\BuildInputs\pgsql\doc'
```

The script installs locked JavaScript dependencies, packages the supplied native database resources, sets `SBCO_DESKTOP=1` using PowerShell, builds the static desktop frontend, then invokes Tauri with `tauri.windows.conf.json`. This avoids the POSIX environment assignment in the existing Linux desktop build command. Use `-SkipDependencyInstall` only when `yarn install --frozen-lockfile` has already succeeded. An optional `-OutputDirectory` selects where to copy results.

`package-postgres-windows.ps1` checks required tools for PE x64 headers, rejects ELF files and reparse points, checks `postgres.exe --version` for 18.6, copies `bin`, `lib`, `share` and the supplied notices, then writes `SHA256SUMS`. It replaces only the generated `src-tauri/resources/postgres` build payload, never the user's application-data directory. Run the Linux packager again before building Linux from that checkout. The packager validates file format and version; source authenticity still depends on the independently verified archive.

Successful builds copy MSI files and matching `.sha256` files to `artifacts/windows-msi/`. That directory is build output. Retain the input archive checksum, generated resource manifest and build log with each release candidate.

## Manual workflow

Run **Prepare Windows MSI** through GitHub Actions on the intended repository commit. It runs only through `workflow_dispatch`; pushes and pull requests do not start it.

Provide the exact official PostgreSQL/EDB Windows archive HTTPS URL and its independently verified SHA-256. The workflow accepts only the configured official distribution hosts, checks the hash before extraction, rejects escaping ZIP paths/symlinks, and invokes the same native-resource checks as the local build. The optional archive-layout inputs default to `pgsql` and its `doc` directory; adjust them to the verified distribution's actual layout. Missing directories cause a failure rather than omitting required resources.

The workflow runs on `windows-2025`, uploads the MSI and checksums as a temporary build artifact, and has read-only repository permissions. After upload, it runs the existing native PostgreSQL lifecycle/recovery test against the packaged tools in a UUID temporary directory with a random local port. It covers initialization, instance exclusion, backup/checksum/error handling, restore and restart, and retains the test log. Shared compilation caching reduces repeated build cost. It does not push commits, create a release, install the MSI, or sign it. A successful workflow provides build and tested runtime evidence on that hosted image; Windows 10/11 and effective Windows ACL qualification remain pending below.

For focused troubleshooting, **Diagnose Windows standalone recovery** uses the same verified PostgreSQL resources and desktop assets, compiles the test separately, and limits its execution to five minutes. It retains stage output and sanitized `postgres.log` files only from UUID test directories. It never collects database configuration, password files or dumps. Diagnostics exposed and corrected two Windows issues: inherited output handles delaying `pg_ctl start`, and a backup flush handle lacking write access. [Run 40871866115](https://github.com/sbcohelp-source/sbco/actions/runs/40871866115) then passed initialization, instance exclusion, migrations, manual/automatic backups, checksum rejection/repair, backup error status, invalid/empty-account archive rejection, restore, restart, and session clearing. The test also stops its temporary cluster during assertion unwinding. This proves the recovery path on the hosted Windows image; it does not replace installed GUI or Windows 10/11 qualification.

## Installer configuration

- `tauri.windows.conf.json` targets MSI, uses `icons/icon.ico` and embeds the WebView2 offline installer. See [Tauri's offline runtime option](https://v2.tauri.app/distribute/windows-installer/#offline-installer).
- WiX uses `installer/branding/banner.bmp` at **493 × 58** pixels and `installer/branding/dialog.bmp` at **493 × 312** pixels.
- Keep upgrade code `b8dc76d1-374a-4f76-95e8-db387b715bcf` and application identifier `in.sbco.vouchercheck` stable across releases. Changing them can break upgrade recognition or select a different data directory.
- Increment the product version deliberately for a release. The current source version remains `0.1.0`; this preparation does not claim a new released version.

## Native Windows validation still required

The launcher implements Windows executable paths and selects PostgreSQL’s builtin C.UTF-8 locale for new Windows clusters. Native Windows 10 and Windows 11 qualification is still required before distribution, including these checks:

1. Verify the implemented `initdb --locale-provider=builtin --builtin-locale=C.UTF-8` initialization with the selected Windows PostgreSQL distribution, including restart and recovery. Existing cluster collation must remain unchanged.
2. Verify every PostgreSQL DLL dependency and extension loads. The existing `LD_LIBRARY_PATH` setting is Linux-specific; the Windows distribution must resolve its DLLs through verified Windows search paths.
3. Verify the application-data directory, credentials, temporary password files and backups are accessible only to the intended user. Unix modes do not establish Windows ACLs.
4. Install on clean machines, including a machine without WebView2 and with networking disabled. Check ordinary-user startup, initialization, Unicode/spaced user paths, port conflicts, one-instance locking and shutdown.
5. Exercise setup, import, verification, training/reset, PDF export, manual and automatic backups, checksum rejection, restore and session clearing. Repeat after forced termination and restart.
6. Verify a newer MSI preserves the same database and settings, and that uninstall/reinstall has the intended data-retention behavior. Preserve a manual backup and check record counts before accepting an upgrade.
7. Review application and third-party notices, sign using the publisher's approved certificate if required, and verify the final signed artifact's checksum and installer behavior.

Linux checks cannot certify these Windows behaviors. Generated unsigned MSI files and hosted test logs are build evidence; effective Windows ACLs, offline WebView2 installation, actual desktop workflows and Windows 10/11 office acceptance still require the checks above.

## Verified standalone artifact

Build `40872620033` produced `SBCO_0.1.0_x64_en-US.msi` with SHA-256 `1a0e2e4759acca4d59fdb1c40bddb2c5a33e0bd378a3b182f6d5541109ebc462`. Its installer smoke passed all three operations with exit code 0 and checked the internal x64 standalone identity. The application GUI was not launched by this packaging test. The artifact also contained a cached client MSI, which was explicitly excluded from the smoke. Commit `866d848` restricts packaging to the fresh configured standalone file and rejects mixed output directories. The [clean rebuild](https://github.com/sbcohelp-source/sbco/actions/runs/40874922384) contains exactly one standalone MSI and sidecar. Its SHA-256 is `a29a56ec27e862846032fca2fd29c9eeef0e7efb88e9a9c16c2104e2e98c6929`. [Its exact-package smoke](https://github.com/sbcohelp-source/sbco/actions/runs/40876658266) passed installation, repair, uninstall and synthetic data/backup preservation with exit code 0 for all operations.
