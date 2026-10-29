# Windows server and connected client installers

The repository now has separate build paths for **SBCO Server** and **SBCO Client**, plus the original standalone desktop configuration. These are distinct products with separate upgrade identities. They must not replace one another during installation.

Unsigned server and client MSI files have been generated on Windows. The client from build `40873108070` (source `9ec44f9`) passed [packaging smoke 40876179179](https://github.com/sbcohelp-source/sbco/actions/runs/40876179179). The final server from build `40881136580` (source `ac85c31`) passed [full service rehearsal 40883757329](https://github.com/sbcohelp-source/sbco/actions/runs/40883757329), including actual setup, five services, trusted HTTPS, application workflows, API crash recovery, MSI repair and uninstall data preservation. That same server MSI passed [scheduled backup and restore rehearsal 40883720195](https://github.com/sbcohelp-source/sbco/actions/runs/40883720195). These results cover the hosted Windows 2025 image; Windows 10/11 office qualification and signing remain separate gates.

## What each package does

| Package         | Purpose                                                                                                              | Database                                                                              |
| --------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| SBCO Server     | Runs the shared application, background imports, web pages and HTTPS endpoint on a Windows 10/11 x64 office computer | PostgreSQL 18.6 on that server, listening only on loopback                            |
| SBCO Client     | Installed desktop client that connects to an explicitly configured HTTPS SBCO Server                                 | No local PostgreSQL, migrations, background worker or database backup controls        |
| SBCO standalone | Existing offline desktop design, built separately with `tauri.windows.conf.json`                                     | Own local PostgreSQL; hosted native recovery passed, Windows 10/11 acceptance pending |

A browser may also open the server's HTTPS address. Server and connected-client installations use the same accounts and records. The server must remain running for connected clients to work. Training remains personal to the authenticated account and separate from live records on that server.

## Build the installers

Run **Build Windows server and client installers** in GitHub Actions on the intended commit. By default it builds both editions. Clear **Also build and test the connected-client MSI** when only a server rebuild is needed; that run contains no client artifact and can feed the server/backup rehearsals. The combined installer smoke requires a run containing both editions. The workflow runs only when manually dispatched and uploads the selected MSI files and SHA-256 checksums. It does not publish releases, sign packages or silently install them on office computers.

`deploy/windows/dependencies.json` records exact official download URLs and pins:

- PostgreSQL 18.6-1, WinSW 2.12.0 and WiX 3.14.1: SHA-256 observed from the official HTTPS downloads. These pins detect later changes; they are not detached-signature verification.
- Caddy 2.11.7: upstream GitHub release asset SHA-256.
- Node.js 26.12.1: exact Windows archive checked against the official HTTPS `SHASUMS256.txt`; detached checksum signatures are not verified by this workflow.

Downloads are checked before extraction/execution. ZIP traversal and symbolic-link entries are refused. The PostgreSQL packager rejects Linux ELF and non-x64 executable payloads in the directories it actually ships. pgAdmin and StackBuilder are not packaged. Existing repository and third-party license files are retained; review their obligations before distributing a release.

For a local Windows build, use PowerShell 7, Visual Studio C++ Build Tools/Windows SDK, Rust 1.99.1, Node.js 26.12.1 and Yarn 1.22.22. WiX MSI builds require the VBScript Windows feature. From the repository root:

```powershell
./scripts/get-windows-build-dependencies.ps1 -Destination C:\BuildInputs\SBCO-Verified
$inputs = Get-Content C:\BuildInputs\SBCO-Verified\inputs.json -Raw | ConvertFrom-Json
./scripts/build-windows-server-msi.ps1 `
  -PostgresRoot $inputs.postgres_root `
  -PostgresLicenseDirectory $inputs.postgres_licenses `
  -NodeRoot $inputs.node_root -WinSwPath $inputs.winsw `
  -CaddyPath $inputs.caddy -ThirdPartyLicenseDirectory $inputs.third_party_licenses `
  -WixRoot $inputs.wix_root
./scripts/build-connected-client-msi.ps1
```

The destination must be new and empty. Outputs are `artifacts/windows-server/` and `artifacts/windows-client/`. The server payload includes API, worker, Next.js standalone pages/assets, Node, PostgreSQL, Caddy, WinSW and the setup/maintenance scripts. The client build uses `connected-client` and the dedicated client configuration, which replaces the PostgreSQL resource list.

## Install and configure the server

1. Install **SBCO Server** on a Windows 10/11 x64 computer with sufficient protected local storage. The MSI installs binaries in `Program Files\SBCO Server`; it does not accept passwords as MSI properties.
2. Arrange a hostname that resolves to this computer from the server and client machines. Obtain a certificate chain and unencrypted PEM private key for that hostname from the office's approved CA. The CA must be trusted by Windows on the server and clients. Setup does not create a pretend certificate or bypass certificate validation.
3. Open **Configure SBCO Server** from the Start menu and approve Windows elevation. Enter the hostname, certificate/key paths and first administrator details. Password entry is masked and confirmed; it is passed to the bootstrap process only through its private child environment and is not saved as a setup argument.
4. Choose whether to allow inbound **TCP 443 on Private/Domain networks**. No database or API port is opened in Windows Firewall. Ensure the machine is on the appropriate network profile and DNS/certificate routing is correct.
5. Setup verifies the local API/web responses and the actual trusted HTTPS endpoint. Only after successful checks does it mark configuration complete. Open the address shown and sign in.

Data, protected service configuration, logs, certificate files and backups live under `%ProgramData%\SBCO Server`. API/worker connection strings contain the local database secret and must remain protected. The database password is randomly generated; the temporary initialization password file is removed.

The five service names are `SBCOPostgres`, `SBCOApi`, `SBCOWorker`, `SBCOWeb` and `SBCOHttps`. PostgreSQL binds `127.0.0.1:55439`, API binds `127.0.0.1:8091`, web pages bind `127.0.0.1:3091`, and Caddy exposes HTTPS 443. Setup refuses occupied ports instead of changing another application.

Services use WinSW's documented **LocalService** account configuration with individual service SIDs. ACLs grant administrators/SYSTEM full control and each service only its own required directories; parent directories grant traversal without inherited access to other services' secrets. PostgreSQL initialization runs under the same restricted identity as the database service. Its new-cluster locale explicitly uses PostgreSQL's built-in `C.UTF-8` provider, avoiding dependence on Windows libc locale naming. See the [WinSW account specification](https://github.com/winsw/winsw/blob/v2.12.0/doc/xmlConfigFile.md#localservice-account) and [PostgreSQL initialization options](https://www.postgresql.org/docs/18/app-initdb.html).

A protected initializer runs `initdb` under that same PostgreSQL service identity. It publishes an atomic exit-code result carrying a fresh nonce and remains running until elevated setup explicitly stops it. Setup validates the result and PostgreSQL 18 cluster before switching the service to the database server. This avoids WinSW 2.12.0's restricted-account completion problem for successful short-lived children without granting additional service-manager rights. The [WinSW completion path](https://github.com/winsw/winsw/blob/v2.12.0/src/WinSW/WrapperService.cs#L360-L389) treats exit code zero differently from a nonzero child failure. Existing clusters and stale results are refused. Initialization diagnostics remain in the private `database/initdb-NONCE.log`; the restricted initializer does not read the administrator-only installation ownership file.

## Repeat setup, repairs and uninstall

Certificate/key, hostname resolution and Windows certificate trust are checked using a temporary HTTPS endpoint before any database is created. A failed TLS preflight can be corrected and setup retried normally. Once all service configurations and administrator bootstrap succeed, setup records a protected checkpoint before starting application services. Repeated configuration resumes from that checkpoint and checks health without overwriting the database, certificate configuration or administrator accounts. This also permits retry after a service startup or health-check failure. A failure before bootstrap completes leaves partial data protected for operator review; it is never automatically reinitialized. A foreign data directory or conflicting service is refused. If first setup fails, services created by that attempt are stopped/unregistered and its newly created firewall rule is removed.

MSI maintenance stops owned services before replacing/removing binaries. Uninstall unregisters them and removes only its owned firewall rule while preserving `%ProgramData%\SBCO Server`. Reinstall at the same fixed path can register the saved service configurations again; a previously approved firewall rule is restored on resume. Service wrapper binaries may be refreshed from the installed package, but operator XML/configuration and database files are retained. Foreign same-name services or firewall rules are not adopted or deleted.

Installer rollback hooks stop newly resumed services and attempt to resume the restored installation. They do not reverse PostgreSQL application schema migrations. Before any version-changing upgrade, keep a verified backup and a rollback plan compatible with that schema version. Future database major upgrades require a planned migration; an installer must not replace a cluster's major version in place.

## Backups and operator maintenance

Run the following in an elevated Windows PowerShell session:

```powershell
& "$env:ProgramFiles\SBCO Server\server\Backup-Server.ps1"
& "$env:ProgramFiles\SBCO Server\server\Manage-Services.ps1" -Action Stop
& "$env:ProgramFiles\SBCO Server\server\Manage-Services.ps1" -Action Resume
```

Backups use PostgreSQL custom archives, archive inspection and a SHA-256 sidecar. They include the entire database, including practice workspaces. Copy successful backups to separate protected storage. Guided setup offers an explicit opt-in daily schedule after the server is healthy; operators can also enable, disable or inspect it with `Set-BackupSchedule.ps1`. The default is 02:00 local time with 14 successful scheduled backups retained. Manual backups remain outside scheduled retention. Uninstall removes the owned task while preserving archives and settings; reinstall requires explicit re-enabling. See [Windows server backups](WINDOWS_SERVER_BACKUPS.md). [Native backup/restore rehearsal 40883720195](https://github.com/sbcohelp-source/sbco/actions/runs/40883720195) passed against the final server MSI. Operators must still verify their actual backup location and restore procedure on an isolated database before relying on office backups.

## Native acceptance required

On both Windows 10 and Windows 11, verify clean installation, ordinary-client startup, server service accounts/SIDs and effective ACLs, initialization, TLS trust and hostname errors, firewall consent, multi-client login/role isolation, imports, reports, training reset, restart after interruption, backup/restore, repair, uninstall/reinstall persistence and upgrade rollback. Test Unicode/spaced paths and machines without preinstalled WebView2. Check all DLL dependencies and event/service logs. MSI generation alone does not establish these results.

## Disposable Windows packaging smoke test

After a successful **Build Windows server and client installers** run, dispatch **Smoke test Windows server and client installers** with that run's numeric ID. The separate workflow accepts artifacts only from a successful manual build in this repository and downloads both named installer artifacts with read-only Actions access.

The smoke script refuses ordinary/local hosts and pre-existing SBCO products, services or data. Before executing either MSI, it verifies the supplied SHA-256, product names, distinct product/upgrade identities, x64 package metadata, 64-bit server PowerShell launchers and absence of PostgreSQL resources in the connected client. It then performs quiet fresh installation, same-package repair and uninstall with a five-minute limit per operation. A clearly marked test-only file verifies server ProgramData retention; no server configuration, administrator bootstrap, database initialization or office service startup is requested. Logs, package identity evidence and the source commit are retained for 14 days, including on failure.

This test runs on the ephemeral `windows-2025` GitHub image. Passing it is packaging evidence only, not Windows 10/11 qualification, a signed-release claim or office acceptance. The server launchers deliberately use `System64Folder`: [Microsoft documents SystemFolder as the 32-bit system path on 64-bit Windows](https://learn.microsoft.com/en-us/windows/win32/msi/systemfolder).

## Scheduled backup runtime rehearsal

The separate **Rehearse Windows scheduled backups and restore** workflow accepts a successful installer build run that includes the backup scripts. It verifies the server MSI checksum and identity, refuses existing SBCO data/services/tasks, installs into a disposable GitHub Windows runner, and creates a clearly marked temporary PostgreSQL fixture through the installed service provisioning helpers. It invokes Task Scheduler as SYSTEM, checks the dump/checksum/status, restores into a second temporary database, compares Unicode text, leading-zero account text, exact numeric values and binary content, and exercises scheduled retention while preserving a manual backup. It also checks disable behavior and uninstall cleanup while confirming database/backup preservation.

This rehearsal does not configure an office, issue a TLS certificate, create an application administrator or start the API, worker or web services. Artifacts contain installer logs and result metadata only, excluding credential files and database/dump contents. A passing run is evidence for the tested hosted Windows image, not Windows 10/11 office qualification. See [Windows server backups](WINDOWS_SERVER_BACKUPS.md) for operator scheduling and recovery instructions.

[Run 40883720195](https://github.com/sbcohelp-source/sbco/actions/runs/40883720195) passed against server build `40881136580`, source `ac85c31`: a real SYSTEM scheduled task created the dump, the restored two-row fixture retained Unicode, leading-zero account text, exact amounts and binary content, retention preserved the manual archive, both enabled and disabled task states survived simulated uninstall rollback, and uninstall removed the task while preserving database and backup data.

## Full shared-server runtime rehearsal

**Rehearse Windows shared server services** verifies a successful same-repository build, installs its server MSI on an empty disposable `windows-2025` runner, and executes the actual installed guided setup under Windows PowerShell 5.1. A strict test prompt wrapper supplies only generated fixture credentials, a localhost hostname and a temporary certificate. The exact generated public-certificate thumbprint is trusted for the test and removed afterward; no certificate-validation bypass or office certificate is used. The fixture declines firewall and backup scheduling prompts.

The script checks all five services, trusted HTTPS, secure session-cookie flags, sign-in, a downloaded setup workbook, a two-row import processed by the worker, a PDF export, isolated training creation/reset, API child crash recovery, explicit service restart, configured MSI repair and uninstall data preservation. Only the exact API child of the owned service wrapper is terminated for the crash test. Subprocesses and installer calls have time limits. Credentials, private keys, database files and dumps are excluded from artifacts; sanitized service/initializer logs and result metadata are retained.

[Run 40883757329](https://github.com/sbcohelp-source/sbco/actions/runs/40883757329) passed all checks above against installer build `40881136580`, source `ac85c31`. The verified server MSI SHA-256 is `525f3e63d6cecad2d0f962e2a23732bc5c2927412b6f0f7f4c7335fbf13bbce2`; the retained `server-rehearsal.json` records five services, two imported rows and each successful lifecycle check. This includes the protected initializer handshake and actual API crash recovery without additional service-control grants. Later installer revisions must repeat the relevant checks. This hosted success does not qualify a real office's Windows 10/11 machine, certificate, firewall, backup storage or installed client GUI.

## Same-version major-upgrade rehearsal

**Rehearse Windows server same-version upgrade** uses the already-built older server `40873108070` (`9ec44f9`) and corrected server `40881136580` (`ac85c31`) by default. Both are version `0.1.0`, with different product codes and the same upgrade code. The workflow validates both build provenances and checksums before the disposable runner installs anything. It configures the older server, creates real records, an enabled backup schedule and a real PostgreSQL archive, then installs the corrected MSI over it. Because the older backup script has a known connection defect, only fixture tooling creates that initial archive through protected process environment variables; the old installed script is neither patched nor claimed to have passed.

The upgrade checks account/session, exact transaction records, protected configuration, task ownership/preferences and archive preservation. It then starts the real SYSTEM backup task using the upgraded script and checks its result and checksum, followed by API crash recovery, restart, MSI repair and uninstall preservation. Artifacts retain product identities, package hashes and result metadata, never credentials, database files or archives. Hosted execution is still pending until its result is recorded.

The installer currently sets `AllowSameVersionUpgrades="yes"` and schedules removal after `InstallInitialize`. [WiX documents](https://docs.firegiant.com/wix3/xsd/wix/majorupgrade/) that this permits same-version major upgrades and transactional restoration of the previous product if installation fails. It also permits reverse replacement between packages whose first three version fields are equal. Therefore this rehearsal does **not** certify versioned downgrade blocking. Future public releases need deliberate version increments and their own upgrade qualification. The old uninstall suppresses service/task removal during upgrade using [Windows Installer's `UPGRADINGPRODUCTCODE` property](https://learn.microsoft.com/en-us/windows/win32/msi/upgradingproductcode); normal uninstall still removes the owned services/task while preserving data.
