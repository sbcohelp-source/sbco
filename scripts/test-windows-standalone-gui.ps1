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
$webViewPolicyState=@{values=@();created_keys=@()}
$installer=New-Object -ComObject WindowsInstaller.Installer
function Test-GuiPolicyValueOwned($Actual,$Kind,[string]$Expected) {
    return [bool]($Kind -eq [Microsoft.Win32.RegistryValueKind]::String -and $Actual -is [string] -and $Actual -ceq $Expected)
}
function Save-GuiPolicyJournal {
    $webViewPolicyState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $privateRoot 'webview-policy-ownership.json')
}
function Install-GuiWebViewPolicy([int]$Port) {
    if ([IO.Path]::GetFileName($application) -cne 'sbco-desktop.exe' -or $Port -lt 1 -or $Port -gt 65535) { throw 'Invalid exact application debugging policy target.' }
    $basePath='SOFTWARE\Policies\Microsoft\Edge\WebView2'
    $scopes=@('AdditionalBrowserArguments','UserDataFolder')
    $refusalScopes=$scopes+@('BrowserExecutableFolder','ChannelSearchKind','ReleaseChannels')
    $names=@('sbco-desktop.exe','in.sbco.vouchercheck','*')
    # Elevated WebView2 honors HKLM policies. Refuse every relevant existing
    # override in both registry views/hives; never replace an office policy.
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryHive]::CurrentUser)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$view)
            try {
                foreach ($scope in $refusalScopes) {
                    $key=$base.OpenSubKey($basePath+'\'+$scope)
                    if ($key) { try { foreach ($name in $key.GetValueNames()) { if ($name -in $names) { throw 'Existing SBCO or wildcard WebView2 policy found; refusing fixture override.' } } } finally { $key.Dispose() } }
                }
            } finally { $base.Dispose() }
        }
    }
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        foreach ($scope in $scopes) {
            $path=$basePath+'\'+$scope
            $prefix=''
            foreach ($part in $path.Split('\')) {
                $prefix=if ($prefix) { $prefix+'\'+$part } else { $part }
                $existing=$base.OpenSubKey($prefix)
                if ($existing) { $existing.Dispose();continue }
                $webViewPolicyState.created_keys+=@($prefix);Save-GuiPolicyJournal
                $created=$base.CreateSubKey($prefix);$created.Dispose()
            }
            $expected=if ($scope -eq 'AdditionalBrowserArguments') { '--remote-debugging-address=127.0.0.1 --remote-debugging-port='+$Port } else { Join-Path $privateRoot 'webview' }
            $key=$base.OpenSubKey($path,$true)
            try {
                foreach ($name in $key.GetValueNames()) { if ($name -in $names) { throw 'WebView2 policy changed during fixture setup; refusing overwrite.' } }
                $webViewPolicyState.values+=@(@{path=$path;name='sbco-desktop.exe';expected=$expected});Save-GuiPolicyJournal
                $key.SetValue('sbco-desktop.exe',$expected,[Microsoft.Win32.RegistryValueKind]::String)
            } finally { $key.Dispose() }
        }
    } finally { $base.Dispose() }
}
function Remove-GuiWebViewPolicy {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try {
        foreach ($owned in $webViewPolicyState.values) {
            $key=$base.OpenSubKey($owned.path,$true)
            if (-not $key) { continue }
            try {
                if ($owned.name -notin $key.GetValueNames()) { continue }
                if (-not (Test-GuiPolicyValueOwned $key.GetValue($owned.name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) $key.GetValueKind($owned.name) $owned.expected)) { throw 'WebView2 policy ownership changed; preserve it.' }
                $key.DeleteValue($owned.name,$false)
            } finally { $key.Dispose() }
        }
        foreach ($path in @($webViewPolicyState.created_keys | Sort-Object Length -Descending)) {
            $key=$base.OpenSubKey($path)
            if (-not $key) { continue }
            try { $empty=$key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0 } finally { $key.Dispose() }
            if ($empty) { $base.DeleteSubKey($path,$false) }
        }
    } finally { $base.Dispose() }
}
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
function Get-GuiOwnedProcess($Owned) {
    try { $process=[Diagnostics.Process]::GetProcessById([int]$Owned.pid) }
    catch [ArgumentException] { return $null } # The exact child already exited.
    try {
        $null=$process.Handle # Pin this instance before checking the current PID.
        $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($Owned.pid)"
        if (-not $current -or $current.CreationDate -ne $Owned.created -or $current.ExecutablePath -ine $Owned.path -or $process.HasExited) { $process.Dispose();return $null }
        return $process
    } catch {
        $exited=$process.HasExited;$process.Dispose()
        if (-not $exited) { throw }
        return $null
    }
}
function Stop-GuiProcesses {
    Remember-GuiProcesses
    foreach ($owned in @($knownProcesses.Values | Where-Object { $_.path -ieq $application })) {
        $process=Get-GuiOwnedProcess $owned
        if ($process) {
            try { if (-not $process.HasExited) { $null=$process.CloseMainWindow();$null=$process.WaitForExit(15000) } }
            catch { if (-not $process.HasExited) { throw } }
            finally { $process.Dispose() }
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
        $process=Get-GuiOwnedProcess $owned
        if ($process) {
            try { if (-not $process.HasExited) { $process.Kill();if (-not $process.WaitForExit(10000)) { throw 'Exact owned fixture process did not stop; preserve data and policy journal.' } } }
            catch { if (-not $process.HasExited) { throw } }
            finally { $process.Dispose() }
        }
    }
    if ($application -and (Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $application })) { throw 'Fixture application remains running.' }
}
function Test-GuiDescendantIdentity($Child,$Root,[object[]]$Processes) {
    $current=$Child
    for ($depth=0;$current -and $depth -lt 200;$depth++) {
        if ($current.ProcessId -eq $Root.ProcessId) {
            return [bool]($current.CreationDate -eq $Root.CreationDate -and $current.ExecutablePath -ieq $Root.ExecutablePath)
        }
        $parents=@($Processes | Where-Object { $_.ProcessId -eq $current.ParentProcessId })
        if ($parents.Count -ne 1 -or -not (Test-GuiChildIdentity $current $parents[0])) { return $false }
        $current=$parents[0]
    }
    return $false
}
function Confirm-GuiDebugListener([string]$Phase) {
    $requestPath=Join-Path $privateRoot ($Phase+'-debug-request.json')
    $ackPath=Join-Path $privateRoot ($Phase+'-debug-verified')
    if ((Test-Path -LiteralPath $ackPath) -or -not (Test-Path -LiteralPath $requestPath)) { return }
    $request=Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
    $appIdentity=$knownProcesses[[string]$request.application_pid]
    $appCurrent=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$request.application_pid)"
    if (-not $appIdentity -or $appIdentity.path -ine $application -or -not $appCurrent -or $appCurrent.CreationDate -ne $appIdentity.created -or $appCurrent.ExecutablePath -ine $application) { throw 'Debug request does not belong to the current fixture application.' }
    $port=[int]$request.port
    if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid fixture debugging port.' }
    $listeners=@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop)
    if ($listeners.Count -eq 0) { throw 'Fixture debugging listener is missing.' }
    $allProcesses=@(Get-CimInstance Win32_Process)
    foreach ($listener in $listeners) {
        if ($listener.LocalAddress -notin @('127.0.0.1','::1')) { throw 'Fixture debugging listener is not restricted to loopback.' }
        $owner=$knownProcesses[[string]$listener.OwningProcess]
        $current=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$listener.OwningProcess)"
        if (-not $owner -or -not $current -or $current.CreationDate -ne $owner.created -or $current.ExecutablePath -ine $owner.path) { throw 'Debugging listener does not belong to an exact fixture process.' }
        if (-not (Test-GuiDescendantIdentity $current $appCurrent $allProcesses)) { throw 'Debugging listener is outside the exact application process tree.' }
    }
    [IO.File]::WriteAllText($ackPath,'verified')
}
function Protect-GuiStartupText([string]$Text,[string[]]$Secrets) {
    foreach ($secret in $Secrets) { if ($secret) { $Text=$Text.Replace($secret,'[REDACTED]') } }
    $Text=[regex]::Replace($Text,'postgres(?:ql)?://[^\s"<>]+','[REDACTED_DATABASE_URI]')
    return $Text.Substring(0,[Math]::Min(3000,$Text.Length))
}
function Read-GuiLiveText([string]$Path) {
    # Python retains write handles while the supervised application is alive.
    # ReadAllText's read-only sharing would reject precisely that diagnostic case.
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Save-GuiStartupState([string]$Phase) {
    $state=@{}
    try {
        Remember-GuiProcesses
        $active=@(foreach ($owned in $knownProcesses.Values) {
            $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($owned.pid)"
            if ($current -and $current.CreationDate -eq $owned.created -and $current.ExecutablePath -ieq $owned.path) { $current }
        })
        $state.processes=@($active | Select-Object -First 100 | ForEach-Object {
            @{pid=$_.ProcessId;parent_pid=$_.ParentProcessId;created=$_.CreationDate;executable=[IO.Path]::GetFileName($_.ExecutablePath)}
        })
        $state.windows=@($active | Where-Object { $_.ExecutablePath -ieq $application } | ForEach-Object {
            $native=Get-Process -Id $_.ProcessId -ErrorAction Stop
            @{pid=$_.ProcessId;handle=$native.MainWindowHandle.ToInt64();title=$native.MainWindowTitle}
        })
        $ids=@($active | ForEach-Object { $_.ProcessId })
        $state.listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.OwningProcess -in $ids } | Select-Object -First 100 | ForEach-Object {
            @{pid=$_.OwningProcess;address=$_.LocalAddress;port=$_.LocalPort}
        })
        $state.database_files=@(foreach ($root in $knownRoots) {
            Assert-OwnedGuiRoot $root $token $allowedRoots
            $log=Join-Path $root 'postgres.log'
            @{config_exists=(Test-Path -LiteralPath (Join-Path $root 'database.json'));pg_version_exists=(Test-Path -LiteralPath (Join-Path $root 'postgres/PG_VERSION'));pid_file_exists=(Test-Path -LiteralPath (Join-Path $root 'postgres/postmaster.pid'));log_bytes=$(if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 })}
        })
    } catch { $state.snapshot_error=@{type=$_.Exception.GetType().Name;hresult=$_.Exception.HResult} }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LogDirectory ($Phase+'-startup-state.json'))
}
function Save-GuiStartupEvidence([string]$Phase) {
    # Raw child output stays private. Discover generated secrets before exporting
    # any bounded text; if discovery fails, omit the text instead of guessing.
    $result=@{};$diagnosticStage='discover generated secrets'
    try {
        $secrets=@(foreach ($root in $knownRoots) {
            Assert-OwnedGuiRoot $root $token $allowedRoots
            $databaseConfig=Join-Path $root 'database.json'
            if (Test-Path -LiteralPath $databaseConfig) { (Get-Content -LiteralPath $databaseConfig -Raw | ConvertFrom-Json).password }
        })
        $accountFile=Join-Path $privateRoot 'account.json'
        if (Test-Path -LiteralPath $accountFile) { $secrets+=@((Get-Content -LiteralPath $accountFile -Raw | ConvertFrom-Json).password) }
        foreach ($stream in @('stdout','stderr')) {
            $diagnosticStage='read '+$stream
            $path=Join-Path $privateRoot ($Phase+'-application.'+$stream)
            if (Test-Path -LiteralPath $path) { $result[$stream]=Protect-GuiStartupText (Read-GuiLiveText $path) $secrets }
        }
        $result.postgres_logs=@(foreach ($root in $knownRoots) {
            $diagnosticStage='read owned PostgreSQL log'
            $path=Join-Path $root 'postgres.log'
            if (Test-Path -LiteralPath $path) { Protect-GuiStartupText (Read-GuiLiveText $path) $secrets }
        })
    } catch { $result=@{diagnostics='Application text omitted because safe redaction could not be established.';stage=$diagnosticStage;error_type=$_.Exception.GetType().Name;hresult=$_.Exception.HResult} }
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory ($Phase+'-application-diagnostics.json'))
}
function ConvertFrom-EdgeDriverVersion([string]$Output,[int]$ExitCode) {
    # Public --version format verified against Microsoft's distributed driver.
    if ($ExitCode -ne 0 -or $Output.Trim() -notmatch '^Microsoft Edge WebDriver (\d+\.\d+\.\d+\.\d+)(?: \([a-f0-9]+\))?$') { throw 'Edge driver version could not be verified.' }
    return $Matches[1]
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
        $stdout=$output.GetAwaiter().GetResult().Trim();$stderr=$errorOutput.GetAwaiter().GetResult().Trim()
        # This process ran only --version before app/credentials exist. Never log
        # output from the later WebDriver session (which handles password fields).
        @{exit_code=$process.ExitCode;stdout=$stdout.Substring(0,[Math]::Min(512,$stdout.Length));stderr=$stderr.Substring(0,[Math]::Min(512,$stderr.Length))} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory ('driver-version-'+[guid]::NewGuid().ToString('N')+'.json'))
        return ConvertFrom-EdgeDriverVersion $stdout $process.ExitCode
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
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$debugPort=$listener.LocalEndpoint.Port;$listener.Stop()
    if ($debugPort -eq $port) { throw 'Driver and WebView2 debugging ports must be distinct.' }
    Install-GuiWebViewPolicy $debugPort
    $config=Join-Path $privateRoot 'driver-config.json'
    @{private_root=$privateRoot;evidence_root=$LogDirectory;port=$port;debug_port=$debugPort;driver=$driverPath;application=$application;runtime_version=$matching.runtime} | ConvertTo-Json | Set-Content -LiteralPath $config
    $python=(Get-Command python -ErrorAction Stop).Source
    foreach ($phase in @('setup','reopen')) {
        $process=Start-Process -FilePath $python -ArgumentList ('"'+(Join-Path $PSScriptRoot '..\tests\windows_standalone_gui.py')+'" --config "'+$config+'" --phase '+$phase) -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $privateRoot "$phase.out") -RedirectStandardError (Join-Path $privateRoot "$phase.err")
        try {
            $deadline=[DateTime]::UtcNow.AddMinutes(8)
            while (-not $process.WaitForExit(1000)) { Remember-GuiProcesses;Confirm-GuiDebugListener $phase;if ([DateTime]::UtcNow -gt $deadline) { $process.Kill();throw "GUI $phase exceeded eight minutes." } }
            if ($process.ExitCode -ne 0) { Save-GuiStartupState $phase;Save-GuiStartupEvidence $phase;throw "GUI $phase failed; inspect sanitized phase evidence." }
        } finally {
            try {
                # A supervisor rejection can interrupt Python while it waits for
                # the handshake. Stop this exact child before deleting evidence
                # or profiles; do not kill its app/PostgreSQL descendants here.
                if (-not $process.HasExited) { $process.Kill() }
                if (-not $process.WaitForExit(10000)) { $timedOut=$true;throw 'GUI harness did not stop; fixture data retained.' }
            } finally { $process.Dispose();Stop-GuiProcesses }
        }
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
    $stopped=$false;$policiesRemoved=$false
    try { if ($application) { Stop-GuiProcesses };$stopped=$true } catch { Write-Warning 'Owned processes could not be stopped; fixture data retained.' }
    if ($stopped) { try { Remove-GuiWebViewPolicy;$policiesRemoved=$true;if ($webViewPolicyState.values.Count -gt 0) { @{exact_app_policy_removed=$true;ordinary_user_qualified=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory 'policy-cleanup.json') } } catch { Write-Warning 'Owned WebView2 policy cleanup was refused; private journal retained.' } }
    if ($stopped -and $installAttempted -and -not $timedOut -and $productCode -and $installer.ProductState($productCode) -ne -1) {
        try { Invoke-Msi '/x' $productCode 'gui-cleanup-uninstall' } catch { Write-Warning 'Owned MSI cleanup failed; fixture retained.' }
    }
    if ($stopped -and $policiesRemoved -and -not $timedOut -and (-not $installAttempted -or $installer.ProductState($productCode) -eq -1)) {
        foreach ($root in $ownedRoots) { try { Assert-OwnedGuiRoot $root $token $allowedRoots;Remove-Item -LiteralPath $root -Recurse -Force } catch { Write-Warning 'Fixture ownership cleanup was refused; directory retained.' } }
    }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)|Out-Null
    if (-not $policiesRemoved -and ($webViewPolicyState.values.Count -gt 0 -or $webViewPolicyState.created_keys.Count -gt 0)) { throw 'Fixture policy cleanup incomplete; inspect retained ownership journal on runner.' }
}
