#requires -Version 7.0
[CmdletBinding()]
param([string]$OutputDirectory = '', [switch]$SkipDependencyInstall)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Build the connected-client MSI on Windows x64.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts/windows-client' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$previousDesktop = $env:SBCO_DESKTOP
Push-Location $repoRoot
try {
    if (-not $SkipDependencyInstall) { & yarn install --frozen-lockfile; if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' } }
    & rustup target add x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Windows target installation failed.' }
    $env:SBCO_DESKTOP = '1'
    & yarn workspace '@sbco/web' build
    if ($LASTEXITCODE -ne 0) { throw 'Client frontend build failed.' }
    Set-Location (Join-Path $repoRoot 'apps/desktop')
    $buildStarted = [DateTime]::UtcNow.AddSeconds(-2)
    & (Join-Path $repoRoot 'node_modules/.bin/tauri.cmd') build --features connected-client --config src-tauri/tauri.connected.conf.json --target x86_64-pc-windows-msvc --bundles msi
    if ($LASTEXITCODE -ne 0) { throw 'Connected-client MSI build failed.' }
    $bundle = Join-Path $repoRoot 'apps/desktop/src-tauri/target/x86_64-pc-windows-msvc/release/bundle/msi'
    $installers = @(Get-ChildItem -LiteralPath $bundle -Filter '*.msi' -File | Where-Object { $_.LastWriteTimeUtc -ge $buildStarted })
    if (-not $installers.Count) { throw 'No fresh SBCO Client MSI was produced.' }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($installer in $installers) {
        $output = Join-Path $OutputDirectory $installer.Name
        Copy-Item -LiteralPath $installer.FullName -Destination $output -Force
        $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$output.sha256" -Value "$hash  $($installer.Name)" -Encoding utf8NoBOM
    }
    Write-Host "Connected-client MSI and checksums: $OutputDirectory"
}
finally { $env:SBCO_DESKTOP = $previousDesktop; Pop-Location }
