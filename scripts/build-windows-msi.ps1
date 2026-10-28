#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PostgresRoot,
    [Parameter(Mandatory = $true)][string]$LicenseDirectory,
    [string]$OutputDirectory = '',
    [switch]$SkipDependencyInstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'A Windows x64 build host is required to produce the MSI.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts/windows-msi' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
foreach ($tool in @('node', 'yarn', 'cargo', 'rustup')) { Get-Command $tool -ErrorAction Stop | Out-Null }
foreach ($image in @('banner.bmp', 'dialog.bmp')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "apps/desktop/src-tauri/installer/branding/$image"))) { throw "Missing installer branding: $image" }
}
& (Join-Path $PSScriptRoot 'package-postgres-windows.ps1') -PostgresRoot $PostgresRoot -LicenseDirectory $LicenseDirectory
$previousDesktop = $env:SBCO_DESKTOP
Push-Location $repoRoot
try {
    if (-not $SkipDependencyInstall) {
        & yarn install --frozen-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
    }
    & rustup target add x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Windows Rust target installation failed.' }
    # PowerShell environment assignment avoids the POSIX-only build:desktop script.
    $env:SBCO_DESKTOP = '1'
    & yarn workspace '@sbco/web' build
    if ($LASTEXITCODE -ne 0) { throw 'Desktop frontend build failed.' }
    Set-Location (Join-Path $repoRoot 'apps/desktop')
    & (Join-Path $repoRoot 'node_modules/.bin/tauri.cmd') build --config src-tauri/tauri.windows.conf.json --target x86_64-pc-windows-msvc --bundles msi
    if ($LASTEXITCODE -ne 0) { throw 'Windows MSI build failed.' }
    $bundleDirectory = Join-Path $repoRoot 'apps/desktop/src-tauri/target/x86_64-pc-windows-msvc/release/bundle/msi'
    $installers = @(Get-ChildItem -LiteralPath $bundleDirectory -Filter '*.msi' -File)
    if ($installers.Count -eq 0) { throw 'Build did not produce an MSI.' }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($installer in $installers) {
        $output = Join-Path $OutputDirectory $installer.Name
        Copy-Item -LiteralPath $installer.FullName -Destination $output -Force
        $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$output.sha256" -Value "$hash  $($installer.Name)" -Encoding utf8NoBOM
    }
    Write-Host "Unsigned MSI and SHA-256 files: $OutputDirectory"
    Write-Host 'This build does not certify native Windows installation, recovery or offline operation.'
}
finally {
    $env:SBCO_DESKTOP = $previousDesktop
    Pop-Location
}
