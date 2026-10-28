#requires -Version 5.1
param([Parameter(Mandatory = $true)][ValidateSet('Stop', 'Remove', 'Resume')][string]$Action)
. (Join-Path $PSScriptRoot 'Server-Common.ps1')
Assert-Administrator
switch ($Action) {
    'Stop' { Stop-ServerServices }
    'Remove' { Remove-ServerServices }
    'Resume' { Resume-ServerServices }
}
