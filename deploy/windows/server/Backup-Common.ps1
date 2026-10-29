# Dot-source AFTER Server-Common.ps1. No side effects or cyclic imports.
$script:BackupTaskName = 'SBCO Server Daily Backup'
function Assert-BackupPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Backup paths must not contain links or junctions.' }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Assert-BackupInstallation {
    foreach ($relative in @('', 'ownership.json', 'configured.json', 'backups', 'backup-schedule.json', 'backup-status.json', 'services\SBCOApi\SBCOApi.xml')) {
        Assert-BackupPath (Join-Path $DataRoot $relative)
    }
    $owned = Read-OwnedInstallation
    if (-not $owned -or -not (Test-Path -LiteralPath (Join-Path $DataRoot 'configured.json'))) { throw 'A configured, owned SBCO Server is required.' }
    return $owned
}
function Get-BackupTaskArguments {
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $InstallRoot 'server\Backup-Server.ps1') + '" -Scheduled'
}
function Get-BackupTaskExecutable { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
function Get-OwnedBackupTask {
    $task = Get-ScheduledTask -TaskName $BackupTaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        $actions = @($task.Actions)
        if ($task.Description -cne "Managed by SBCO Server backup format 1 at $InstallRoot" -or $actions.Count -ne 1 -or
            $actions[0].Execute -ine (Get-BackupTaskExecutable) -or $actions[0].Arguments -cne (Get-BackupTaskArguments) -or
            $actions[0].WorkingDirectory -ine $InstallRoot -or $task.Principal.UserId -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18') -or
            [string]$task.Principal.LogonType -ne 'ServiceAccount') {
            throw 'The reserved backup task belongs to another configuration; it was not changed.'
        }
    }
    return $task
}
function Remove-OwnedBackupSchedule {
    if (-not (Read-OwnedInstallation)) { return }
    $task = Get-OwnedBackupTask
    if ($task) { Unregister-ScheduledTask -TaskName $BackupTaskName -TaskPath '\' -Confirm:$false }
}
function Write-BackupJson([string]$Path, $Value) {
    Assert-BackupPath $Path
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.partial'
    try {
        Write-Utf8 $temporary ($Value | ConvertTo-Json -Depth 5)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Read-BackupSchedule {
    $path = Join-Path $DataRoot 'backup-schedule.json'
    Assert-BackupPath $path
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($settings.format -ne 1 -or $settings.install_root -ine $InstallRoot -or
        $settings.time -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$' -or $settings.retention -lt 1 -or $settings.retention -gt 365 -or
        $settings.enabled -isnot [bool]) { throw 'Backup schedule settings are invalid; no backup files were removed.' }
    return $settings
}
function Remove-ExpiredScheduledBackups([string]$Folder, [int]$Retention, $Owned) {
    if ($Retention -lt 1 -or $Retention -gt 365) { throw 'Retention must be between 1 and 365 successful scheduled backups.' }
    Assert-BackupPath $Folder
    $valid = @(foreach ($file in Get-ChildItem -LiteralPath $Folder -Filter 'auto-*.dump' -File) {
        if ($file.Name -notmatch '^auto-[0-9]{8}-[0-9]{6}-[a-f0-9]{32}\.dump$') { continue }
        try {
            $metadataPath = $file.FullName + '.backup.json'; $checksumPath = $file.FullName + '.sha256'
            foreach ($path in @($file.FullName, $metadataPath, $checksumPath)) { Assert-BackupPath $path }
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($metadata.format -ne 1 -or $metadata.mode -cne 'scheduled' -or $metadata.install_root -ine $InstallRoot -or
                $metadata.install_created_at -cne $Owned.created_at -or $metadata.file -cne $file.Name) { continue }
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($metadata.sha256 -cne $hash -or (Get-Content -LiteralPath $checksumPath -Raw).Trim() -cne ($hash + '  ' + $file.Name)) { continue }
            $file
        } catch { continue } # Unknown, incomplete or corrupt files are preserved for review.
    })
    foreach ($file in @($valid | Sort-Object @{Expression='LastWriteTimeUtc';Descending=$true}, @{Expression='Name';Descending=$true} | Select-Object -Skip $Retention)) {
        Remove-Item -LiteralPath $file.FullName -Force
        Remove-Item -LiteralPath ($file.FullName + '.sha256') -Force
        Remove-Item -LiteralPath ($file.FullName + '.backup.json') -Force
    }
}
function Invoke-BackupArchive([string]$Partial) {
    & (Join-Path $InstallRoot 'postgres\bin\pg_dump.exe') --no-password --format=custom --file=$Partial *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Database backup failed.' }
    & (Join-Path $InstallRoot 'postgres\bin\pg_restore.exe') --list $Partial *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Backup archive validation failed.' }
    if (-not (Test-Path -LiteralPath $Partial) -or (Get-Item -LiteralPath $Partial).Length -eq 0) { throw 'Backup archive is empty.' }
}
function Invoke-ServerBackup([bool]$Scheduled) {
    $owned = Assert-BackupInstallation
    $settings = Read-BackupSchedule
    if ($Scheduled -and (-not $settings -or -not $settings.enabled)) { return } # Queued invocation after disable.
    $folder = Join-Path $DataRoot 'backups'
    Set-PrivateDirectory $folder
    $mode = if ($Scheduled) { 'scheduled' } else { 'manual' }
    $prefix = if ($Scheduled) { 'auto-' } else { 'sbco-' }
    $path = Join-Path $folder ($prefix + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.dump')
    $partial = "$path.partial"; $previousDatabase = $env:PGDATABASE
    $status = @{format=1; mode=$mode; started_at=[DateTime]::UtcNow.ToString('o'); result='running'}
    $statusPath = Join-Path $DataRoot 'backup-status.json'
    try {
        Write-BackupJson $statusPath $status
        [xml]$apiConfig = Get-Content -LiteralPath (Join-Path $DataRoot 'services\SBCOApi\SBCOApi.xml') -Raw
        $connection = @($apiConfig.service.env | Where-Object { $_.name -eq 'DATABASE_URL' })
        if ($connection.Count -ne 1) { throw 'Database configuration is unavailable.' }
        $database = [uri]$connection[0].value
        if ($database.Scheme -ne 'postgresql' -or $database.Host -ne '127.0.0.1' -or $database.Port -ne 55439 -or $database.AbsolutePath -ne '/sbco' -or $database.Query -or $database.Fragment) { throw 'Backup requires the owned local server database.' }
        $env:PGDATABASE = $connection[0].value
        Invoke-BackupArchive $partial
        $hash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::Move($partial, $path)
        Write-Utf8 "$path.sha256" ($hash + '  ' + [IO.Path]::GetFileName($path))
        Write-BackupJson "$path.backup.json" @{format=1; mode=$mode; install_root=$InstallRoot; install_created_at=$owned.created_at; file=[IO.Path]::GetFileName($path); sha256=$hash}
        # Never prune until a complete new dump/checksum/ownership record is published.
        if ($Scheduled) { Remove-ExpiredScheduledBackups $folder $settings.retention $owned }
        $status.result='succeeded'; $status.file=[IO.Path]::GetFileName($path); $status.sha256=$hash
        $status.completed_at=[DateTime]::UtcNow.ToString('o')
        Write-BackupJson $statusPath $status
        Write-Host "Backup verified: $path. Copy it and its checksum to separate protected storage."
    } catch {
        $status.result='failed'; $status.completed_at=[DateTime]::UtcNow.ToString('o')
        Write-BackupJson $statusPath $status
        throw 'SBCO backup failed. Existing backups were preserved unless retention followed a successful new archive. Check available disk space, database service and protected configuration; then retry.'
    } finally {
        $env:PGDATABASE=$previousDatabase
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}
