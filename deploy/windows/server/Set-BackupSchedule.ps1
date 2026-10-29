#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable', 'Status')][string]$Action = 'Status',
    [ValidatePattern('^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')][string]$Time = '02:00',
    [ValidateRange(1,365)][int]$Retention = 14
)
. (Join-Path $PSScriptRoot 'Server-Common.ps1')
. (Join-Path $PSScriptRoot 'Backup-Common.ps1')
Assert-Administrator
$lock = New-Object Threading.Mutex($false, 'Global\SBCOServerSetup')
$acquired = $false
try {
    try { $acquired = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Server maintenance or a backup is running. Retry after it finishes.' }
    $null = Assert-BackupInstallation
    $task = Get-OwnedBackupTask
    $settings = Read-BackupSchedule
    if ($Action -eq 'Enable') {
        $trigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]::Today.Add([TimeSpan]::ParseExact($Time, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)))
        $taskAction = New-ScheduledTaskAction -Execute (Get-BackupTaskExecutable) -Argument (Get-BackupTaskArguments) -WorkingDirectory $InstallRoot
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $policy = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Hours 6) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $definition = New-ScheduledTask -Action $taskAction -Trigger $trigger -Principal $principal -Settings $policy -Description "Managed by SBCO Server backup format 1 at $InstallRoot"
        # Register disabled first; only enable after protected configuration is complete.
        $definition.Settings.Enabled = $false
        Register-ScheduledTask -TaskName $BackupTaskName -TaskPath '\' -InputObject $definition -Force | Out-Null
        $settings = @{format=1; install_root=$InstallRoot; enabled=$true; time=$Time; retention=$Retention}
        Write-BackupJson (Join-Path $DataRoot 'backup-schedule.json') $settings
        Enable-ScheduledTask -TaskName $BackupTaskName -TaskPath '\' | Out-Null
        Write-Host "Daily backups enabled at $Time (this computer's local time), keeping $Retention successful scheduled backups."
    } elseif ($Action -eq 'Disable') {
        if ($task) { Disable-ScheduledTask -TaskName $BackupTaskName -TaskPath '\' | Out-Null }
        if ($settings) { $settings.enabled = $false; Write-BackupJson (Join-Path $DataRoot 'backup-schedule.json') $settings }
        Write-Host 'Scheduled backups disabled. Existing backups and database records are preserved.'
    }
    $task = Get-OwnedBackupTask
    $info = if ($task) { Get-ScheduledTaskInfo -TaskName $BackupTaskName -TaskPath '\' } else { $null }
    $lastBackup = if (Test-Path -LiteralPath (Join-Path $DataRoot 'backup-status.json')) { Get-Content -LiteralPath (Join-Path $DataRoot 'backup-status.json') -Raw | ConvertFrom-Json } else { $null }
    [pscustomobject]@{schedule=$settings; task_state=$(if($task){[string]$task.State}else{'Not installed'}); next_run=$(if($info){$info.NextRunTime}else{$null}); last_task_result=$(if($info){$info.LastTaskResult}else{$null}); last_backup=$lastBackup}
} finally {
    if ($acquired) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
