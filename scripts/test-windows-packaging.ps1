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

# Exercise the actual guided-setup prompt wrapper through a separate child script.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-windows-server-runtime.ps1'),[ref]$null,[ref]$null)
$wrapper=$ast.Find({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('function Read-Host')},$true).Value
$root=Join-Path ([IO.Path]::GetTempPath()) ('sbco-wrapper-'+[guid]::NewGuid().ToString('N'))
try{
 [IO.Directory]::CreateDirectory((Join-Path $root 'server'))|Out-Null
 [IO.File]::WriteAllText((Join-Path $root 'wrapper.ps1'),$wrapper)
 @{install=$root;certificate='fixture-cert';key='fixture-key';password='fixture-secret'}|ConvertTo-Json|Set-Content (Join-Path $root 'answers.json')
 [IO.File]::WriteAllText((Join-Path $root 'server/Configure-Server.ps1'),@'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Read-Host 'HTTPS server hostname (must resolve to this computer and match your certificate)') -cne 'localhost'){throw 'Hostname mismatch'}
if((Read-Host 'Full path to the PEM certificate chain') -cne 'fixture-cert'){throw 'Certificate mismatch'}
$password=Read-Host 'First administrator password (at least 12 characters)' -AsSecureString
if($password -isnot [Security.SecureString]){throw 'Not a secure string'}
$password.Dispose()
try{Read-Host 'unknown';throw 'Guard failed'}catch{if($_.Exception.Message -notlike 'Unexpected guided setup prompt*'){throw}}
Write-Host 'PASS actual wrapper answers inherited by child setup script; secure password and unknown-prompt refusal.'
'@)
 & (Join-Path $root 'wrapper.ps1')
 [IO.File]::WriteAllText((Join-Path $root 'server/Configure-Server.ps1'),'exit 17')
 $global:LASTEXITCODE=0
 & (Join-Path $root 'wrapper.ps1')
 if($LASTEXITCODE -ne 17){throw 'Guided setup failure exit code was swallowed.'}
 $global:LASTEXITCODE=0
 Write-Host 'PASS guided setup wrapper propagates child failure exit codes.'
}finally{if(Test-Path $root){Remove-Item $root -Recurse -Force}}

# Invoke-RestMethod emits a JSON array as one pipeline object. Exercise the actual
# polling expression so property filtering cannot accidentally inspect the array.
& {
 $call=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Call-Server'},$true)
 Invoke-Expression $call.Extent.Text
 $poll=$ast.Find({param($node)$node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $node.Extent.Text.StartsWith('{$script:batch=')},$true).ScriptBlock.GetScriptBlock()
 $script:session=[Microsoft.PowerShell.Commands.WebRequestSession]::new()
 $import=[pscustomobject]@{id='fixture-import'}
 $script:fixtureImportStatus='Queued'
 function Invoke-RestMethod {
  Write-Output -NoEnumerate @([pscustomobject]@{id='other-import';status='Completed'},[pscustomobject]@{id='fixture-import';status=$script:fixtureImportStatus;inserted=2})
 }
 try {
  if(& $poll){throw 'Queued import must not be considered complete.'}
  $script:fixtureImportStatus='Completed'
  if(-not (& $poll) -or $script:batch.id -cne 'fixture-import' -or $script:batch.inserted -ne 2){throw 'Completed import array response was not selected correctly.'}
  $script:fixtureImportStatus='Failed'
  if(-not (& $poll) -or $script:batch.status -cne 'Failed'){throw 'Failed import must terminate polling.'}
  Write-Host 'PASS actual import polling handles non-enumerated JSON arrays and all terminal states.'
  function Invoke-RestMethod {
   $response=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
   $response.Content=[Net.Http.StringContent]::new('fixture-response-secret')
   throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('fixture-error-secret',$response)
  }
  try{Call-Server 'query' @{kind='report';password='fixture-request-secret'};throw 'Expected HTTP refusal.'}catch{
   if($_.Exception.Message -cne 'HTTPS application check failed: query kind=report HTTP=403'){throw 'HTTP diagnostic must contain only path/kind/status and no bodies.'}
  }
  Write-Host 'PASS HTTP failure diagnostics retain status and kind without request/response secrets.'
  function Invoke-RestMethod {
   param($WebSession,$Headers)
   foreach($key in $Headers.Keys){$WebSession.Headers[$key]=$Headers[$key]}
   if($WebSession.Headers.ContainsKey('X-SBCO-Training')){return 'training'}
   return 'live'
  }
  if((Call-Server 'me' $null @{'X-SBCO-Training'='fixture-generation'}) -cne 'training'){throw 'Training request lost explicit context.'}
  if((Call-Server 'training/reset' @{generation='fixture-generation';confirmation='DELETE TRAINING'}) -cne 'live'){throw 'Reset leaked previous training context.'}
  if((Call-Server 'query' @{kind='report'}) -cne 'live'){throw 'Live query retained stale training context.'}
  Write-Host 'PASS training/reset/live transitions clear persisted context while retaining the session.'

 } finally { Remove-Variable fixtureImportStatus,batch -Scope Script -ErrorAction SilentlyContinue }
}

# Shared Rust bundle caches can contain other products and older versions.
& {
 $buildAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build-windows-msi.ps1'),[ref]$null,[ref]$null)
 foreach($name in @('Get-FreshStandaloneInstaller','Assert-StandaloneOutput')){
  $definition=$buildAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
  Invoke-Expression $definition.Extent.Text
 }
 $fixture=Join-Path ([IO.Path]::GetTempPath()) ('sbco-msi-selection-'+[guid]::NewGuid().ToString('N'))
 try {
  [IO.Directory]::CreateDirectory($fixture)|Out-Null
  $expected='SBCO_0.1.0_x64_en-US.msi';$started=[DateTime]::UtcNow.AddMinutes(-1)
  foreach($name in @($expected,'SBCO Client_0.1.0_x64_en-US.msi','SBCO_0.0.9_x64_en-US.msi')){[IO.File]::WriteAllText((Join-Path $fixture $name),'fixture')}
  [IO.File]::SetLastWriteTimeUtc((Join-Path $fixture $expected),$started.AddDays(-1))
  try{Get-FreshStandaloneInstaller $fixture $started $expected;throw 'Stale installer unexpectedly selected.'}catch{if($_.Exception.Message -notlike 'Build did not produce the expected fresh standalone MSI*'){throw}}
  [IO.File]::SetLastWriteTimeUtc((Join-Path $fixture $expected),[DateTime]::UtcNow)
  $selected=@(Get-FreshStandaloneInstaller $fixture $started $expected)
  if($selected.Count -ne 1 -or $selected[0].Name -cne $expected){throw 'Bundle cache contaminated standalone selection.'}
  try{Assert-StandaloneOutput $fixture $expected;throw 'Mixed output unexpectedly accepted.'}catch{if($_.Exception.Message -notlike 'Output directory contains another installer*'){throw}}
  Remove-Item -LiteralPath (Join-Path $fixture 'SBCO Client_0.1.0_x64_en-US.msi'),(Join-Path $fixture 'SBCO_0.0.9_x64_en-US.msi')
  [IO.File]::WriteAllText((Join-Path $fixture 'SBCO Client_0.1.0_x64_en-US.msi.sha256'),'fixture')
  try{Assert-StandaloneOutput $fixture $expected;throw 'Foreign sidecar unexpectedly accepted.'}catch{if($_.Exception.Message -notlike 'Output directory contains another installer*'){throw}}
  Remove-Item -LiteralPath (Join-Path $fixture 'SBCO Client_0.1.0_x64_en-US.msi.sha256')
  Assert-StandaloneOutput $fixture $expected
  Write-Host 'PASS standalone artifact selection rejects stale/cross-product cache entries and mixed output directories.'
 }finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
}
