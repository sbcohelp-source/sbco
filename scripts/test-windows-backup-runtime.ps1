#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$LogDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $env:RUNNER_TEMP) { throw 'Backup rehearsal requires an ephemeral GitHub-hosted Windows x64 runner.' }
$LogDirectory = [IO.Path]::GetFullPath($LogDirectory)
[IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
$installPath = Join-Path $env:ProgramFiles 'SBCO Server'
$dataPath = Join-Path $env:ProgramData 'SBCO Server'
$fixtureToken = [guid]::NewGuid().ToString('N')
$fixtureCreated = $false; $msiStarted = $false; $msiTimedOut = $false; $productCode = $null
$createdServices = [Collections.Generic.List[string]]::new()
$password = $null
$oldPassword = $env:PGPASSWORD
$installer = New-Object -ComObject WindowsInstaller.Installer
function Read-MsiProperty($Database, [string]$Property) {
    $view = $Database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Property'")
    try { $null = $view.Execute(); $record=$view.Fetch(); if ($null -eq $record) { throw "Missing MSI property $Property" }; try { return $record.StringData(1) } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) | Out-Null } }
    finally { $null = $view.Close(); [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null }
}
function Invoke-TestMsi([string]$Operation, [string]$Target, [string]$Label) {
    $log = Join-Path $LogDirectory "$Label.log"
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList "$Operation `"$Target`" /qn /norestart REBOOT=ReallySuppress /L*v `"$log`"" -PassThru
    try {
        if (-not $process.WaitForExit(300000)) { $script:msiTimedOut=$true; $process.Kill(); throw "MSI $Label timed out; stop further installer operations." }
        if ($process.ExitCode -notin @(0,3010)) { throw "MSI $Label failed, exit $($process.ExitCode)." }
    } finally { $process.Dispose() }
}
function Invoke-TestPg([string]$Tool, [string[]]$Arguments) {
    $result = & (Join-Path $pgBin $Tool) --no-password @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Isolated PostgreSQL operation failed: $Tool" }
    return $result
}
try {
    foreach ($path in @($installPath, $dataPath)) { if (Test-Path -LiteralPath $path) { throw "Existing SBCO installation/data refused: $path" } }
    if (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue) { throw 'Existing SBCO services refused.' }
    if (Get-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Existing backup task refused.' }
    if (Get-NetTCPConnection -State Listen -LocalPort 55439 -ErrorAction SilentlyContinue) { throw 'Required isolated PostgreSQL port is occupied.' }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path $root) { foreach ($entry in Get-ChildItem $root) { if (($entry.GetValue('DisplayName', $null)) -like 'SBCO*') { throw 'Existing SBCO product registration refused.' } } }
    }
    $files = @(Get-ChildItem -LiteralPath $ArtifactDirectory -Filter '*.msi' -File)
    if ($files.Count -ne 1) { throw 'Exactly one server MSI is required.' }
    $msi = $files[0]
    $checksum = (Get-Content -LiteralPath ($msi.FullName+'.sha256') -Raw).Trim()
    if ($checksum -notmatch '^([a-fA-F0-9]{64})  (.+)$' -or $Matches[2] -cne $msi.Name) { throw 'Invalid MSI checksum manifest.' }
    $expectedHash = $Matches[1]
    if ((Get-FileHash -LiteralPath $msi.FullName -Algorithm SHA256).Hash -ine $expectedHash) { throw 'MSI checksum mismatch.' }
    $database = $installer.OpenDatabase($msi.FullName,0)
    try {
        $productCode = Read-MsiProperty $database 'ProductCode'
        if ((Read-MsiProperty $database 'ProductName') -cne 'SBCO Server' -or (Read-MsiProperty $database 'Manufacturer') -cne 'S K Singh' -or [guid](Read-MsiProperty $database 'UpgradeCode') -ne [guid]'126a311d-74cf-4427-9422-12b3182ea43e') { throw 'Unexpected server MSI identity.' }
        if ($installer.ProductState($productCode) -ne -1) { throw 'Server product already registered.' }
    } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) | Out-Null }
    $msiStarted = $true
    Invoke-TestMsi '/i' $msi.FullName 'backup-server-install'
    . (Join-Path $installPath 'server\Server-Common.ps1')
    . (Join-Path $installPath 'server\Backup-Common.ps1')
    Assert-Administrator
    foreach ($scriptName in @('Set-BackupSchedule.ps1','Backup-Server.ps1')) { if (-not (Test-Path -LiteralPath (Join-Path $installPath "server\$scriptName"))) { throw "Installer lacks $scriptName; rebuild before rehearsal." } }
    # Exercise installed production provisioning helpers without running interactive office/TLS setup.
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $installPath 'server\Configure-Server.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Installed setup does not parse.' }
    foreach ($name in @('New-ServiceConfig','Install-NewService','Initialize-PostgresDatabase')) {
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        if ($null -eq $definition) { throw "Missing setup helper $name" }
        Invoke-Expression $definition.Extent.Text
    }
    Set-PrivateDirectory $DataRoot
    $owned=@{format=1;install_root=$InstallRoot;created_at=[DateTime]::UtcNow.ToString('o');test_only=$true;test_token=$fixtureToken}
    Write-Utf8 (Join-Path $DataRoot 'ownership.json') ($owned | ConvertTo-Json)
    $fixtureCreated=$true
    foreach ($folder in @('services','logs','database','backups')) { Set-PrivateDirectory (Join-Path $DataRoot $folder) }
    $pgBin=Join-Path $InstallRoot 'postgres\bin'; $pgData=Join-Path $DataRoot 'database\cluster'
    $password=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $passwordFile=Join-Path $DataRoot 'database\init-password'
    Write-Utf8 $passwordFile $password
    $pgSid=Initialize-PostgresDatabase $pgBin $pgData $passwordFile
    Remove-Item -LiteralPath $passwordFile
    Add-Content -LiteralPath (Join-Path $pgData 'postgresql.conf') -Encoding ASCII -Value "`nlisten_addresses='127.0.0.1'`nport=55439`nmax_connections=20`nunix_socket_directories=''"
    New-ServiceConfig 'SBCOPostgres' (Join-Path $pgBin 'postgres.exe') ('-D "'+$pgData+'"') @{} @() $false
    Set-PrivateDirectory (Join-Path $DataRoot 'services\SBCOPostgres') @($pgSid)
    Invoke-Wrapper 'SBCOPostgres' 'start'
    Wait-Condition { & (Join-Path $pgBin 'pg_isready.exe') -h 127.0.0.1 -p 55439 -U sbco *> $null; $LASTEXITCODE -eq 0 } 'isolated PostgreSQL readiness'
    $env:PGPASSWORD=$password
    $null=Invoke-TestPg 'createdb.exe' @('-h','127.0.0.1','-p','55439','-U','sbco','sbco')
    $null=Invoke-TestPg 'psql.exe' @('-X','-h','127.0.0.1','-p','55439','-U','sbco','-d','sbco','-v','ON_ERROR_STOP=1','-c',"CREATE TABLE backup_fixture (id integer PRIMARY KEY, account text NOT NULL, amount numeric(20,2) NOT NULL, note text NOT NULL, payload bytea NOT NULL); INSERT INTO backup_fixture VALUES (1,'0000123456',123456789012345678.90,U&'\0939\093F\0928\094D\0926\0940',decode('00017fff','hex')),(2,'0000000042',0.01,'fixture-two',decode('255044462d312e37000aff','hex'));")
    New-ServiceConfig 'SBCOApi' (Join-Path $InstallRoot 'bin\sbco-api.exe') '' @{DATABASE_URL="postgresql://sbco:$password@127.0.0.1:55439/sbco"} @('SBCOPostgres')
    # API XML supplies protected backup credentials; no API/worker/web service is registered.
    Write-Utf8 (Join-Path $DataRoot 'configured.json') (@{ready=$true;test_only=$true;hostname='unused.test';firewall=$false} | ConvertTo-Json)
    $schedule=Join-Path $InstallRoot 'server\Set-BackupSchedule.ps1'
    $status=& $schedule -Action Enable -Time '02:00' -Retention 2
    if (-not $status.schedule.enabled -or $status.schedule.retention -ne 2) { throw 'Schedule registration did not persist.' }
    $task=Get-OwnedBackupTask
    if ($null -eq $task -or $task.State -eq 'Disabled') { throw 'Owned scheduled task was not enabled.' }
    # Exercise the same journal helpers used by MSI uninstall rollback against the real scheduler.
    foreach ($expectedEnabled in @($true, $false)) {
        if (-not $expectedEnabled) { $null=& $schedule -Action Disable }
        Remove-OwnedBackupSchedule
        if ($null -ne (Get-OwnedBackupTask)) { throw 'Removal rehearsal retained the owned task.' }
        Restore-OwnedBackupScheduleAfterRollback
        $restoredTask=Get-OwnedBackupTask
        $restoredStatus=& $schedule -Action Status
        if ($null -eq $restoredTask -or ($restoredTask.State -ne 'Disabled') -ne $expectedEnabled -or $restoredStatus.schedule.enabled -ne $expectedEnabled -or $restoredStatus.schedule.retention -ne 2 -or $restoredStatus.schedule.time -cne '02:00') { throw 'Rollback did not restore task state and schedule preferences.' }
    }
    $null=& $schedule -Action Enable -Time '02:00' -Retention 2
    function Invoke-ScheduledBackup {
        $statusFile=Join-Path $DataRoot 'backup-status.json'
        $previousFile=if(Test-Path -LiteralPath $statusFile){(Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json -AsHashtable)['file']}else{$null}
        $started=[DateTime]::Now
        Start-ScheduledTask -TaskName $BackupTaskName -TaskPath '\'
        Wait-Condition {
            $info=Get-ScheduledTaskInfo -TaskName $BackupTaskName -TaskPath '\'
            if ($info.LastRunTime -lt $started.AddSeconds(-2) -or (Get-ScheduledTask -TaskName $BackupTaskName -TaskPath '\').State -eq 'Running' -or $info.LastTaskResult -ne 0 -or -not (Test-Path -LiteralPath $statusFile)) { return $false }
            $backup=Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
            $backup.result -eq 'succeeded' -and $backup.file -cne $previousFile
        } 'actual SYSTEM scheduled backup' 120
    }
    Invoke-ScheduledBackup
    $status=& $schedule -Action Status
    if ($status.last_backup.result -ne 'succeeded' -or $status.last_backup.mode -ne 'scheduled') { throw 'Scheduled backup did not publish success status.' }
    $dump=Join-Path (Join-Path $DataRoot 'backups') $status.last_backup.file
    $hash=(Get-FileHash -LiteralPath $dump -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $status.last_backup.sha256 -or (Get-Content -LiteralPath "$dump.sha256" -Raw).Trim() -cne "$hash  $($status.last_backup.file)") { throw 'Scheduled dump checksum failed.' }
    $null=Invoke-TestPg 'createdb.exe' @('-h','127.0.0.1','-p','55439','-U','sbco','sbco_restore_test')
    $null=Invoke-TestPg 'pg_restore.exe' @('-h','127.0.0.1','-p','55439','-U','sbco','--exit-on-error','-d','sbco_restore_test',$dump)
    $query=@('-X','-h','127.0.0.1','-p','55439','-U','sbco','-At','-v','ON_ERROR_STOP=1','-c',"SELECT id,account,amount::text,encode(convert_to(note,'UTF8'),'hex'),encode(payload,'hex') FROM backup_fixture ORDER BY id")
    $live=(Invoke-TestPg 'psql.exe' ($query+@('-d','sbco'))) -join "`n"
    $restored=(Invoke-TestPg 'psql.exe' ($query+@('-d','sbco_restore_test'))) -join "`n"
    if ($live -cne "1|0000123456|123456789012345678.90|e0a4b9e0a4bfe0a4a8e0a58de0a4a6e0a580|00017fff`n2|0000000042|0.01|666978747572652d74776f|255044462d312e37000aff" -or $restored -cne $live) { throw 'Restored fixture rows differ from original database.' }
    & (Join-Path $InstallRoot 'server\Backup-Server.ps1')
    $manual=@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'backups') -Filter 'sbco-*.dump' -File)
    if ($manual.Count -ne 1) { throw 'Manual fixture backup was not created.' }
    $manualHash=(Get-FileHash -LiteralPath $manual[0].FullName -Algorithm SHA256).Hash
    Invoke-ScheduledBackup
    Invoke-ScheduledBackup
    if (@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'backups') -Filter 'auto-*.dump' -File).Count -ne 2) { throw 'Actual scheduled retention did not keep exactly two successful dumps.' }
    if ((Get-FileHash -LiteralPath $manual[0].FullName -Algorithm SHA256).Hash -cne $manualHash) { throw 'Scheduled retention changed the manual backup.' }
    $status=& $schedule -Action Status
    $dump=Join-Path (Join-Path $DataRoot 'backups') $status.last_backup.file
    $hash=(Get-FileHash -LiteralPath $dump -Algorithm SHA256).Hash.ToLowerInvariant()
    $disabled=& $schedule -Action Disable
    if ($disabled.schedule.enabled -or $disabled.task_state -ne 'Disabled') { throw 'Schedule disable did not persist.' }
    $before=@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'backups') -Filter '*.dump').Count
    & (Join-Path $InstallRoot 'server\Backup-Server.ps1') -Scheduled
    if (@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'backups') -Filter '*.dump').Count -ne $before) { throw 'Disabled queued invocation created a backup.' }
    # Enable again so uninstall proves owned-task cleanup while preserving the dump and cluster.
    $null=& $schedule -Action Enable -Time '02:00' -Retention 2
    Invoke-TestMsi '/x' $productCode 'backup-server-uninstall'
    if (Get-ScheduledTask -TaskName $BackupTaskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Uninstall retained the backup task.' }
    if (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue) { throw 'Uninstall retained a fixture service.' }
    if (-not (Test-Path -LiteralPath (Join-Path $pgData 'global\pg_control')) -or (Get-FileHash -LiteralPath $dump -Algorithm SHA256).Hash -ine $hash) { throw 'Uninstall removed or changed preserved backup/database data.' }
    @{result='passed';scope='disposable Windows backup runtime rehearsal';source_msi_sha256=$expectedHash;scheduled_dump_sha256=$hash;restored_rows=2;unicode_numeric_account_binary_roundtrip=$true;scheduled_retention=2;manual_backup_preserved=$true;scheduler_removed=$true;database_preserved=$true;enabled_and_disabled_schedule_rollback=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory 'backup-rehearsal.json')
} catch {
    $failureMessage=$_.Exception.Message
    if ($password) { $failureMessage=$failureMessage.Replace($password,'[REDACTED]') }
    $failureMessage=[regex]::Replace($failureMessage,'postgresql://[^@\s]+@','postgresql://[REDACTED]@')
    $failureMessage | Set-Content -LiteralPath (Join-Path $LogDirectory 'failure.txt')
    if ($fixtureCreated) {
        # Preserve safe scheduler/status evidence before cleanup or a diagnostic backup overwrites it.
        $diagnosticTask=$null
        try {
            $diagnosticTask=Get-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\' -ErrorAction SilentlyContinue
            $diagnosticInfo=if($diagnosticTask){Get-ScheduledTaskInfo -TaskName 'SBCO Server Daily Backup' -TaskPath '\'}else{$null}
            $statusPath=Join-Path $dataPath 'backup-status.json'
            $backupStatus=if(Test-Path -LiteralPath $statusPath){Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json|Select-Object format,mode,result,started_at,completed_at,file,sha256}else{$null}
            @{task_state=$(if($diagnosticTask){[string]$diagnosticTask.State}else{'Missing'});last_task_result=$(if($diagnosticInfo){$diagnosticInfo.LastTaskResult}else{$null});last_run=$(if($diagnosticInfo){$diagnosticInfo.LastRunTime}else{$null});action_executable=$(if($diagnosticTask){[IO.Path]::GetFileName($diagnosticTask.Actions[0].Execute)}else{$null});action_matches_expected=$(if($diagnosticTask){$diagnosticTask.Actions[0].Execute -ieq (Get-BackupTaskExecutable) -and $diagnosticTask.Actions[0].Arguments -ceq (Get-BackupTaskArguments) -and $diagnosticTask.Actions[0].WorkingDirectory -ieq $InstallRoot}else{$false});backup_script_exists=(Test-Path -LiteralPath (Join-Path $installPath 'server\Backup-Server.ps1'));backup_files=@(Get-ChildItem -LiteralPath (Join-Path $dataPath 'backups') -File | Select-Object Name,Length);backup_status=$backupStatus} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LogDirectory 'backup-task-diagnostic.json')
        } catch { Write-Warning 'Task diagnostic snapshot could not be collected.' }
        # Same installed script and Windows PowerShell version as SYSTEM; restricted to the
        # disposable fixture. Capture only sanitized text, never credentials or database files.
        if ($diagnosticTask -and $diagnosticTask.State -ne 'Running') {
            $probe=$null
            try {
                # Load the installed implementation unchanged, but expose its original inner
                # exception in this private diagnostic process instead of the generic UI error.
                $probeScript=Join-Path $dataPath 'backup-diagnostic.ps1'
                Write-Utf8 $probeScript @'
param([string]$ServerDirectory)
. (Join-Path $ServerDirectory 'Server-Common.ps1')
. (Join-Path $ServerDirectory 'Backup-Common.ps1')
Assert-Administrator
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ServerDirectory 'Backup-Common.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Installed backup diagnostic source did not parse.'}
$implementation=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ServerBackup'},$true)
$genericThrows=@($implementation.FindAll({param($node) $node -is [Management.Automation.Language.ThrowStatementAst] -and $node.Extent.Text -like "throw 'SBCO backup failed.*"},$true))
if($genericThrows.Count -ne 1){throw 'Expected generic backup exception was not found.'}
Invoke-Expression ($implementation.Extent.Text.Replace($genericThrows[0].Extent.Text,'throw'))
try { Invoke-ServerBackup $false; exit 0 }
catch {
    @{error_type=$_.Exception.GetType().FullName;error_message=$_.Exception.Message;line=$_.InvocationInfo.ScriptLineNumber} | ConvertTo-Json -Compress | Write-Output
    exit 1
}
'@
                $start=[Diagnostics.ProcessStartInfo]::new()
                $start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$probeScript+'" -ServerDirectory "'+(Join-Path $installPath 'server')+'"'
                $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
                $start.EnvironmentVariables.Remove('PSModulePath') # Let Windows PowerShell construct its own module path.
                $probe=[Diagnostics.Process]::new();$probe.StartInfo=$start;$null=$probe.Start()
                $stdout=$probe.StandardOutput.ReadToEndAsync();$stderr=$probe.StandardError.ReadToEndAsync()
                if(-not $probe.WaitForExit(30000)){$probe.Kill();throw 'Administrative diagnostic backup timed out.'}
                $text='Exit code: '+$probe.ExitCode+"`n"+$stdout.Result+"`n"+$stderr.Result
                if($password){$text=$text.Replace($password,'[REDACTED]')}
                $text=[regex]::Replace($text,'postgresql://[^@\s]+@','postgresql://[REDACTED]@')
                $text|Set-Content -LiteralPath (Join-Path $LogDirectory 'backup-powershell51-probe.txt') -Encoding utf8NoBOM
            } catch { Write-Warning 'Administrative diagnostic backup probe could not finish.' }
            finally {if($null -ne $probe){$probe.Dispose()}}
        }
        # Only this fixture's PostgreSQL text logs; never config XML, database or dump files.
        $pgLogs=Join-Path $dataPath 'logs\SBCOPostgres'
        $pgLogFiles=@()
        if(Test-Path -LiteralPath $pgLogs){$pgLogFiles+=@(Get-ChildItem -LiteralPath $pgLogs -Filter '*.log' -File)}
        $initLogs=Join-Path $dataPath 'database'
        if(Test-Path -LiteralPath $initLogs){$pgLogFiles+=@(Get-ChildItem -LiteralPath $initLogs -Filter 'initdb-*.log' -File|Where-Object {$_.Name -match '^initdb-[a-f0-9]{32}\.log$'})}
        if ($pgLogFiles.Count) {
            foreach ($file in $pgLogFiles) {
                try {
                    $text=(Get-Content -LiteralPath $file.FullName -Tail 2000) -join "`n"
                    if ($password) { $text=$text.Replace($password,'[REDACTED]') }
                    $text=[regex]::Replace($text,'postgresql://[^@\s]+@','postgresql://[REDACTED]@')
                    $text | Set-Content -LiteralPath (Join-Path $LogDirectory ('postgres-'+$file.Name)) -Encoding utf8NoBOM
                } catch { Write-Warning 'A PostgreSQL fixture diagnostic log could not be collected.' }
            }
        }
    }
    throw $failureMessage
} finally {
    $env:PGPASSWORD=$oldPassword; $password=$null
    if ($msiStarted -and -not $msiTimedOut -and $null -ne $productCode -and $installer.ProductState($productCode) -ne -1) {
        try { Invoke-TestMsi '/x' $productCode 'backup-cleanup-uninstall' } catch { Write-Warning 'Test installer cleanup failed; retain the disposable runner logs.' }
    }
    # Never collect credential XML, the fixture database or dump contents in artifacts.
    # Remove test data only after all owned services/task are gone and its unique marker agrees.
    if ($fixtureCreated -and -not (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue) -and -not (Get-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\' -ErrorAction SilentlyContinue)) {
        $markerPath=Join-Path $dataPath 'ownership.json'
        if (Test-Path -LiteralPath $markerPath) {
            $marker=Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.test_only -eq $true -and $marker.test_token -ceq $fixtureToken) { Remove-Item -LiteralPath $dataPath -Recurse -Force }
        }
    }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
}
