#requires -Version 7.2
# Portable regression check for Next.js dynamic-route names in the shipped manifest.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build-windows-server-msi.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$manifestAssignment = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$manifest'
}, $true)
if ($null -eq $manifestAssignment) { throw 'Server payload manifest generator not found.' }
$payload = Join-Path ([IO.Path]::GetTempPath()) ('sbco-manifest-' + [guid]::NewGuid().ToString('N'))
try {
    $files = @('web/app/[...route]/page.js', 'web/app/[office]/page.js', 'web/space and unicode-हिंदी.js')
    foreach ($relative in $files) {
        $path = Join-Path $payload $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        [IO.File]::WriteAllText($path, 'manifest fixture', [Text.UTF8Encoding]::new($false))
    }
    Invoke-Expression $manifestAssignment.Extent.Text
    if (@($manifest).Count -ne $files.Count) { throw 'Manifest omitted payload files.' }
    $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('manifest fixture'))).ToLowerInvariant()
    foreach ($relative in $files) {
        if ($manifest -cnotcontains "$expected  $relative") { throw "Missing or incorrect literal-path checksum: $relative" }
    }
    Write-Host 'PASS server payload checksums include literal bracket, space and Unicode filenames.'
} finally {
    if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
}

[xml]$wix = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../deploy/windows/server/installer.wxs') -Raw
$namespace = [Xml.XmlNamespaceManager]::new($wix.NameTable)
$namespace.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
$launchers = $wix.SelectNodes('//w:Shortcut[contains(@Target,"powershell.exe")]/@Target | //w:CustomAction[contains(@ExeCommand,"powershell.exe")]/@ExeCommand', $namespace)
if ($launchers.Count -ne 6) { throw 'Expected six server PowerShell launcher references.' }
foreach ($launcher in $launchers) {
    if (-not $launcher.Value.Contains('[System64Folder]') -or $launcher.Value.Contains('[SystemFolder]')) { throw 'Server x64 launcher must use System64Folder.' }
}
Write-Host 'PASS all six server MSI launchers use the 64-bit Windows system directory.'

$shortcutKey = $wix.SelectSingleNode('//w:Component[@Id="ServerShortcut"]/w:RegistryValue[@KeyPath="yes"]', $namespace)
if ($null -eq $shortcutKey -or $shortcutKey.Root -ne 'HKCU') { throw 'Non-advertised Start Menu shortcut requires an HKCU registry key path (ICE38/43/57).' }
if ($null -eq $wix.SelectSingleNode('//w:SetProperty[@Id="ARPINSTALLLOCATION"][@After="CostFinalize"]', $namespace)) { throw 'Install location must be resolved after directory costing.' }
Write-Host 'PASS shortcut registry scope and resolved install-location metadata.'

$rollback = $wix.SelectSingleNode('//w:CustomAction[@Id="RollbackResumeServices"]', $namespace)
if ($rollback.ExeCommand -notmatch '-Action RollbackResume$' -or $rollback.Execute -ne 'rollback') { throw 'Uninstall rollback must use the explicit schedule-restoring maintenance action.' }
Write-Host 'PASS uninstall rollback uses its dedicated restoration action.'

# COM methods may emit null to PowerShell's success stream. Only rows may escape
# the reader, including when the MSI view contains no records.
$smokeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-windows-installers.ps1'), [ref]$null, [ref]$null)
$reader = $smokeAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-MsiRows'}, $true)
$readerText = $reader.Extent.Text.Replace('[Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)', '$null').Replace('[Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)', '$null')
Invoke-Expression $readerText
$mockRecord = [pscustomobject]@{Values=@('ProductName','SBCO Server')}
$mockRecord | Add-Member ScriptMethod StringData {param($index) $this.Values[$index-1]}
$mockView = [pscustomobject]@{Record=$mockRecord;Fetched=$false}
$mockView | Add-Member ScriptMethod Execute {return $null}
$mockView | Add-Member ScriptMethod Close {return $null}
$mockView | Add-Member ScriptMethod Fetch {if(-not $this.Fetched){$this.Fetched=$true;return $this.Record};return $null}
$mockDatabase = [pscustomobject]@{View=$mockView}
$mockDatabase | Add-Member ScriptMethod OpenView {param($sql) $this.View}
$rows = @(Read-MsiRows $mockDatabase 'SELECT fixture' 2)
if ($rows.Count -ne 1 -or $rows[0][0] -cne 'ProductName' -or $rows[0][1] -cne 'SBCO Server') { throw 'MSI reader leaked COM method output into rows.' }
if (@(Read-MsiRows $mockDatabase 'SELECT empty' 2).Count -ne 0) { throw 'Empty MSI view emitted a null record.' }
Write-Host 'PASS MSI row reader suppresses COM method output and preserves row arrays.'
