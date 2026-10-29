# Helpers loaded only by the guarded disposable Windows server-runtime harness.
Set-StrictMode -Version Latest
function Assert-UpgradeIdentity($OldCode,$NewCode,$OldVersion,$NewVersion,$UpgradeCode) {
    if([guid]$OldCode -eq [guid]$NewCode -or $OldVersion -cne $NewVersion -or [guid]$UpgradeCode -ne [guid]'126a311d-74cf-4427-9422-12b3182ea43e'){
        throw 'Upgrade fixture requires distinct product codes, equal versions and the SBCO Server upgrade identity.'
    }
}
function Read-UpgradePackage([string]$Directory,[string]$OldCode,[string]$OldVersion) {
    $files=@(Get-ChildItem -LiteralPath $Directory -Filter '*.msi' -File)
    if($files.Count -ne 1){throw 'Exactly one upgrade server MSI required.'}
    $file=$files[0];$manifest=(Get-Content -LiteralPath ($file.FullName+'.sha256') -Raw).Trim()
    if($manifest -notmatch '^([a-fA-F0-9]{64})  (.+)$' -or $Matches[2] -cne $file.Name){throw 'Invalid upgrade checksum manifest.'}
    $hash=$Matches[1].ToLowerInvariant()
    if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $hash){throw 'Upgrade MSI checksum mismatch.'}
    $db=$installer.OpenDatabase($file.FullName,0)
    try {
        $code=Read-MsiProperty $db 'ProductCode';$version=Read-MsiProperty $db 'ProductVersion'
        if((Read-MsiProperty $db 'ProductName') -cne 'SBCO Server' -or (Read-MsiProperty $db 'Manufacturer') -cne 'S K Singh'){throw 'Unexpected upgrade MSI product.'}
        Assert-UpgradeIdentity $OldCode $code $OldVersion $version (Read-MsiProperty $db 'UpgradeCode')
        if($installer.ProductState($code) -ne -1){throw 'Upgrade product already registered.'}
        return @{path=$file.FullName;code=$code;version=$version;sha256=$hash}
    } finally {[Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)|Out-Null}
}
function New-PreUpgradeArchive([string]$Destination) {
    # The old packaged backup script has a known connection bug. This fixture
    # uses its bundled tool directly; it never changes the installed old script.
    [xml]$config=Get-Content -LiteralPath (Join-Path $dataPath 'services\SBCOApi\SBCOApi.xml') -Raw -Encoding UTF8
    $entry=@($config.service.env|Where-Object name -eq 'DATABASE_URL')
    if($entry.Count -ne 1){throw 'Expected one private fixture database connection.'}
    $uri=[uri]$entry[0].value
    if($uri.Scheme -cne 'postgresql' -or $uri.Host -cne '127.0.0.1' -or $uri.Port -ne 55439 -or $uri.AbsolutePath -cne '/sbco'){throw 'Unexpected fixture database endpoint.'}
    $user=$uri.UserInfo.Split(':',2);if($user.Count -ne 2){throw 'Invalid fixture database credentials.'}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $installPath 'postgres\bin\pg_dump.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment['PGHOST']='127.0.0.1';$info.Environment['PGHOSTADDR']='127.0.0.1';$info.Environment.Remove('PGSERVICE')|Out-Null;$info.Environment['PGPORT']='55439';$info.Environment['PGDATABASE']='sbco'
    $info.Environment['PGUSER']=[uri]::UnescapeDataString($user[0]);$info.Environment['PGPASSWORD']=[uri]::UnescapeDataString($user[1]);$info.Environment['PGCONNECT_TIMEOUT']='10'
    foreach($argument in @('--no-password','--format=custom','--file',$Destination)){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try{
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(120000)){$process.Kill($true);$process.WaitForExit();throw 'Pre-upgrade fixture archive timed out.'}
        if($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Destination)){throw 'Pre-upgrade fixture archive failed.'}
        $null=$stdout.Result;$null=$stderr.Result
    }finally{$info.Environment.Remove('PGPASSWORD')|Out-Null;$process.Dispose()}
    $bytes=[IO.File]::ReadAllBytes($Destination)
    if($bytes.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($bytes,0,5) -cne 'PGDMP'){throw 'Fixture archive is not a custom PostgreSQL dump.'}
}
function Invoke-ServerUpgradeFixture($Package) {
    $beforeActor=Call-Server 'me'
    $beforeRows=(Call-Server 'query' @{kind='transactions';filter=$filter;cursor=$null;limit=50})|ConvertTo-Json -Depth 20 -Compress
    $configurationFiles=@('ownership.json','configured.json','tls\certificate.pem','tls\private-key.pem','tls\Caddyfile')
    foreach($service in $serviceNames){$configurationFiles+="services\$service\$service.xml"}
    $preserved=@{};foreach($relative in $configurationFiles){
        $path=Join-Path $dataPath $relative
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Expected protected server configuration is missing.'}
        $preserved[$relative]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $backupDirectory=Join-Path $dataPath 'backups';[IO.Directory]::CreateDirectory($backupDirectory)|Out-Null
    $archive=Join-Path $backupDirectory 'sbco-before-upgrade.dump';New-PreUpgradeArchive $archive
    $archiveHash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $schedule=Join-Path $installPath 'server\Set-BackupSchedule.ps1'
    $nextAutomaticRun=[DateTime]::Now.AddHours(12)
    $scheduleTime=$nextAutomaticRun.ToString('HH:mm')
    $null=& $schedule -Action Enable -Time $scheduleTime -Retention 3
    # Retain the real future date across midnight; the production preference is
    # time-only, but this fixture must never auto-run while replacing binaries.
    $futureTrigger=New-ScheduledTaskTrigger -Daily -At $nextAutomaticRun
    Set-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\' -Trigger $futureTrigger | Out-Null
    if((Get-ScheduledTaskInfo -TaskName 'SBCO Server Daily Backup' -TaskPath '\').NextRunTime -le [DateTime]::Now.AddMinutes(45) -or (Get-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\').State -eq 'Running'){throw 'Fixture backup trigger is not safely beyond the rehearsal deadline.'}
    . (Join-Path $installPath 'server\Backup-Common.ps1')
    $oldTask=Get-OwnedBackupTask;if($null -eq $oldTask -or $oldTask.State -eq 'Disabled'){throw 'Pre-upgrade task not enabled.'}
    $taskXml=Export-ScheduledTask -TaskName $BackupTaskName -TaskPath '\'
    $scheduleHash=(Get-FileHash -LiteralPath (Join-Path $dataPath 'backup-schedule.json') -Algorithm SHA256).Hash
    $oldCode=$productCode
    Invoke-RehearsalMsi '/i' $Package.path 'server-major-upgrade'
    $script:productCode=$Package.code
    if($installer.ProductState($oldCode) -ne -1 -or $installer.ProductState($Package.code) -ne 5){throw 'Upgrade did not replace the old registered product.'}
    Assert-ServicesReady
    $afterActor=Call-Server 'me'
    if($afterActor.id -cne $beforeActor.id -or $afterActor.name -cne $beforeActor.name -or $afterActor.role -cne $beforeActor.role){throw 'Upgrade changed account/session identity.'}
    if(((Call-Server 'query' @{kind='transactions';filter=$filter;cursor=$null;limit=50})|ConvertTo-Json -Depth 20 -Compress) -cne $beforeRows){throw 'Upgrade changed fixture transaction records.'}
    foreach($relative in $preserved.Keys){if((Get-FileHash -LiteralPath (Join-Path $dataPath $relative) -Algorithm SHA256).Hash -cne $preserved[$relative]){throw 'Upgrade changed protected existing configuration.'}}
    . (Join-Path $installPath 'server\Backup-Common.ps1')
    $task=Get-OwnedBackupTask;$settings=Read-BackupSchedule
    if($null -eq $task -or $task.State -eq 'Disabled' -or -not $settings.enabled -or $settings.time -cne $scheduleTime -or $settings.retention -ne 3 -or (Export-ScheduledTask -TaskName $BackupTaskName -TaskPath '\') -cne $taskXml -or (Get-FileHash -LiteralPath (Join-Path $dataPath 'backup-schedule.json') -Algorithm SHA256).Hash -cne $scheduleHash){throw 'Upgrade changed the owned backup task or preferences.'}
    $started=[DateTime]::Now;Start-ScheduledTask -TaskName $BackupTaskName -TaskPath '\'
    Wait-Condition {
        $info=Get-ScheduledTaskInfo -TaskName $BackupTaskName -TaskPath '\'
        if($info.LastRunTime -lt $started.AddSeconds(-2) -or $info.LastTaskResult -ne 0 -or (Get-ScheduledTask -TaskName $BackupTaskName -TaskPath '\').State -eq 'Running'){return $false}
        $statusPath=Join-Path $dataPath 'backup-status.json';if(-not(Test-Path -LiteralPath $statusPath)){return $false}
        $state=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
        $state.result -eq 'succeeded' -and $state.mode -eq 'scheduled' -and [DateTime]$state.started_at -ge $started.AddSeconds(-2).ToUniversalTime()
    } 'post-upgrade SYSTEM backup' 120
    $state=Get-Content -LiteralPath (Join-Path $dataPath 'backup-status.json') -Raw|ConvertFrom-Json
    if($state.file -notmatch '^auto-[0-9]{8}-[0-9]{6}-[a-f0-9]{32}\.dump$'){throw 'Unexpected scheduled backup filename.'}
    $dump=Join-Path $backupDirectory $state.file;$dumpHash=(Get-FileHash -LiteralPath $dump -Algorithm SHA256).Hash.ToLowerInvariant()
    if($dumpHash -cne $state.sha256 -or (Get-Content -LiteralPath "$dump.sha256" -Raw).Trim() -cne "$dumpHash  $($state.file)" -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $archiveHash){throw 'Upgrade archive preservation or new backup checksum failed.'}
    # The existing common tail verifies exact-owned API crash recovery and a
    # configured restart/repair/uninstall with the upgraded product selected.
    $script:upgradeResult=@{old_product_code=$oldCode;new_product_code=$Package.code;version=$Package.version;old_msi_sha256=$expectedHash;new_msi_sha256=$Package.sha256;database_and_session_preserved=$true;configuration_preserved=$true;task_and_preferences_preserved=$true;archive_preserved=$true;new_system_backup_succeeded=$true;archive_path=$archive;archive_sha256=$archiveHash}
}
