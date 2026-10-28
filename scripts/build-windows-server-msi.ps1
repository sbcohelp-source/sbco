#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PostgresRoot,
    [Parameter(Mandatory = $true)][string]$PostgresLicenseDirectory,
    [Parameter(Mandatory = $true)][string]$NodeRoot,
    [Parameter(Mandatory = $true)][string]$WinSwPath,
    [Parameter(Mandatory = $true)][string]$CaddyPath,
    [Parameter(Mandatory = $true)][string]$ThirdPartyLicenseDirectory,
    [Parameter(Mandatory = $true)][string]$WixRoot,
    [switch]$SkipDependencyInstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Build the Windows server MSI on a Windows x64 host.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
$payload = Join-Path $repoRoot 'artifacts/windows-server-payload'
$output = Join-Path $repoRoot 'artifacts/windows-server'
$work = Join-Path $repoRoot 'artifacts/windows-server-wix'
foreach ($tool in @('candle.exe', 'light.exe', 'heat.exe')) { if (-not (Test-Path (Join-Path $WixRoot $tool))) { throw "Missing WiX tool $tool" } }
& (Join-Path $PSScriptRoot 'package-postgres-windows.ps1') -PostgresRoot $PostgresRoot -LicenseDirectory $PostgresLicenseDirectory
$oldDesktop = $env:SBCO_DESKTOP
$oldApi = $env:SBCO_API_URL
Push-Location $repoRoot
try {
    if (-not $SkipDependencyInstall) { & yarn install --frozen-lockfile; if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' } }
    & rustup target add x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Windows target installation failed.' }
    & cargo build --release --locked --target x86_64-pc-windows-msvc -p sbco-api -p sbco-worker
    if ($LASTEXITCODE -ne 0) { throw 'Server binaries failed to build.' }
    $env:SBCO_DESKTOP = '0'; $env:SBCO_API_URL = 'http://127.0.0.1:8091'
    & yarn workspace '@sbco/web' build
    if ($LASTEXITCODE -ne 0) { throw 'Standalone web server failed to build.' }
    if (Test-Path $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
    foreach ($directory in @($payload, $output, $work, (Join-Path $payload 'bin'), (Join-Path $payload 'tools'), (Join-Path $payload 'node'))) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    foreach ($binary in @('sbco-api.exe', 'sbco-worker.exe')) { Copy-Item (Join-Path $repoRoot "target/x86_64-pc-windows-msvc/release/$binary") (Join-Path $payload 'bin') }
    Copy-Item (Join-Path $repoRoot 'apps/desktop/src-tauri/resources/postgres') (Join-Path $payload 'postgres') -Recurse
    Copy-Item (Join-Path $repoRoot 'apps/web/.next-web/standalone') (Join-Path $payload 'web') -Recurse
    Copy-Item (Join-Path $repoRoot 'apps/web/.next-web/static') (Join-Path $payload 'web/apps/web/.next-web/static') -Recurse
    Copy-Item (Join-Path $repoRoot 'apps/web/public') (Join-Path $payload 'web/apps/web/public') -Recurse
    Copy-Item (Join-Path $NodeRoot 'node.exe') (Join-Path $payload 'node/node.exe')
    Copy-Item (Join-Path $NodeRoot 'LICENSE') (Join-Path $payload 'node/LICENSE')
    $version = & (Join-Path $payload 'node/node.exe') --version
    if ($LASTEXITCODE -ne 0 -or $version -ne 'v26.12.1') { throw 'Node.js 26.12.1 x64 is required.' }
    Copy-Item -LiteralPath $WinSwPath -Destination (Join-Path $payload 'tools/winsw.exe')
    Copy-Item -LiteralPath $CaddyPath -Destination (Join-Path $payload 'tools/caddy.exe')
    Copy-Item -LiteralPath $ThirdPartyLicenseDirectory -Destination (Join-Path $payload 'licenses') -Recurse
    Copy-Item (Join-Path $repoRoot 'LICENSE') (Join-Path $payload 'LICENSE')
    Copy-Item (Join-Path $repoRoot 'crates/documents/fonts/LICENSE.txt') (Join-Path $payload 'licenses/Noto-OFL.txt')
    Copy-Item (Join-Path $repoRoot 'deploy/windows/server') (Join-Path $payload 'server') -Recurse
    $manifest = foreach ($file in Get-ChildItem $payload -File -Recurse | Sort-Object FullName) { '{0}  {1}' -f (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), ([IO.Path]::GetRelativePath($payload,$file.FullName).Replace('\','/')) }
    Set-Content (Join-Path $payload 'SHA256SUMS') $manifest -Encoding utf8NoBOM
    # WiX UI expects RTF; retain the repository license text unchanged in payload.
    $license = Get-Content (Join-Path $repoRoot 'LICENSE') -Raw
    $rtf = '{\rtf1\ansi\deff0{\fonttbl{\f0 Courier New;}}\f0\fs16 ' + $license.Replace('\','\\').Replace('{','\{').Replace('}','\}').Replace("`r",'').Replace("`n",'\par ') + '}'
    $licenseRtf = Join-Path $work 'license.rtf'; Set-Content $licenseRtf $rtf -Encoding ascii
    $harvest = Join-Path $work 'payload.wxs'
    & (Join-Path $WixRoot 'heat.exe') dir $payload -nologo -cg ServerPayload -dr INSTALLFOLDER -srd -sfrag -ag -var var.ServerPayloadDir -out $harvest
    if ($LASTEXITCODE -ne 0) { throw 'WiX payload harvesting failed.' }
    $brand = Join-Path $repoRoot 'apps/desktop/src-tauri/installer/branding'
    $defines = @("-dServerPayloadDir=$payload", "-dAppIcon=$(Join-Path $repoRoot 'apps/desktop/src-tauri/icons/icon.ico')", "-dLicenseRtf=$licenseRtf", "-dBannerBmp=$(Join-Path $brand 'banner.bmp')", "-dDialogBmp=$(Join-Path $brand 'dialog.bmp')")
    & (Join-Path $WixRoot 'candle.exe') -nologo -arch x64 @defines -out "$work\" (Join-Path $repoRoot 'deploy/windows/server/installer.wxs') $harvest
    if ($LASTEXITCODE -ne 0) { throw 'WiX compilation failed.' }
    $msi = Join-Path $output 'SBCO-Server-0.1.0-x64.msi'
    & (Join-Path $WixRoot 'light.exe') -nologo -ext WixUIExtension -out $msi (Join-Path $work 'installer.wixobj') (Join-Path $work 'payload.wixobj')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $msi)) { throw 'Server MSI linking failed.' }
    $hash = (Get-FileHash $msi -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content "$msi.sha256" "$hash  $([IO.Path]::GetFileName($msi))" -Encoding utf8NoBOM
    Copy-Item (Join-Path $payload 'SHA256SUMS') (Join-Path $output 'payload-SHA256SUMS') -Force
    Write-Host "Server MSI, checksum and payload manifest: $output"
}
finally { $env:SBCO_DESKTOP=$oldDesktop;$env:SBCO_API_URL=$oldApi;Pop-Location }
