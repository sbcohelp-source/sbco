#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ArtifactDirectory,[Parameter(Mandatory=$true)][string]$LogDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $env:RUNNER_TEMP) { throw 'GUI qualification requires an ephemeral GitHub-hosted Windows x64 runner.' }
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The disposable installer fixture must be elevated.' }
if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { throw 'A usable interactive desktop session is required.' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GuiDesktop {
 [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
 [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
 [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
'@
$desktop=[GuiDesktop]::OpenInputDesktop(0,$false,0x100)
if ($desktop -eq [IntPtr]::Zero) { throw 'Runner has no accessible input desktop.' }
$null=[GuiDesktop]::CloseDesktop($desktop)
if ([GuiDesktop]::GetSystemMetrics(0) -lt 800 -or [GuiDesktop]::GetSystemMetrics(1) -lt 600) { throw 'Runner desktop resolution is too small for this gate.' }
function Assert-GuiPath([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'GUI fixture paths must not contain links or junctions.' }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function Get-GuiDataRoots {
    # Resolve Windows Known Folders; do not redirect profiles through environment variables.
    $roaming=[Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    foreach ($folder in @($roaming,$local)) {
        if (-not $folder -or -not [IO.Path]::IsPathFullyQualified($folder)) { throw 'Windows Known Folder could not be resolved.' }
        Assert-GuiPath $folder
        Join-Path $folder 'in.sbco.vouchercheck'
    }
}
function Assert-OwnedGuiRoot([string]$Path,[string]$Token,[string[]]$AllowedRoots) {
    $full=[IO.Path]::GetFullPath($Path)
    if ($Token -cnotmatch '^[a-f0-9]{32}$' -or $AllowedRoots -inotcontains $full) { throw 'GUI cleanup path or ownership identity is invalid.' }
    Assert-GuiPath $full
    $marker=Join-Path $full 'gui-fixture-owner.txt'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'GUI cleanup ownership marker is missing.' }
    Assert-GuiPath $marker
    if ([IO.File]::ReadAllText($marker) -cne $Token) { throw 'GUI cleanup token does not match; preserve the directory.' }
    # Refuse links anywhere before a recursive deletion; never follow foreign data.
    if (Get-ChildItem -LiteralPath $full -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'GUI fixture contains a link or junction; preserve it.' }
}
function New-PrivateGuiRoot([string]$Path,[string]$Token) {
    if (Test-Path -LiteralPath $Path) { throw 'GUI fixture directory already exists.' }
    Assert-GuiPath $Path
    $null=[IO.Directory]::CreateDirectory($Path)
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    [IO.File]::WriteAllText((Join-Path $Path 'gui-fixture-owner.txt'),$Token)
}
# Reuse the reviewed checksum, identity and bounded MSI adapters, never the smoke script body.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-windows-standalone-installer.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('Get-VerifiedMsi','Assert-StandaloneIdentity','Read-MsiRows','Invoke-Msi')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if ($null -eq $definition) { throw "Required installer helper is missing: $name" }
    Invoke-Expression $definition.Extent.Text
}
$ArtifactDirectory=[IO.Path]::GetFullPath($ArtifactDirectory)
$LogDirectory=[IO.Path]::GetFullPath($LogDirectory)
Assert-GuiPath $LogDirectory
$null=[IO.Directory]::CreateDirectory($LogDirectory)
$knownRoots=@(Get-GuiDataRoots | Select-Object -Unique)
$token=[guid]::NewGuid().ToString('N')
$privateRoot=Join-Path ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) ('sbco-gui-'+$token)
$allowedRoots=@($knownRoots)+@($privateRoot)
$ownedRoots=[Collections.Generic.List[string]]::new()
$knownProcesses=@{}
$startedAt=[DateTime]::UtcNow
$application=$null;$driverPath=$null;$productCode=$null;$installAttempted=$false;$timedOut=$false
$installer=New-Object -ComObject WindowsInstaller.Installer
function Test-GuiChildIdentity($Child,$Parent) {
    # Windows can retain a dead parent's PID after that number is reused. Only
    # children created at/after this exact parent instance belong to its tree.
    return [bool]($Child.CreationDate -and $Parent.CreationDate -and $Child.ExecutablePath -and
        $Child.ParentProcessId -eq $Parent.ProcessId -and $Child.ProcessId -ne $Parent.ProcessId -and
        $Child.CreationDate.ToUniversalTime() -ge $Parent.CreationDate.ToUniversalTime())
}
function Remember-GuiProcesses {
    $all=@(Get-CimInstance Win32_Process)
    $owned=@($all | Where-Object { $_.CreationDate -and $_.CreationDate.ToUniversalTime() -ge $startedAt -and $_.ExecutablePath -and (($application -and $_.ExecutablePath -ieq $application) -or ($driverPath -and $_.ExecutablePath -ieq $driverPath)) })
    $changed=$true
    while ($changed) {
        $ids=@($owned | ForEach-Object { $_.ProcessId })
        $children=@(foreach ($candidate in $all) {
            if ($candidate.ProcessId -in $ids) { continue }
            foreach ($parent in $owned) {
                if (Test-GuiChildIdentity $candidate $parent) { $candidate;break }
            }
        })
        $changed=$children.Count -gt 0;$owned+=@($children)
    }
    foreach ($process in $owned) { $knownProcesses[[string]$process.ProcessId]=[pscustomobject]@{pid=$process.ProcessId;created=$process.CreationDate;path=$process.ExecutablePath} }
}
function Stop-GuiProcesses {
    Remember-GuiProcesses
    foreach ($owned in @($knownProcesses.Values | Where-Object { $_.path -ieq $application })) {
        $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($owned.pid)"
        if ($current -and $current.CreationDate -eq $owned.created -and $current.ExecutablePath -ieq $owned.path) {
            $process=Get-Process -Id $owned.pid
            $null=$process.CloseMainWindow();$null=$process.WaitForExit(15000)
        }
    }
    # pg_ctl targets only the fresh token-owned cluster. Failure keeps all data for inspection.
    foreach ($root in $knownRoots) {
        if (Test-Path -LiteralPath (Join-Path $root 'postgres\postmaster.pid')) {
            Assert-OwnedGuiRoot $root $token $allowedRoots
            $pgCtl=Join-Path ([IO.Path]::GetDirectoryName($application)) 'postgres\bin\pg_ctl.exe'
            $process=Start-Process -FilePath $pgCtl -ArgumentList ('-D "'+(Join-Path $root 'postgres')+'" -w -t 30 stop -m fast') -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $privateRoot 'pg-stop.out') -RedirectStandardError (Join-Path $privateRoot 'pg-stop.err')
            try { if (-not $process.WaitForExit(40000)) { $process.Kill();throw 'Owned fixture PostgreSQL stop timed out.' };if ($process.ExitCode -ne 0) { throw 'Owned fixture PostgreSQL did not stop; data preserved.' } } finally { $process.Dispose() }
        }
    }
    foreach ($owned in @($knownProcesses.Values)) {
        $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($owned.pid)"
        if ($current -and $current.CreationDate -eq $owned.created -and $current.ExecutablePath -ieq $owned.path) { Stop-Process -Id $owned.pid -Force }
    }
    if ($application -and (Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $application })) { throw 'Fixture application remains running.' }
}
function Get-EdgeDriverVersion([string]$Path) {
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') { throw 'Edge driver must have a valid Microsoft signature.' }
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Path;$info.Arguments='--version';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        $null=$process.Start()
        $output=$process.StandardOutput.ReadToEndAsync();$errorOutput=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill();throw 'Edge driver version probe timed out.' }
        if ($process.ExitCode -ne 0 -or $output.Result -notmatch 'MSEdgeDriver\s+(\d+\.\d+\.\d+\.\d+)') { throw 'Edge driver version could not be verified.' }
        return $Matches[1]
    } finally { $process.Dispose() }
}
function Get-MatchingEdgeDriver {
    # Microsoft's documented WebView2 Runtime product registration (not Edge browser version).
    $runtimeKey='{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $versions=@(foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients','HKCU:\Software\Microsoft\EdgeUpdate\Clients')) {
        $key=Join-Path $root $runtimeKey
        if (Test-Path $key) { $value=Get-ItemPropertyValue -LiteralPath $key -Name pv;if ($value -match '^\d+\.\d+\.\d+\.\d+$' -and $value -ne '0.0.0.0') { $value } }
    }) | Select-Object -Unique
    if (@($versions).Count -ne 1) { throw 'Expected one unambiguous installed WebView2 Runtime version.' }
    $runtime=[string]@($versions)[0]
    $candidate=if ($env:EDGEWEBDRIVER) { Join-Path $env:EDGEWEBDRIVER 'msedgedriver.exe' } else { '' }
    $version=''
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { $version=Get-EdgeDriverVersion $candidate }
    $source='GitHub runner preinstalled Edge Driver'
    if (-not $version -or ($version.Split('.')[0..2] -join '.') -ne ($runtime.Split('.')[0..2] -join '.')) {
        $zipPath=Join-Path $privateRoot 'edgedriver.zip'
        $source="https://msedgedriver.microsoft.com/$runtime/edgedriver_win64.zip"
        Invoke-WebRequest -Uri $source -OutFile $zipPath -TimeoutSec 120
        $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $entry=$zip.GetEntry('msedgedriver.exe')
            if ($null -eq $entry) { throw 'Official driver archive does not contain msedgedriver.exe.' }
            $candidate=Join-Path $privateRoot 'msedgedriver.exe'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$candidate,$false)
        } finally { $zip.Dispose() }
        $version=Get-EdgeDriverVersion $candidate
    }
    if (($version.Split('.')[0..2] -join '.') -ne ($runtime.Split('.')[0..2] -join '.')) { throw 'Edge driver does not match the installed WebView2 Runtime.' }
    return [pscustomobject]@{path=$candidate;version=$version;runtime=$runtime;source=$source;sha256=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash}
}
try {
    foreach ($path in @($knownRoots)+@((Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SBCO Server'),(Join-Path $env:ProgramFiles 'SBCO'),(Join-Path $env:ProgramFiles 'SBCO Client'))) { if (Test-Path -LiteralPath $path) { throw 'Existing SBCO installation/data found; refusing GUI fixture.' } }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path $root) { foreach ($entry in Get-ChildItem $root) { if ($entry.GetValue('DisplayName',$null) -like 'SBCO*') { throw 'An existing SBCO product is registered.' } } }
    }
    if ((Get-Process -Name 'sbco-desktop','sbco-client','msedgedriver' -ErrorAction SilentlyContinue) -or (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue)) { throw 'Existing application, driver or SBCO service found.' }
    foreach ($name in @('DATABASE_URL','SBCO_POSTGRES_BIN','SBCO_POSTGRES_SHARE','WEBVIEW2_BROWSER_EXECUTABLE_FOLDER','WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','WEBVIEW2_USER_DATA_FOLDER')) { if ([Environment]::GetEnvironmentVariable($name)) { throw "Unexpected runtime override $name; refusing fixture." } }
    New-PrivateGuiRoot $privateRoot $token;$ownedRoots.Add($privateRoot)
    $verified=Get-VerifiedMsi $ArtifactDirectory
    $database=$installer.OpenDatabase($verified.path,0)
    try {
        $properties=@{};foreach ($row in Read-MsiRows $database 'SELECT `Property`, `Value` FROM `Property`' 2) { $properties[$row[0]]=$row[1] }
        $summary=$database.SummaryInformation(0);try { $template=$summary.Property(7) } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary)|Out-Null }
        Assert-StandaloneIdentity $properties $template
        $productCode=$properties.ProductCode
        if ($installer.ProductState($productCode) -ne -1) { throw 'Standalone product already registered.' }
        $main=@(Read-MsiRows $database 'SELECT `File`, `Component_`, `FileName` FROM `File`' 3 | Where-Object { $_[2].Split('|')[-1] -ceq 'sbco-desktop.exe' })
        if ($main.Count -ne 1) { throw 'MSI standalone executable identity is ambiguous.' }
        $component=@(Read-MsiRows $database 'SELECT `Component`, `ComponentId`, `KeyPath` FROM `Component`' 3 | Where-Object { $_[0] -ceq $main[0][1] -and $_[2] -ceq $main[0][0] })
        if ($component.Count -ne 1 -or [guid]$component[0][1] -eq [guid]::Empty) { throw 'MSI application component is invalid.' }
        $mainComponent=$component[0][1]
    } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)|Out-Null }
    $installAttempted=$true;Invoke-Msi '/i' $verified.path 'gui-install'
    if ($installer.ProductState($productCode) -ne 5) { throw 'Standalone product is not installed.' }
    $application=$installer.ComponentPath($productCode,$mainComponent)
    if (-not $application -or -not (Test-Path -LiteralPath $application -PathType Leaf)) { throw 'Installed executable missing.' }
    $matching=Get-MatchingEdgeDriver;$driverPath=$matching.path
    $os=Get-CimInstance Win32_OperatingSystem
    @{os=$os.Caption;build=$os.BuildNumber;session=[Diagnostics.Process]::GetCurrentProcess().SessionId;runtime=$matching.runtime;driver_version=$matching.version;driver_source=$matching.source;driver_sha256=$matching.sha256;msi_sha256=$verified.sha256;product_code=$productCode;upgrade_code=$properties.UpgradeCode;known_folders=$knownRoots;windows_10_11_qualified=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory 'environment.json')
    foreach ($root in $knownRoots) { New-PrivateGuiRoot $root $token;$ownedRoots.Add($root) }
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $config=Join-Path $privateRoot 'driver-config.json'
    @{private_root=$privateRoot;evidence_root=$LogDirectory;port=$port;driver=$driverPath;application=$application;runtime_version=$matching.runtime} | ConvertTo-Json | Set-Content -LiteralPath $config
    $python=(Get-Command python -ErrorAction Stop).Source
    foreach ($phase in @('setup','reopen')) {
        $process=Start-Process -FilePath $python -ArgumentList ('"'+(Join-Path $PSScriptRoot '..\tests\windows_standalone_gui.py')+'" --config "'+$config+'" --phase '+$phase) -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $privateRoot "$phase.out") -RedirectStandardError (Join-Path $privateRoot "$phase.err")
        try {
            $deadline=[DateTime]::UtcNow.AddMinutes(8)
            while (-not $process.WaitForExit(1000)) { Remember-GuiProcesses;if ([DateTime]::UtcNow -gt $deadline) { $process.Kill();throw "GUI $phase exceeded eight minutes." } }
            if ($process.ExitCode -ne 0) { throw "GUI $phase failed; inspect sanitized phase evidence." }
        } finally { $process.Dispose();Stop-GuiProcesses }
    }
    Invoke-Msi '/x' $productCode 'gui-uninstall'
    if ($installer.ProductState($productCode) -ne -1) { throw 'GUI fixture product remains installed.' }
    foreach ($root in $knownRoots) { Assert-OwnedGuiRoot $root $token $allowedRoots }
    @{result='passed';installed_standalone_gui=$true;visible_setup_and_sign_in=$true;help_search=$true;restart_account_persistence=$true;uninstall_preserved_profile=$true;native_dialogs_tested=$false;windows_10_11_qualified=$false;msi_sha256=$verified.sha256} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory 'gui-result.json')
} catch {
    # Outer errors contain no account fields; driver/PG stderr and account JSON stay private.
    @{type=$_.Exception.GetType().Name;message=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory 'fixture-failure.json')
    throw 'Installed standalone GUI gate failed; inspect sanitized evidence.'
} finally {
    $stopped=$false
    try { if ($application) { Stop-GuiProcesses };$stopped=$true } catch { Write-Warning 'Owned processes could not be stopped; fixture data retained.' }
    if ($stopped -and $installAttempted -and -not $timedOut -and $productCode -and $installer.ProductState($productCode) -ne -1) {
        try { Invoke-Msi '/x' $productCode 'gui-cleanup-uninstall' } catch { Write-Warning 'Owned MSI cleanup failed; fixture retained.' }
    }
    if ($stopped -and -not $timedOut -and (-not $installAttempted -or $installer.ProductState($productCode) -eq -1)) {
        foreach ($root in $ownedRoots) { try { Assert-OwnedGuiRoot $root $token $allowedRoots;Remove-Item -LiteralPath $root -Recurse -Force } catch { Write-Warning 'Fixture ownership cleanup was refused; directory retained.' } }
    }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)|Out-Null
}
