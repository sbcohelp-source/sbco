#requires -Version 7.2
# Portable tests exercise the actual ownership/path helpers; never start a Windows app.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Operation,[string]$Message) { $failed=$false;try { & $Operation | Out-Null } catch { $failed=$true };Assert $failed $Message }
$source=Join-Path $PSScriptRoot 'test-windows-standalone-gui.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors|Out-String) }
foreach ($name in @('Assert-GuiPath','Assert-OwnedGuiRoot','Get-GuiDataRoots','Test-GuiChildIdentity','ConvertFrom-EdgeDriverVersion','Protect-GuiStartupText','Test-GuiDescendantIdentity','Read-GuiLiveText','Test-GuiPolicyValueOwned','Get-GuiOwnedProcess')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Assert ($null -ne $definition) "Missing helper $name"
    Invoke-Expression $definition.Extent.Text
}
$safe=Protect-GuiStartupText 'generated-password postgresql://u:other@localhost/db tail' @('generated-password')
Assert ($safe -ceq '[REDACTED] [REDACTED_DATABASE_URI] tail') 'Startup evidence exposed generated password or database URI.'
Assert ((Protect-GuiStartupText ('x'*4000) @()).Length -eq 3000) 'Startup evidence was not bounded.'
Write-Host 'PASS pre-credential startup diagnostics secret/URI redaction and output bound.'
Assert (Test-GuiPolicyValueOwned 'exact-fixture-value' ([Microsoft.Win32.RegistryValueKind]::String) 'exact-fixture-value') 'Owned policy string refused.'
Assert (-not (Test-GuiPolicyValueOwned 'foreign-value' ([Microsoft.Win32.RegistryValueKind]::String) 'exact-fixture-value')) 'Changed policy would be removed.'
Assert (-not (Test-GuiPolicyValueOwned 'exact-fixture-value' ([Microsoft.Win32.RegistryValueKind]::ExpandString) 'exact-fixture-value')) 'Changed policy type would be removed.'
Write-Host 'PASS exact policy value/type ownership refusal.'
# Captured from the official 155.0.4283.62 Linux driver --version (no browser launch).
$publicVersion='Microsoft Edge WebDriver 155.0.4283.62 (aa3a7406ba8c53a83536df539f07124d73c899bd)'
Assert ((ConvertFrom-EdgeDriverVersion ($publicVersion+"`r`n") 0) -ceq '155.0.4283.62') 'Official Edge driver branding/version was rejected.'
Refuses { ConvertFrom-EdgeDriverVersion $publicVersion 1 } 'Failed version process accepted.'
Refuses { ConvertFrom-EdgeDriverVersion 'ChromeDriver 155.0.4283.62' 0 } 'Different driver brand accepted.'
Refuses { ConvertFrom-EdgeDriverVersion '' 0 } 'Empty version output accepted.'
Refuses { ConvertFrom-EdgeDriverVersion 'Microsoft Edge WebDriver 155.0.4283' 0 } 'Incomplete version accepted.'
Write-Host 'PASS official Edge driver version branding, exit-code, malformed/foreign-output checks.'
$parent=[pscustomobject]@{ProcessId=100;CreationDate=[DateTime]'2026-10-29T10:00:10Z';ExecutablePath='owned.exe'}
$child=[pscustomobject]@{ProcessId=200;ParentProcessId=100;CreationDate=[DateTime]'2026-10-29T10:00:11Z';ExecutablePath='child.exe'}
Assert (Test-GuiChildIdentity $child $parent) 'Actual newer child was rejected.'
$child.CreationDate=[DateTime]'2026-10-29T10:00:05Z'
Assert (-not (Test-GuiChildIdentity $child $parent)) 'Stale parent PID reuse wrongly claimed an older process.'
$child.CreationDate=$parent.CreationDate
Assert (Test-GuiChildIdentity $child $parent) 'Equal timestamp resolution child was rejected.'
$child.ParentProcessId=999
Assert (-not (Test-GuiChildIdentity $child $parent)) 'Unrelated process was claimed.'
$child.ParentProcessId=100;$child.CreationDate=$null
Assert (-not (Test-GuiChildIdentity $child $parent)) 'Process without creation identity was claimed.'
$child.CreationDate=[DateTime]'2026-10-29T10:00:11Z'
Assert (Test-GuiDescendantIdentity $child $parent @($parent,$child)) 'Actual app descendant rejected.'
$foreign=[pscustomobject]@{ProcessId=300;ParentProcessId=0;CreationDate=[DateTime]'2026-10-29T10:00:01Z';ExecutablePath='driver.exe'}
$child.ParentProcessId=300
Assert (-not (Test-GuiDescendantIdentity $child $parent @($parent,$child,$foreign))) 'Driver-root child accepted as application listener.'
$child.ParentProcessId=100;$child.CreationDate=[DateTime]'2026-10-29T10:00:05Z'
Assert (-not (Test-GuiDescendantIdentity $child $parent @($parent,$child))) 'Reused application PID accepted as listener ancestor.'
Write-Host 'PASS exact parent-instance ancestry, including stale PID reuse and unknown creation time refusal.'
# Pin a real benign process handle, while mocking only CIM's identity snapshot.
# No process is terminated in this test.
$self=[Diagnostics.Process]::GetCurrentProcess()
$fixtureIdentity=[pscustomobject]@{ProcessId=$self.Id;CreationDate=$self.StartTime;ExecutablePath=$self.MainModule.FileName}
function Get-CimInstance { param($ClassName,$Filter) return $fixtureIdentity }
try {
    $owned=[pscustomobject]@{pid=$self.Id;created=$fixtureIdentity.CreationDate;path=$fixtureIdentity.ExecutablePath}
    $pinned=Get-GuiOwnedProcess $owned
    Assert ($null -ne $pinned -and $pinned.Handle -ne [IntPtr]::Zero) 'Exact live process was not pinned.'
    $pinned.Dispose()
    $owned.created=$owned.created.AddSeconds(-1)
    Assert ($null -eq (Get-GuiOwnedProcess $owned)) 'Stale process creation identity was accepted.'
    $owned.created=$fixtureIdentity.CreationDate;$owned.path='foreign-application.exe'
    Assert ($null -eq (Get-GuiOwnedProcess $owned)) 'Foreign executable identity was accepted.'
    $owned.path=$fixtureIdentity.ExecutablePath;$fixtureIdentity=$null
    Assert ($null -eq (Get-GuiOwnedProcess $owned)) 'Disappeared CIM process was accepted.'
} finally { Remove-Item Function:Get-CimInstance;$self.Dispose() }
Write-Host 'PASS pinned real process handle with stale/foreign/disappeared identity refusal; no termination.'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sbco-gui-guards-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($fixture)|Out-Null
    $liveLog=Join-Path $fixture 'live-output.txt'
    $writer=[IO.File]::Open($liveLog,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes('live application diagnostics')
        $writer.Write($bytes,0,$bytes.Length);$writer.Flush()
        Assert ((Read-GuiLiveText $liveLog) -ceq 'live application diagnostics') 'Live application output could not be read with shared write handles.'
    } finally { $writer.Dispose() }
    Write-Host 'PASS live application stream diagnostics while writer remains open.'
    $root=Join-Path $fixture 'in.sbco.vouchercheck';[IO.Directory]::CreateDirectory($root)|Out-Null
    $token=[guid]::NewGuid().ToString('N');$allowed=@($root)
    $marker=Join-Path $root 'gui-fixture-owner.txt'
    Refuses { Assert-OwnedGuiRoot $root $token $allowed } 'Missing ownership marker accepted.'
    [IO.File]::WriteAllText($marker,$token)
    Assert-OwnedGuiRoot $root $token $allowed
    Refuses { Assert-OwnedGuiRoot $fixture $token $allowed } 'Ancestor/foreign path accepted for recursive cleanup.'
    Refuses { Assert-OwnedGuiRoot $root ('0'*32) $allowed } 'Wrong ownership identity accepted.'
    Refuses { Assert-OwnedGuiRoot $root '' $allowed } 'Empty cleanup identity accepted.'
    [IO.File]::WriteAllText($marker,'unowned data')
    Refuses { Assert-OwnedGuiRoot $root $token $allowed } 'Changed ownership marker accepted.'
    Assert ([IO.File]::ReadAllText($marker) -ceq 'unowned data') 'Refused cleanup changed existing content.'
    [IO.File]::WriteAllText($marker,$token)
    $outside=Join-Path $fixture 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null
    $link=Join-Path $root 'foreign-link'
    if ($IsWindows) { New-Item -ItemType Junction -Path $link -Target $outside|Out-Null }
    else { New-Item -ItemType SymbolicLink -Path $link -Target $outside|Out-Null }
    Refuses { Assert-OwnedGuiRoot $root $token $allowed } 'Nested junction/symlink accepted.'
    Refuses { Assert-GuiPath (Join-Path $link 'child') } 'Linked ancestor accepted.'
    Remove-Item -LiteralPath $link
    if ($IsWindows) {
        $roots=@(Get-GuiDataRoots)
        Assert ($roots.Count -eq 2) 'Expected both actual Windows Known Folder roots.'
        Assert ($roots[0] -eq (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'in.sbco.vouchercheck')) 'Roaming profile was derived from an environment override.'
        Assert ($roots[1] -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'in.sbco.vouchercheck')) 'Local profile was derived from an environment override.'
    } else {
        $logs=Join-Path $fixture 'must-not-exist';$message=$null
        try { & $source -ArtifactDirectory $fixture -LogDirectory $logs } catch { $message=$_.Exception.Message }
        Assert ($message -like '*ephemeral GitHub-hosted Windows x64*' -and -not (Test-Path -LiteralPath $logs)) 'Non-Windows guard allowed side effects.'
    }
    Write-Host 'PASS GUI cleanup path, marker identity, junction refusal, Known Folder contract and platform guard.'
} finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
