#requires -Version 5.1
param([Parameter(Mandatory = $true)][ValidateSet('Stop', 'Remove', 'Resume', 'RollbackResume')][string]$Action)
. (Join-Path $PSScriptRoot 'Server-Common.ps1')
Assert-Administrator
$maintenanceLock = New-Object Threading.Mutex($false, 'Global\SBCOServerSetup')
$acquired = $false
try {
    try { $acquired = $maintenanceLock.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'A server backup or setup is running. Wait for it to finish before changing the installation.' }
    switch ($Action) {
        'Stop' { Stop-ServerServices }
        'Remove' { Remove-ServerServices }
        'Resume' { Resume-ServerServices }
        'RollbackResume' { Resume-ServerServices -Rollback }
    }
} finally {
    if ($acquired) { $maintenanceLock.ReleaseMutex() }
    $maintenanceLock.Dispose()
}
