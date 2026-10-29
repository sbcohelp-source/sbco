# Shared by guided setup and installer service maintenance. Windows PowerShell 5.1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InstallRoot = Split-Path -Parent $PSScriptRoot
$script:DataRoot = Join-Path $env:ProgramData 'SBCO Server'
$script:ServiceNames = @('SBCOPostgres', 'SBCOApi', 'SBCOWorker', 'SBCOWeb', 'SBCOHttps')
function Assert-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this operation as a Windows administrator.' }
}
function Write-Utf8([string]$Path, [string]$Value) {
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}
function Set-PrivateDirectory([string]$Path, [string[]]$ServiceSids = @(), [string]$Access = 'ReadAndExecute') {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse-point data directory: $Path" }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    foreach ($sid in $ServiceSids) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), $Access, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-ServiceSid([string]$Name) {
    (New-Object Security.Principal.NTAccount("NT SERVICE\$Name")).Translate([Security.Principal.SecurityIdentifier]).Value
}
function Grant-Traverse([string]$Path, [string]$Sid) {
    $acl = Get-Acl -LiteralPath $Path
    $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($Sid)), 'ReadAndExecute', 'None', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-Wrapper([string]$Name) { Join-Path $DataRoot "services\$Name\$Name.exe" }
function Invoke-Wrapper([string]$Name, [string]$Operation) {
    & (Get-Wrapper $Name) $Operation | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Service $Operation failed for $Name. Check the protected service logs." }
}
function Wait-Condition([scriptblock]$Condition, [string]$Description, [int]$Seconds = 90) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Description"
}
function Wait-Http([string]$Url) {
    Wait-Condition { try { (Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5).StatusCode -eq 200 } catch { $false } } "HTTP health at $Url"
}
function Read-OwnedInstallation {
    $marker = Join-Path $DataRoot 'ownership.json'
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    $owned = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($owned.install_root -ne $InstallRoot -or $owned.format -ne 1) { throw 'Existing server belongs to another installation path/version. Preserve it and perform a reviewed migration.' }
    return $owned
}
function Assert-OwnedService([string]$Name) {
    $service = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if ($service -and $service.PathName.Trim('"') -ne (Get-Wrapper $Name)) { throw "Refusing to manage another installation's service: $Name" }
}
function Stop-ServerServices {
    if (-not (Read-OwnedInstallation)) { return }
    foreach ($name in @('SBCOHttps', 'SBCOWeb', 'SBCOWorker', 'SBCOApi', 'SBCOPostgres')) {
        Assert-OwnedService $name
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            if ((Get-Service $name).Status -ne 'Stopped') { Invoke-Wrapper $name 'stop' }
            Wait-Condition { (Get-Service $name).Status -eq 'Stopped' } "stop $name"
        }
    }
}
function Set-OwnedFirewall([bool]$Enabled) {
    $rule = Get-NetFirewallRule -Name 'SBCO-HTTPS-443' -ErrorAction SilentlyContinue
    $description = "Managed by SBCO Server at $InstallRoot"
    if ($rule -and $rule.Description -ne $description) { throw 'The reserved firewall rule belongs to another configuration; it was not changed.' }
    if ($Enabled -and -not $rule) {
        New-NetFirewallRule -Name 'SBCO-HTTPS-443' -DisplayName 'SBCO HTTPS' -Description $description -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443 -Profile Domain,Private | Out-Null
    } elseif (-not $Enabled -and $rule) { $rule | Remove-NetFirewallRule }
}
function Remove-ServerServices {
    if (-not (Read-OwnedInstallation)) { return }
    . (Join-Path $PSScriptRoot 'Backup-Common.ps1')
    Remove-OwnedBackupSchedule
    Stop-ServerServices
    foreach ($name in @('SBCOHttps', 'SBCOWeb', 'SBCOWorker', 'SBCOApi', 'SBCOPostgres')) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            Invoke-Wrapper $name 'uninstall'
            Wait-Condition { -not (Get-Service -Name $name -ErrorAction SilentlyContinue) } "remove $name"
        }
    }
    Set-OwnedFirewall $false
    Write-Host "Services removed. All database, settings, certificates and backup files remain in $DataRoot."
}
function Resume-ServerServices([switch]$Rollback) {
    if (-not (Read-OwnedInstallation)) { return }
    . (Join-Path $PSScriptRoot 'Backup-Common.ps1')
    # Only MSI rollback restores removed task state. Ordinary reinstall clears the
    # previous transaction's journal before anything can fail, without enabling it.
    if ($Rollback) { Restore-OwnedBackupScheduleAfterRollback }
    else { Clear-BackupScheduleRemovalJournal }
    $readyPath = Join-Path $DataRoot 'configured.json'
    if (-not (Test-Path -LiteralPath $readyPath)) { throw 'Setup is incomplete. No existing database or configuration was overwritten.' }
    $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    foreach ($name in $ServiceNames) {
        Assert-OwnedService $name
        $registered = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $registered -or $registered.Status -eq 'Stopped') {
            # Service wrappers are generated binaries, not operator configuration.
            Copy-Item -LiteralPath (Join-Path $InstallRoot 'tools\winsw.exe') -Destination (Get-Wrapper $name) -Force
        }
        if (-not $registered) {
            Invoke-Wrapper $name 'install'
            & sc.exe sidtype $name unrestricted | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not restore service identity: $name" }
        }
        if ((Get-Service $name).Status -ne 'Running') { Invoke-Wrapper $name 'start' }
        Wait-Condition { (Get-Service $name).Status -eq 'Running' } "start $name"
        if ($name -eq 'SBCOApi') { Wait-Http 'http://127.0.0.1:8091/health' }
        if ($name -eq 'SBCOWeb') { Wait-Http 'http://127.0.0.1:3091/' }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Wait-Http "https://$($ready.hostname)/api/v1/server-info"
    if ($ready.firewall) { Set-OwnedFirewall $true }
    $ready | Add-Member -NotePropertyName ready -NotePropertyValue $true -Force
    Write-Utf8 $readyPath ($ready | ConvertTo-Json)
    $backupSettings = Read-BackupSchedule
    if ($backupSettings -and $backupSettings.enabled -and -not (Get-OwnedBackupTask)) {
        Write-Warning 'Daily backups are not scheduled. Run server\Set-BackupSchedule.ps1 -Action Enable with your preferred time and retention to enable them again.'
    }
    Write-Host "Server ready at https://$($ready.hostname). Existing data and configuration were preserved."
}
