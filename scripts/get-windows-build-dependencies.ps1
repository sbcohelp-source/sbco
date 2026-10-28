#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'Use a new empty destination for verified build inputs.' }
New-Item -ItemType Directory -Path $Destination | Out-Null
$manifest = Get-Content (Join-Path $repoRoot 'deploy/windows/dependencies.json') -Raw | ConvertFrom-Json
function Download-Verified([string]$Url, [string]$Checksum, [string]$Path) {
    if (([uri]$Url).Scheme -ne 'https' -or $Checksum -notmatch '^[0-9a-fA-F]{64}$') { throw 'An HTTPS URL and pinned SHA-256 are required.' }
    Invoke-WebRequest -Uri $Url -OutFile $Path
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Checksum) { throw "Checksum mismatch for $([IO.Path]::GetFileName($Path))" }
}
function Expand-Safe([string]$Archive, [string]$Directory) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $prefix = [IO.Path]::GetFullPath($Directory) + [IO.Path]::DirectorySeparatorChar
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $resolved = [IO.Path]::GetFullPath((Join-Path $Directory $entry.FullName))
            if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Archive contains an escaping path or symbolic link.' }
        }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Directory
}
foreach ($name in @('postgres', 'caddy', 'wix')) {
    $item = $manifest.$name
    $zipPath = Join-Path $Destination "$name.zip"
    Download-Verified $item.url $item.sha256 $zipPath
    Expand-Safe $zipPath (Join-Path $Destination $name)
}
$winsw = Join-Path $Destination 'winsw.exe'
Download-Verified $manifest.winsw.url $manifest.winsw.sha256 $winsw
$nodeFilename = "node-v$($manifest.node.version)-win-x64.zip"
$checksums = (Invoke-WebRequest -Uri $manifest.node.checksum_url).Content
$line = @($checksums -split "`n" | Where-Object { $_ -match ('^[0-9a-fA-F]{64}\s+' + [regex]::Escape($nodeFilename) + '\s*$') })
if ($line.Count -ne 1) { throw 'Exact Node.js archive was not found in the official checksum list.' }
$nodeHash = ($line[0] -split '\s+')[0]
$nodeZip = Join-Path $Destination 'node.zip'
Download-Verified $manifest.node.url $nodeHash $nodeZip
Expand-Safe $nodeZip (Join-Path $Destination 'node')
$pgRoot = Join-Path $Destination 'postgres/pgsql'
$pgNotices = Join-Path $Destination 'postgres-notices'
New-Item -ItemType Directory -Path $pgNotices | Out-Null
foreach ($notice in @('server_license.txt', 'commandlinetools_3rd_party_licenses.txt')) { Copy-Item -LiteralPath (Join-Path $pgRoot $notice) -Destination $pgNotices }
$notices = Join-Path $Destination 'third-party-notices'
New-Item -ItemType Directory -Path $notices | Out-Null
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/winsw/winsw/v$($manifest.winsw.version)/LICENSE.txt" -OutFile (Join-Path $notices 'WinSW-LICENSE.txt')
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/caddyserver/caddy/v$($manifest.caddy.version)/LICENSE" -OutFile (Join-Path $notices 'Caddy-LICENSE.txt')
$paths = @{
    postgres_root=$pgRoot; postgres_licenses=$pgNotices;
    node_root=(Join-Path $Destination "node/node-v$($manifest.node.version)-win-x64");
    winsw=$winsw;caddy=(Join-Path $Destination 'caddy/caddy.exe');
    wix_root=(Join-Path $Destination 'wix');third_party_licenses=$notices;
    node_sha256=$nodeHash
}
$paths | ConvertTo-Json | Set-Content (Join-Path $Destination 'inputs.json') -Encoding utf8NoBOM
Copy-Item (Join-Path $repoRoot 'deploy/windows/dependencies.json') (Join-Path $Destination 'pinned-dependencies.json')
Write-Host "Verified build inputs prepared in $Destination."
