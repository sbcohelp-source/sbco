#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PostgresRoot,
    [Parameter(Mandatory = $true)][string]$LicenseDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Package native Windows PostgreSQL on Windows with PowerShell 7.' }

$repoRoot = Split-Path -Parent $PSScriptRoot
$postgresSource = (Resolve-Path -LiteralPath $PostgresRoot).Path
$licenseSource = (Resolve-Path -LiteralPath $LicenseDirectory).Path
$destination = Join-Path $repoRoot 'apps/desktop/src-tauri/resources/postgres'

function Assert-NativePe64([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "Not a Windows PE file: $Path" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 6)) { throw "Invalid PE header: $Path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) { throw "Expected native Windows x64 PE: $Path" }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}

foreach ($directory in @('bin', 'lib', 'share')) {
    if (-not (Test-Path -LiteralPath (Join-Path $postgresSource $directory) -PathType Container)) { throw "Missing PostgreSQL $directory directory." }
}
if (-not (Test-Path -LiteralPath $licenseSource -PathType Container)) { throw 'Provide the distribution license/documentation directory.' }
if (-not (Get-ChildItem -LiteralPath $licenseSource -File -Recurse | Select-Object -First 1)) { throw 'License/documentation directory must not be empty.' }
$resourceSources = @((Join-Path $postgresSource 'bin'), (Join-Path $postgresSource 'lib'), (Join-Path $postgresSource 'share'), $licenseSource)
foreach ($source in $resourceSources) {
    $entries = @((Get-Item -LiteralPath $source)) + @(Get-ChildItem -LiteralPath $source -Force -Recurse)
    if ($entries | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }) { throw 'Reparse points are not permitted in packaged resources.' }
}
foreach ($name in @('postgres', 'initdb', 'pg_ctl', 'pg_dump', 'pg_restore', 'createdb', 'dropdb')) {
    Assert-NativePe64 (Join-Path $postgresSource "bin/$name.exe")
}
foreach ($file in Get-ChildItem -LiteralPath $resourceSources -File -Recurse) {
    if ($file.Extension -in @('.exe', '.dll')) { Assert-NativePe64 $file.FullName }
    $stream = [System.IO.File]::OpenRead($file.FullName)
    try {
        $magic = [byte[]]::new(4)
        $read = $stream.Read($magic, 0, 4)
        if ($read -eq 4 -and $magic[0] -eq 0x7F -and $magic[1] -eq 0x45 -and $magic[2] -eq 0x4C -and $magic[3] -eq 0x46) { throw "Linux ELF payload is prohibited: $($file.FullName)" }
    }
    finally { $stream.Dispose() }
}
$version = & (Join-Path $postgresSource 'bin/postgres.exe') --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^postgres \(PostgreSQL\) 18\.6(?:\s|$)') { throw 'Native PostgreSQL 18.6 is required.' }

$staging = "$destination.staging-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($directory in @('bin', 'lib', 'share')) {
        Copy-Item -LiteralPath (Join-Path $postgresSource $directory) -Destination (Join-Path $staging $directory) -Recurse
    }
    Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $staging 'licenses') -Recurse
    Get-ChildItem -LiteralPath $postgresSource -Filter '*license*.txt' -File | Copy-Item -Destination (Join-Path $staging 'licenses') -Force
    $manifest = foreach ($file in Get-ChildItem -LiteralPath $staging -File -Recurse | Sort-Object FullName) {
        $relative = [System.IO.Path]::GetRelativePath($staging, $file.FullName).Replace('\', '/')
        '{0}  {1}' -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
    }
    Set-Content -LiteralPath (Join-Path $staging 'SHA256SUMS') -Value $manifest -Encoding utf8NoBOM
    # This is a generated installer resource directory, never the user's database.
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    Move-Item -LiteralPath $staging -Destination $destination
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
Write-Host "Packaged native PostgreSQL 18.6 x64 resources: $destination"
