#requires -Version 5.1
# Logical backup; never stops services or modifies database records.
param([switch]$Scheduled)
. (Join-Path $PSScriptRoot 'Server-Common.ps1')
. (Join-Path $PSScriptRoot 'Backup-Common.ps1')
Assert-Administrator
$lock = New-Object Threading.Mutex($false, 'Global\SBCOServerSetup')
$acquired = $false
try {
    try { $acquired = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Server maintenance or another backup is running. Retry after it finishes.' }
    Invoke-ServerBackup ([bool]$Scheduled)
} finally {
    if ($acquired) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
