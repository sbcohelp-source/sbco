#requires -Version 7.2
# Portable checks of the actual smoke helpers; no MSI, services, GUI or office data.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert([bool]$Condition,[string]$Message) { if(-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Operation,[string]$Message) { $failed=$false;try { & $Operation | Out-Null } catch { $failed=$true };Assert $failed $Message }
$source=Join-Path $PSScriptRoot 'test-windows-standalone-installer.ps1'
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Smoke script does not parse.'
foreach($name in @('Get-VerifiedMsi','Assert-StandaloneIdentity','Assert-FixtureRetention','Remove-OwnedFixtures')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Assert ($null -ne $definition) "Missing helper $name"
    Invoke-Expression $definition.Extent.Text
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sbco-standalone-guards-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($fixture)|Out-Null
    $package=Join-Path $fixture 'SBCO_0.1.0_x64_en-US.msi'
    [IO.File]::WriteAllText($package,'synthetic MSI bytes; never execute')
    $hash=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    $manifest=$package+'.sha256'
    [IO.File]::WriteAllText($manifest, "$hash  $([IO.Path]::GetFileName($package))")
    $verified=Get-VerifiedMsi $fixture
    Assert ($verified.path -ceq $package -and $verified.sha256 -ceq $hash) 'Valid checksum was rejected.'
    [IO.File]::WriteAllText((Join-Path $fixture 'SBCO Client_0.1.0_x64_en-US.msi'),'unrelated cached client')
    $verified=Get-VerifiedMsi $fixture
    Assert ($verified.path -ceq $package -and $verified.excluded_msi_files.Count -eq 1) 'Cached client must be excluded, not selected.'
    [IO.File]::WriteAllText($manifest,"$hash  different.msi")
    Refuses { Get-VerifiedMsi $fixture } 'Wrong manifest filename accepted.'
    [IO.File]::WriteAllText($manifest,(('0'*64)+"  $([IO.Path]::GetFileName($package))"))
    Refuses { Get-VerifiedMsi $fixture } 'Checksum mismatch accepted.'
    [IO.File]::WriteAllText($manifest,"$hash  $([IO.Path]::GetFileName($package))")
    $extra=Join-Path $fixture 'SBCO_0.2.0_x64_en-US.msi';[IO.File]::WriteAllText($extra,'ambiguous')
    Refuses { Get-VerifiedMsi $fixture } 'Ambiguous standalone package accepted.'
    Remove-Item -LiteralPath $extra,$package
    Refuses { Get-VerifiedMsi $fixture } 'Client-only directory accepted as standalone.'
    $identity=@{ProductName='SBCO';Manufacturer='S K Singh';ProductCode='{182fa928-2583-449b-9331-52ecae2be098}';UpgradeCode='{b8dc76d1-374a-4f76-95e8-db387b715bcf}'}
    Assert-StandaloneIdentity $identity 'x64;1033'
    foreach($change in @(@('ProductName','SBCO Client'),@('Manufacturer','Other publisher'),@('UpgradeCode','d599863f-574d-46f4-bebf-3609e933a7e1'),@('ProductCode',[guid]::Empty.ToString()))) {
        $copy=$identity.Clone();$copy[$change[0]]=$change[1]
        Refuses { Assert-StandaloneIdentity $copy 'x64;1033' } 'Foreign/invalid product identity accepted.'
    }
    Refuses { Assert-StandaloneIdentity $identity 'Intel;1033' } 'Non-x64 package accepted.'
    Write-Host 'PASS exact standalone selection, checksum binding, ambiguity/client-only refusal and standalone product identity.'
    $markerValue='EPHEMERAL portable test token'
    $markers=[Collections.Generic.List[string]]::new();$createdDirectories=[Collections.Generic.List[string]]::new()
    $data=Join-Path $fixture 'data';[IO.Directory]::CreateDirectory($data)|Out-Null;$createdDirectories.Add($data)
    foreach($name in @('owned.txt','modified.txt')) { $path=Join-Path $data $name;[IO.File]::WriteAllText($path,$markerValue);$markers.Add($path) }
    Assert-FixtureRetention
    [IO.File]::WriteAllText($markers[1],'changed data must survive cleanup')
    $foreign=Join-Path $data 'untracked.txt';[IO.File]::WriteAllText($foreign,'not a fixture marker')
    Refuses { Assert-FixtureRetention } 'Changed data marker was not detected.'
    Remove-OwnedFixtures
    Assert (-not (Test-Path -LiteralPath $markers[0])) 'Exact owned marker was not removed.'
    Assert ((Test-Path -LiteralPath $markers[1]) -and (Test-Path -LiteralPath $foreign) -and (Test-Path -LiteralPath $data)) 'Cleanup deleted unowned/changed data.'
    $empty=Join-Path $fixture 'empty';[IO.Directory]::CreateDirectory($empty)|Out-Null;$createdDirectories.Add($empty)
    Remove-OwnedFixtures
    Assert (-not (Test-Path -LiteralPath $empty)) 'Owned empty directory was not removed.'
    Write-Host 'PASS marker retention detection and cleanup preserving changed/untracked files.'
    if (-not $IsWindows) {
        $guardedLogs=Join-Path $fixture 'must-not-be-created'
        $message=$null
        try { & $source -ArtifactDirectory $fixture -LogDirectory $guardedLogs } catch { $message=$_.Exception.Message }
        Assert ($message -like '*ephemeral GitHub-hosted Windows x64*' -and -not (Test-Path -LiteralPath $guardedLogs)) 'Platform guard failed before side effects.'
        Write-Host 'PASS non-Windows refusal before filesystem/install side effects.'
    }
} finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
