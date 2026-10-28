#requires -Version 5.1
# Operator-run logical backup. Does not stop services or alter the database.
. (Join-Path $PSScriptRoot 'Server-Common.ps1')
Assert-Administrator
if (-not (Read-OwnedInstallation) -or -not (Test-Path (Join-Path $DataRoot 'configured.json'))) { throw 'A configured SBCO Server is required.' }
[xml]$apiConfig = Get-Content -LiteralPath (Join-Path $DataRoot 'services\SBCOApi\SBCOApi.xml') -Raw
$connection = @($apiConfig.service.env | Where-Object { $_.name -eq 'DATABASE_URL' })
if ($connection.Count -ne 1) { throw 'Database configuration is unavailable.' }
$folder = Join-Path $DataRoot 'backups'
Set-PrivateDirectory $folder
$path = Join-Path $folder ('sbco-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.dump')
$partial = "$path.partial"
$previousDatabase = $env:PGDATABASE
try {
    $env:PGDATABASE = $connection[0].value
    & (Join-Path $InstallRoot 'postgres\bin\pg_dump.exe') -Fc -f $partial
    if ($LASTEXITCODE -ne 0) { throw 'Database backup failed.' }
    & (Join-Path $InstallRoot 'postgres\bin\pg_restore.exe') --list $partial *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Backup archive validation failed.' }
    Move-Item -LiteralPath $partial -Destination $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 "$path.sha256" ($hash + '  ' + [IO.Path]::GetFileName($path))
    Write-Host "Backup saved: $path. Keep a copy on separate protected storage."
}
finally {
    $env:PGDATABASE = $previousDatabase
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
}
