# Windows MSI preparation

The project contains a branded Windows MSI build configuration and a manual build workflow. **No MSI has been produced or executed on Windows yet.** Configuration validation on Linux is not evidence that the Windows application, installer or recovery procedures work.

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

After these files are pushed to the intended repository, run **Prepare Windows MSI** through GitHub Actions. It runs only through `workflow_dispatch`; pushes and pull requests do not start it.

Provide the exact official PostgreSQL/EDB Windows archive HTTPS URL and its independently verified SHA-256. The workflow accepts only the configured official distribution hosts, checks the hash before extraction, rejects escaping ZIP paths/symlinks, and invokes the same native-resource checks as the local build. The optional archive-layout inputs default to `pgsql` and its `doc` directory; adjust them to the verified distribution's actual layout. Missing directories cause a failure rather than omitting required resources.

The workflow runs on `windows-2025`, uploads the MSI and checksums as a temporary build artifact, and has read-only repository permissions. It does not push commits, create a release, install the MSI, or sign it. A successful workflow is a build result awaiting the native acceptance checks below.

## Installer configuration

- `tauri.windows.conf.json` targets MSI, uses `icons/icon.ico` and embeds the WebView2 offline installer. See [Tauri's offline runtime option](https://v2.tauri.app/distribute/windows-installer/#offline-installer).
- WiX uses `installer/branding/banner.bmp` at **493 × 58** pixels and `installer/branding/dialog.bmp` at **493 × 312** pixels.
- Keep upgrade code `b8dc76d1-374a-4f76-95e8-db387b715bcf` and application identifier `in.sbco.vouchercheck` stable across releases. Changing them can break upgrade recognition or select a different data directory.
- Increment the product version deliberately for a release. The current source version remains `0.1.0`; this preparation does not claim a new released version.

## Native Windows validation still required

The launcher currently has a Windows executable suffix but retains platform assumptions from the Linux release. Before distributing an MSI, build and test on Windows 10 and Windows 11, including these concrete checks:

1. Verify `initdb --locale=C.UTF-8` works with the selected Windows PostgreSQL distribution. If it does not, implement and test an explicit Windows locale/provider choice for new clusters; do not silently change existing cluster collation.
2. Verify every PostgreSQL DLL dependency and extension loads. The existing `LD_LIBRARY_PATH` setting is Linux-specific; the Windows distribution must resolve its DLLs through verified Windows search paths.
3. Verify the application-data directory, credentials, temporary password files and backups are accessible only to the intended user. Unix modes do not establish Windows ACLs.
4. Install on clean machines, including a machine without WebView2 and with networking disabled. Check ordinary-user startup, initialization, Unicode/spaced user paths, port conflicts, one-instance locking and shutdown.
5. Exercise setup, import, verification, training/reset, PDF export, manual and automatic backups, checksum rejection, restore and session clearing. Repeat after forced termination and restart.
6. Verify a newer MSI preserves the same database and settings, and that uninstall/reinstall has the intended data-retention behavior. Preserve a manual backup and check record counts before accepting an upgrade.
7. Review application and third-party notices, sign using the publisher's approved certificate if required, and verify the final signed artifact's checksum and installer behavior.

Linux checks cannot certify these Windows behaviors. There is currently no verified Windows installer artifact or Windows acceptance record in this project.
