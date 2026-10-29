#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ArtifactDirectory,
    [Parameter(Mandatory=$true)][string]$LogDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $env:RUNNER_TEMP) {
    throw 'Standalone installer smoke is restricted to an ephemeral GitHub-hosted Windows x64 runner.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The runner must be elevated.' }
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
$LogDirectory = [IO.Path]::GetFullPath($LogDirectory)
[IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
$installer = New-Object -ComObject WindowsInstaller.Installer
$productCode = $null
$installAttempted = $false
$timedOut = $false
$markerValue = 'EPHEMERAL STANDALONE PACKAGING FIXTURE ' + [guid]::NewGuid().ToString('N')
$markers = [Collections.Generic.List[string]]::new()
$createdDirectories = [Collections.Generic.List[string]]::new()
function Get-VerifiedMsi([string]$Directory) {
    $allFiles = @(Get-ChildItem -LiteralPath $Directory -Filter '*.msi' -File)
    # Older builds could upload a cached connected-client MSI alongside the standalone.
    # Never open/install that package: select the exact standalone filename family,
    # then independently validate its internal ProductName/UpgradeCode before use.
    $files = @($allFiles | Where-Object { $_.Name -cmatch '^SBCO_[0-9][^\\/]*_x64_en-US\.msi$' })
    if ($files.Count -ne 1) { throw 'Expected exactly one standalone MSI.' }
    $file = $files[0]
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'MSI links are prohibited.' }
    $checksum = (Get-Content -LiteralPath ($file.FullName + '.sha256') -Raw -Encoding UTF8).Trim()
    if ($checksum -notmatch '^([a-fA-F0-9]{64})  (.+)$' -or $Matches[2] -cne $file.Name) { throw 'Invalid standalone checksum manifest.' }
    $expected = $Matches[1]
    if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $expected) { throw 'Standalone checksum mismatch; MSI must not be opened or installed.' }
    return [pscustomobject]@{path=$file.FullName;sha256=$expected;excluded_msi_files=@($allFiles | Where-Object { $_.FullName -cne $file.FullName } | ForEach-Object { $_.Name })}
}
function Assert-StandaloneIdentity([hashtable]$Properties, [string]$Template) {
    if ($Properties.ProductName -cne 'SBCO' -or $Properties.Manufacturer -cne 'S K Singh' -or ([guid]$Properties.UpgradeCode) -ne ([guid]'b8dc76d1-374a-4f76-95e8-db387b715bcf')) { throw 'Unexpected standalone MSI identity.' }
    if ([guid]$Properties.ProductCode -eq [guid]::Empty -or $Template -notmatch '^x64;') { throw 'Expected standalone x64 MSI with a nonempty product identity.' }
}
function Assert-FixtureRetention {
    foreach ($marker in $markers) {
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or [IO.File]::ReadAllText($marker) -cne $markerValue) { throw 'Installer changed or removed a standalone data/backup fixture.' }
    }
}
function Remove-OwnedFixtures {
    # Delete only exact token-bearing files we created; never recursively remove app data.
    foreach ($marker in $markers) {
        if ((Test-Path -LiteralPath $marker -PathType Leaf) -and -not ((Get-Item -LiteralPath $marker -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and [IO.File]::ReadAllText($marker) -ceq $markerValue) { Remove-Item -LiteralPath $marker }
    }
    foreach ($directory in ($createdDirectories | Sort-Object Length -Descending)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and -not ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { Remove-Item -LiteralPath $directory }
    }
}
function Assert-NoAppStarted {
    if (Get-Process -Name 'sbco-desktop','sbco-client' -ErrorAction SilentlyContinue) { throw 'Installer unexpectedly launched an SBCO application.' }
    if (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue) { throw 'Standalone installer unexpectedly created an SBCO service.' }
}
function Read-MsiRows($Database, [string]$Sql, [int]$Columns) {
    $view = $Database.OpenView($Sql)
    try {
        $null = $view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            try {
                $values = @(); for ($index = 1; $index -le $Columns; $index++) { $values += $record.StringData($index) }
                Write-Output -NoEnumerate $values
            } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) | Out-Null }
        }
    } finally { $null = $view.Close(); [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null }
}
function Invoke-Msi([string]$Operation, [string]$Target, [string]$Label) {
    $log = Join-Path $LogDirectory "$Label.log"
    $arguments = "$Operation `"$Target`" /qn /norestart REBOOT=ReallySuppress /L*v `"$log`""
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList $arguments -PassThru
    try {
        if (-not $process.WaitForExit(300000)) {
            $script:timedOut = $true
            $process.Kill()
            throw "MSI $Label exceeded five minutes; stop further MSI operations and retain the disposable runner logs."
        }
        if ($process.ExitCode -notin @(0, 3010)) { throw "MSI $Label failed with exit code $($process.ExitCode). See $log" }
        Add-Content -LiteralPath (Join-Path $LogDirectory 'operations.txt') -Value "$Label exit=$($process.ExitCode)"
    } finally { $process.Dispose() }
}
try {
    # Refuse all known editions and user-data locations before any installation or fixture.
    foreach ($path in @((Join-Path $env:ProgramData 'SBCO Server'), (Join-Path $env:ProgramFiles 'SBCO'), (Join-Path $env:ProgramFiles 'SBCO Server'), (Join-Path $env:ProgramFiles 'SBCO Client'), (Join-Path $env:LOCALAPPDATA 'SBCO'), (Join-Path $env:LOCALAPPDATA 'in.sbco.client'), (Join-Path $env:APPDATA 'in.sbco.client'), (Join-Path $env:APPDATA 'in.sbco.vouchercheck'), (Join-Path $env:LOCALAPPDATA 'in.sbco.vouchercheck'))) {
        if (Test-Path -LiteralPath $path) { throw "Existing SBCO data or installation found; refusing smoke: $path" }
    }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path $root) { foreach ($entry in Get-ChildItem $root) { if ($entry.GetValue('DisplayName',$null) -like 'SBCO*') { throw 'An existing SBCO product is registered.' } } }
    }
    Assert-NoAppStarted
    $verified = Get-VerifiedMsi $ArtifactDirectory
    $database = $installer.OpenDatabase($verified.path,0)
    try {
        $properties = @{}
        foreach ($row in Read-MsiRows $database 'SELECT `Property`, `Value` FROM `Property`' 2) { $properties[$row[0]]=$row[1] }
        $summary=$database.SummaryInformation(0)
        try { $template=$summary.Property(7) } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary)|Out-Null }
        Assert-StandaloneIdentity $properties $template
        $productCode=$properties.ProductCode
        if ($installer.ProductState($productCode) -ne -1) { throw 'Standalone product is already registered.' }
        $files=@(Read-MsiRows $database 'SELECT `File`, `Component_`, `FileName` FROM `File`' 3)
        $names=@($files | ForEach-Object { $_[2].Split('|')[-1] })
        foreach ($required in @('sbco-desktop.exe','postgres.exe','initdb.exe','pg_ctl.exe','pg_dump.exe','pg_restore.exe')) {
            if ($names -notcontains $required) { throw "Standalone MSI payload missing $required" }
        }
        $main=@($files | Where-Object { $_[2].Split('|')[-1] -ceq 'sbco-desktop.exe' })
        if ($main.Count -ne 1) { throw 'Expected exactly one standalone application executable.' }
        $components=@(Read-MsiRows $database 'SELECT `Component`, `ComponentId`, `KeyPath` FROM `Component`' 3 | Where-Object { $_[0] -ceq $main[0][1] -and $_[2] -ceq $main[0][0] })
        if ($components.Count -ne 1 -or [guid]$components[0][1] -eq [guid]::Empty) { throw 'Cannot identify the installed application component.' }
        $mainComponent=$components[0][1]
        @{product_name=$properties.ProductName;product_code=$productCode;upgrade_code=$properties.UpgradeCode;version=$properties.ProductVersion;template=$template;sha256=$verified.sha256;file_count=$files.Count;excluded_msi_files=$verified.excluded_msi_files} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory 'verified-msi-identity.json')
    } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)|Out-Null }
    $installAttempted=$true
    Invoke-Msi '/i' $verified.path 'standalone-install'
    if ($installer.ProductState($productCode) -ne 5) { throw 'Standalone MSI is not registered as installed.' }
    $installedExe=$installer.ComponentPath($productCode,$mainComponent)
    if (-not $installedExe -or -not (Test-Path -LiteralPath $installedExe -PathType Leaf)) { throw 'Installed standalone executable is missing.' }
    Assert-NoAppStarted
    # Real app data root and backup location, containing only clearly labelled synthetic files.
    foreach ($parent in @($env:APPDATA,$env:LOCALAPPDATA)) {
        $root=Join-Path $parent 'in.sbco.vouchercheck'
        if (Test-Path -LiteralPath $root) { throw 'MSI unexpectedly created application data without launching the app.' }
        foreach ($relative in @('','postgres','backups')) {
            $directory=if ($relative) { Join-Path $root $relative } else { $root }
            [IO.Directory]::CreateDirectory($directory)|Out-Null
            $createdDirectories.Add($directory)
            $marker=Join-Path $directory 'installer-smoke-test-only.txt'
            [IO.File]::WriteAllText($marker,$markerValue)
            $markers.Add($marker)
        }
    }
    Invoke-Msi '/fa' $verified.path 'standalone-repair'
    if ($installer.ProductState($productCode) -ne 5 -or -not (Test-Path -LiteralPath $installedExe -PathType Leaf)) { throw 'Repair lost the application installation.' }
    Assert-FixtureRetention
    Assert-NoAppStarted
    Invoke-Msi '/x' $productCode 'standalone-uninstall'
    if ($installer.ProductState($productCode) -ne -1) { throw 'Standalone product remains registered after uninstall.' }
    if (Test-Path -LiteralPath $installedExe) { throw 'Standalone executable remained after uninstall.' }
    Assert-FixtureRetention
    Assert-NoAppStarted
    @{result='passed';edition='standalone';checksums=$true;msi_identity=$true;installed=$true;repaired=$true;uninstalled=$true;synthetic_appdata_and_backups_preserved=$true;gui_launched=$false;database_created=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory 'result.json')
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $LogDirectory 'failure.txt')
    throw
} finally {
    if ($installAttempted -and -not $timedOut -and $productCode -and $installer.ProductState($productCode) -ne -1) {
        try { Invoke-Msi '/x' $productCode 'standalone-cleanup-uninstall' } catch { Write-Warning $_ }
    }
    # Leave evidence untouched if MSI timed out or removal failed; the runner is disposable.
    if (-not $timedOut -and $productCode -and $installer.ProductState($productCode) -eq -1) { Remove-OwnedFixtures }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)|Out-Null
}
