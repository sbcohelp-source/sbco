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
function Get-FreshStandaloneInstaller([string]$BundleDirectory,[DateTime]$BuildStarted,[string]$ExpectedName) {
    $installers=@(Get-ChildItem -LiteralPath $BundleDirectory -Filter '*.msi' -File | Where-Object { $_.Name -ceq $ExpectedName -and $_.LastWriteTimeUtc -ge $BuildStarted })
    if($installers.Count -ne 1){throw "Build did not produce the expected fresh standalone MSI: $ExpectedName"}
    return $installers[0]
}
function Assert-StandaloneOutput([string]$Directory,[string]$ExpectedName) {
    if(-not (Test-Path -LiteralPath $Directory)){return}
    foreach($file in Get-ChildItem -LiteralPath $Directory -File){
        if(($file.Name.EndsWith('.msi') -or $file.Name.EndsWith('.msi.sha256')) -and $file.Name -cnotin @($ExpectedName,"$ExpectedName.sha256")){
            throw 'Output directory contains another installer product/version; choose an empty output directory.'
        }
    }
}
if (-not $IsWindows) { throw 'A Windows x64 build host is required to produce the MSI.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts/windows-msi' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$config=Get-Content -LiteralPath (Join-Path $repoRoot 'apps/desktop/src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json
$expectedName="$($config.productName)_$($config.version)_x64_en-US.msi"
Assert-StandaloneOutput $OutputDirectory $expectedName
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
    $buildStarted = [DateTime]::UtcNow.AddSeconds(-2)
    & (Join-Path $repoRoot 'node_modules/.bin/tauri.cmd') build --config src-tauri/tauri.windows.conf.json --target x86_64-pc-windows-msvc --bundles msi
    if ($LASTEXITCODE -ne 0) { throw 'Windows MSI build failed.' }
    $bundleDirectory = Join-Path $repoRoot 'apps/desktop/src-tauri/target/x86_64-pc-windows-msvc/release/bundle/msi'
    $installers = @(Get-FreshStandaloneInstaller $bundleDirectory $buildStarted $expectedName)
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
