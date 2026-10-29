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
foreach ($name in @('Assert-GuiPath','Assert-OwnedGuiRoot','Get-GuiDataRoots','Test-GuiChildIdentity','ConvertFrom-EdgeDriverVersion')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Assert ($null -ne $definition) "Missing helper $name"
    Invoke-Expression $definition.Extent.Text
}
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
Write-Host 'PASS exact parent-instance ancestry, including stale PID reuse and unknown creation time refusal.'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sbco-gui-guards-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($fixture)|Out-Null
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
