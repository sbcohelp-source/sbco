#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$ConfigurationPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InstallRoot = Split-Path -Parent $PSScriptRoot
$script:DataRoot = Join-Path $env:ProgramData 'SBCO Server'

function Assert-InitializationPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Initialization paths must not contain links or junctions.' }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Invoke-PackagedInitdb([string]$Executable, [string[]]$Arguments, [string]$LogPath) {
    # Windows PowerShell can turn native stderr into an error record even on exit 0.
    # Judge completion by its exit code and retain diagnostics only in the protected directory.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    & $Executable @Arguments > $LogPath 2>&1
    if ($null -eq $global:LASTEXITCODE) { throw 'Initialization process did not start.' }
    return [int]$global:LASTEXITCODE
}
function Invoke-PostgresInitialization([string]$Path) {
    $databaseRoot = Join-Path $DataRoot 'database'
    $cluster = Join-Path $databaseRoot 'cluster'
    $configuration = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($configuration) -ine [IO.Path]::GetFullPath($databaseRoot)) { throw 'Initialization configuration is outside this server.' }
    # Elevated setup validates ownership; this restricted service has only root traversal
    # and access to its private database directory, not the administrator-only marker.
    foreach ($candidate in @($configuration, $cluster)) { Assert-InitializationPath $candidate }
    $config = Get-Content -LiteralPath $configuration -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.format -ne 1 -or $config.nonce -cnotmatch '^[a-f0-9]{32}$' -or $config.arguments -isnot [array]) { throw 'Invalid initialization configuration.' }
    $executable = Join-Path $InstallRoot 'postgres\bin\initdb.exe'
    $resultPath = Join-Path $databaseRoot ('init-result-' + $config.nonce + '.json')
    if ($config.executable -ine $executable -or $config.result_path -ine $resultPath) { throw 'Initialization executable or result path does not match this installation.' }
    $logPath = Join-Path $databaseRoot ('initdb-' + $config.nonce + '.log')
    $passwordFile = Join-Path $databaseRoot 'init-password'
    foreach ($candidate in @($executable, $resultPath, $logPath, $passwordFile, (Join-Path $InstallRoot 'postgres\share'))) { Assert-InitializationPath $candidate }
    if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) { throw 'Private initialization password file is missing.' }
    if ((Test-Path -LiteralPath $resultPath) -or (Test-Path -LiteralPath $logPath) -or (Test-Path -LiteralPath (Join-Path $cluster 'PG_VERSION')) -or (Test-Path -LiteralPath (Join-Path $cluster 'global\pg_control'))) { throw 'Existing result or initialized database was preserved.' }
    # Accept only the setup arguments: never allow another cluster, inline secret or executable.
    $expectedPairs = @{'-D'=$cluster; '-L'=(Join-Path $InstallRoot 'postgres\share'); '-U'='sbco'}
    $expectedFlags = @('--auth=scram-sha-256','--encoding=UTF8','--locale-provider=builtin','--builtin-locale=C.UTF-8',('--pwfile='+$passwordFile))
    $seen = @{}
    $arguments = @($config.arguments)
    for ($index=0; $index -lt $arguments.Count; $index++) {
        $argument = $arguments[$index]
        if ($argument -isnot [string] -or $seen.ContainsKey($argument)) { throw 'Invalid or repeated initialization argument.' }
        $seen[$argument]=$true
        if ($expectedPairs.ContainsKey($argument)) {
            $index++
            if ($index -ge $arguments.Count -or $arguments[$index] -isnot [string] -or $arguments[$index] -ine $expectedPairs[$argument]) { throw 'Initialization argument points outside this server.' }
        } elseif ($expectedFlags -inotcontains $argument) { throw 'Unsupported initialization argument.' }
    }
    foreach ($required in @($expectedPairs.Keys) + $expectedFlags) { if (-not $seen.ContainsKey($required)) { throw 'Required initialization argument is missing.' } }
    $exitCode = 1
    try { $exitCode = Invoke-PackagedInitdb $executable $arguments $logPath } catch { $exitCode = 1 }
    $temporary = $resultPath + '.partial-' + [guid]::NewGuid().ToString('N')
    try {
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((@{format=1; nonce=$config.nonce; exit_code=[int]$exitCode} | ConvertTo-Json -Compress))
            $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $resultPath) # Never replace an earlier result.
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

# WinSW 2 cannot self-stop a short-lived LocalService process without SCM access.
# Publish the outcome and stay alive; the elevated setup operator stops this service.
# Invalid config or publication failure yields no marker, so setup times out safely.
try { Invoke-PostgresInitialization $ConfigurationPath } catch { }
while ($true) { Start-Sleep -Seconds 60 }
