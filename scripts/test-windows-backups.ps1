#requires -Version 7.2
# Portable tests: real temporary files/status/retention; simulated Windows task/ACL/native tools.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('sbco-backup-test-' + [guid]::NewGuid().ToString('N'))
$envBefore = @{ProgramData=$env:ProgramData; SystemRoot=$env:SystemRoot; PGDATABASE=$env:PGDATABASE}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Operation, [string]$Message) {
    $refused=$false; try { & $Operation | Out-Null } catch { $refused=$true }
    Assert $refused $Message
}
try {
    $server = Join-Path $root 'install/server'; $null=New-Item -ItemType Directory -Path $server -Force
    $env:ProgramData=Join-Path $root 'data'; $env:SystemRoot=Join-Path $root 'windows'
    foreach($name in @('Server-Common.ps1','Backup-Common.ps1','Backup-Server.ps1','Set-BackupSchedule.ps1')) {
        $source=Join-Path $PSScriptRoot "../deploy/windows/server/$name"
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) "Parse error in $name"
        Copy-Item -LiteralPath $source -Destination $server
    }
    Add-Content -LiteralPath (Join-Path $server 'Server-Common.ps1') -Value @'
function Assert-Administrator {}
function Set-PrivateDirectory([string]$Path) { [IO.Directory]::CreateDirectory($Path) | Out-Null }
'@
    . (Join-Path $server 'Server-Common.ps1')
    . (Join-Path $server 'Backup-Common.ps1')
    Set-PrivateDirectory $DataRoot; Set-PrivateDirectory (Join-Path $DataRoot 'services/SBCOApi')
    $owned=@{format=1; install_root=$InstallRoot; created_at='2026-10-29T00:00:00Z'}
    Write-BackupJson (Join-Path $DataRoot 'ownership.json') $owned
    Write-BackupJson (Join-Path $DataRoot 'configured.json') @{ready=$true}
    Write-Utf8 (Join-Path $DataRoot 'services/SBCOApi/SBCOApi.xml') '<service><env name="DATABASE_URL" value="postgresql://sbco:test-only@127.0.0.1:55439/sbco" /></service>'
    $settings=@{format=1; install_root=$InstallRoot; enabled=$true; time='02:00'; retention=2}
    Write-BackupJson (Join-Path $DataRoot 'backup-schedule.json') $settings
    $script:archiveFails=$false
    function Invoke-BackupArchive([string]$Partial) {
        [IO.File]::WriteAllText($Partial, 'PGDMP portable fixture ' + [guid]::NewGuid())
        if($script:archiveFails){throw 'fixture failure with sensitive detail that must not persist'}
    }
    $folder=Join-Path $DataRoot 'backups'; Set-PrivateDirectory $folder
    function New-ArchiveFixture([string]$Name,[string]$Instance,[bool]$Corrupt=$false) {
        $path=Join-Path $folder $Name; Write-Utf8 $path "archive-$Name"
        $hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        if($Corrupt){$hash='bad'}
        Write-Utf8 "$path.sha256" ($hash+'  '+$Name)
        Write-BackupJson "$path.backup.json" @{format=1;mode='scheduled';install_root=$InstallRoot;install_created_at=$Instance;file=$Name;sha256=$hash}
        return $path
    }
    foreach($day in 1..4){$null=New-ArchiveFixture ('auto-2026010'+$day+'-020000-'+('a'*31)+$day+'.dump') $owned.created_at}
    $foreign=Join-Path $folder ('auto-20200101-000000-'+('b'*32)+'.dump'); Write-Utf8 $foreign 'untracked real data'
    $corrupt=New-ArchiveFixture ('auto-20200102-000000-'+('c'*32)+'.dump') $owned.created_at $true
    $otherInstall=New-ArchiveFixture ('auto-20200103-000000-'+('d'*32)+'.dump') 'other-instance'
    $env:PGDATABASE='previous-environment'; $script:archiveFails=$true
    Refuses {Invoke-ServerBackup $true} 'Failed archive must fail operation'
    Assert (@(Get-ChildItem -LiteralPath $folder -Filter '*.dump').Count -eq 7) 'Failure pruned backups'
    Assert (@(Get-ChildItem -LiteralPath $folder -Filter '*.partial').Count -eq 0) 'Failure left partial file'
    $status=Get-Content (Join-Path $DataRoot 'backup-status.json') -Raw
    Assert ($status -match 'failed' -and $status -notmatch 'sensitive|test-only') 'Failure status leaked details or missed failure'
    Assert ($env:PGDATABASE -ceq 'previous-environment') 'Database environment not restored after failure'
    $script:archiveFails=$false; Invoke-ServerBackup $false
    $manual=@(Get-ChildItem -LiteralPath $folder -Filter 'sbco-*.dump')
    Assert ($manual.Count -eq 1) 'Manual backup missing'
    Assert (@(Get-ChildItem -LiteralPath $folder -Filter 'auto-*.dump').Count -eq 7) 'Manual backup pruned scheduled files'
    Invoke-ServerBackup $true
    Assert (@(Get-ChildItem -LiteralPath $folder -Filter 'auto-*.dump').Count -eq 5) 'Retention did not keep two owned successes and three unknown files'
    foreach($path in @($foreign,$corrupt,$otherInstall,$manual[0].FullName)){Assert (Test-Path -LiteralPath $path) 'Retention deleted unowned/corrupt/manual archive'}
    $status=Get-Content (Join-Path $DataRoot 'backup-status.json') -Raw | ConvertFrom-Json
    Assert ($status.result -eq 'succeeded' -and (Test-Path (Join-Path $folder $status.file))) 'Success status missing archive'
    Assert ($env:PGDATABASE -ceq 'previous-environment') 'Database environment not restored after success'
    $settings.enabled=$false; Write-BackupJson (Join-Path $DataRoot 'backup-schedule.json') $settings
    $before=@(Get-ChildItem -LiteralPath $folder).Count; Invoke-ServerBackup $true
    Assert (@(Get-ChildItem -LiteralPath $folder).Count -eq $before) 'Disabled queued invocation wrote backup'
    $settings.retention=0; Write-BackupJson (Join-Path $DataRoot 'backup-schedule.json') $settings
    Refuses {Invoke-ServerBackup $true} 'Invalid retention accepted'
    $settings.retention=2; Write-BackupJson (Join-Path $DataRoot 'backup-schedule.json') $settings
    $owned.install_root='another-install'; Write-BackupJson (Join-Path $DataRoot 'ownership.json') $owned
    Refuses {Invoke-ServerBackup $false} 'Foreign installation accepted'
    $owned.install_root=$InstallRoot; Write-BackupJson (Join-Path $DataRoot 'ownership.json') $owned
    if(-not $IsWindows) {
        $link=Join-Path $DataRoot 'linked-backups'; New-Item -ItemType SymbolicLink -Path $link -Target $folder | Out-Null
        Refuses {Assert-BackupPath (Join-Path $link 'archive.dump')} 'Symlink ancestor accepted'
    }
    # Same-second names deliberately reverse GUID ordering versus actual write time.
    $originalFolder=$folder
    $folder=Join-Path $DataRoot 'same-second-fixtures'; Set-PrivateDirectory $folder
    $older=New-ArchiveFixture ('auto-20260101-020000-'+('f'*32)+'.dump') $owned.created_at
    $newer=New-ArchiveFixture ('auto-20260101-020000-'+('0'*32)+'.dump') $owned.created_at
    [IO.File]::SetLastWriteTimeUtc($older, [datetime]'2026-01-01T02:00:00.100Z')
    [IO.File]::SetLastWriteTimeUtc($newer, [datetime]'2026-01-01T02:00:00.900Z')
    Remove-ExpiredScheduledBackups $folder 1 (Read-OwnedInstallation)
    Assert ((Test-Path -LiteralPath $newer) -and -not (Test-Path -LiteralPath $older)) 'Same-second GUID sorting pruned the newest backup'
    Assert ((Test-Path -LiteralPath ($newer+'.sha256')) -and (Test-Path -LiteralPath ($newer+'.backup.json'))) 'Newest backup metadata was pruned'
    $folder=$originalFolder
    Write-Host 'PASS same-second backups retain newest write time despite reverse GUID ordering.'
    Write-Host 'PASS backup failure/status, atomic publication, retention/provenance, manual preservation, disabled queue, environment and link safeguards.'

    $global:sbcoTestTask=$null
    function Get-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction); $global:sbcoTestTask }
    function New-ScheduledTaskTrigger { param([switch]$Daily,$At); [pscustomobject]@{At=$At} }
    function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory); [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory} }
    function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
    function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable,$MultipleInstances,$RestartCount,$RestartInterval,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries); [pscustomobject]@{Enabled=$true;MultipleInstances=$MultipleInstances;RestartCount=$RestartCount;StartWhenAvailable=[bool]$StartWhenAvailable} }
    function New-ScheduledTask { param($Action,$Trigger,$Principal,$Settings,$Description); [pscustomobject]@{Actions=@($Action);Triggers=@($Trigger);Principal=$Principal;Settings=$Settings;Description=$Description;State='Disabled'} }
    function Register-ScheduledTask { param($TaskName,$TaskPath,$InputObject,[switch]$Force); $global:sbcoTestTask=$InputObject }
    function Enable-ScheduledTask { param($TaskName,$TaskPath); $global:sbcoTestTask.State='Ready' }
    function Disable-ScheduledTask { param($TaskName,$TaskPath); $global:sbcoTestTask.State='Disabled' }
    function Unregister-ScheduledTask { param($TaskName,$TaskPath,$Confirm); $global:sbcoTestTask=$null }
    function Get-ScheduledTaskInfo { param($TaskName,$TaskPath); [pscustomobject]@{NextRunTime=[datetime]::Today.AddDays(1);LastTaskResult=0} }
    $control=Join-Path $server 'Set-BackupSchedule.ps1'
    & $control -Action Enable -Time '03:15' -Retention 5 | Out-Null
    Assert ($global:sbcoTestTask.State -eq 'Ready') 'Task not enabled'
    Assert ($global:sbcoTestTask.Settings.MultipleInstances -eq 'IgnoreNew' -and $global:sbcoTestTask.Settings.StartWhenAvailable -and $global:sbcoTestTask.Settings.RestartCount -eq 3) 'Missed-run/retry/overlap policy missing'
    Assert ($global:sbcoTestTask.Triggers[0].At.Hour -eq 3 -and $global:sbcoTestTask.Triggers[0].At.Minute -eq 15) 'Daily time ignored'
    Assert ($global:sbcoTestTask.Actions[0].Arguments -notmatch 'test-only|postgresql:') 'Task arguments contain secret'
    $settings=Read-BackupSchedule
    Assert ($settings.enabled -and $settings.retention -eq 5 -and $settings.time -eq '03:15') 'Schedule preferences not saved'
    Refuses { & $control -Action Enable -Time '24:00' } 'Invalid schedule time accepted'
    $global:sbcoTestTask.Description='Unrelated administrator task'
    Refuses { & $control -Action Enable } 'Foreign task overwritten'
    Refuses { & $control -Action Disable } 'Foreign task disabled'
    Refuses { Remove-OwnedBackupSchedule } 'Foreign task unregistered'
    $global:sbcoTestTask.Description="Managed by SBCO Server backup format 1 at $InstallRoot"
    $originalArguments=$global:sbcoTestTask.Actions[0].Arguments; $global:sbcoTestTask.Actions[0].Arguments='different command'
    Refuses {Remove-OwnedBackupSchedule} 'Matching description with foreign command accepted'
    $global:sbcoTestTask.Actions[0].Arguments=$originalArguments
    & $control -Action Disable | Out-Null
    Assert ($global:sbcoTestTask.State -eq 'Disabled' -and -not (Read-BackupSchedule).enabled) 'Disable state not saved'
    Remove-OwnedBackupSchedule
    Assert ($null -eq $global:sbcoTestTask) 'Owned task remained after removal'
    Assert (@(Get-ChildItem -LiteralPath $folder).Count -eq $before) 'Schedule operation modified backups'
    Write-Host 'PASS schedule time/retention, SYSTEM action without secrets, retry/catch-up, foreign-task refusal, disable and uninstall preserve archives.'
} finally {
    foreach($key in $envBefore.Keys){[Environment]::SetEnvironmentVariable($key,$envBefore[$key])}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    Remove-Variable -Name sbcoTestTask -Scope Global -ErrorAction SilentlyContinue
}
