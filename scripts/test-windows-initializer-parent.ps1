# Portable flow checks: actual parent helper with only Windows service/ACL adapters mocked.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../deploy/windows/server/Configure-Server.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-PostgresDatabase'},$true)
if($null -eq $helper){throw 'Initialization helper missing.'}
Invoke-Expression $helper.Extent.Text
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sbco-init-parent-'+[guid]::NewGuid().ToString('N'))
$oldSystemRoot=$env:SystemRoot
$events=[Collections.Generic.List[string]]::new()
function Write-Utf8([string]$Path,[string]$Value){[IO.File]::WriteAllText($Path,$Value)}
function Set-PrivateDirectory([string]$Path,[string[]]$ServiceSids,[string]$Access){[IO.Directory]::CreateDirectory($Path)|Out-Null}
function New-ServiceConfig { $events.Add('configure') }
function Install-NewService { $events.Add('install');return 'S-1-5-80-123' }
function Get-Service { return [pscustomobject]@{Status=$script:serviceState} }
function Wait-Condition([scriptblock]$Condition,[string]$Description,[int]$Seconds=90){if(-not (& $Condition)){throw "Simulated timeout: $Description"}}
function Invoke-Wrapper([string]$Name,[string]$Operation){
 $events.Add($Operation)
 if($Operation -eq 'stop'){$script:serviceState='Stopped';return}
 $script:serviceState='Running'
 $file=@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'database') -Filter 'init-configuration-*.json' -File)
 if($file.Count -ne 1){throw 'Expected one fresh private initializer config.'}
 $config=Get-Content -LiteralPath $file[0].FullName -Raw|ConvertFrom-Json
 if($mode -eq 'missing'){return}
 $result=@{format=1;nonce=$config.nonce;exit_code=0}
 if($mode -eq 'stale'){$result.nonce='0'*32}
 if($mode -eq 'failed'){$result.exit_code=23}
 if($mode -eq 'success'){
  [IO.Directory]::CreateDirectory((Join-Path $pgData 'global'))|Out-Null
  Write-Utf8 (Join-Path $pgData 'PG_VERSION') '18'
  Write-Utf8 (Join-Path $pgData 'global/pg_control') 'fixture'
 }
 Write-Utf8 $config.result_path ($result|ConvertTo-Json)
 if((Get-Content -LiteralPath $config.result_path -Raw|ConvertFrom-Json).exit_code -isnot [long]){throw 'Test requires real JSON Int64 roundtrip.'}
}
try{
 $env:SystemRoot=Join-Path $fixture 'windows'
 $InstallRoot=Join-Path $fixture 'install'
 [IO.Directory]::CreateDirectory((Join-Path $InstallRoot 'server'))|Out-Null
 Write-Utf8 (Join-Path $InstallRoot 'server/Initialize-Postgres.ps1') 'fixture'
 foreach($mode in @('success','stale','failed','missing')){
  $DataRoot=Join-Path $fixture $mode
  [IO.Directory]::CreateDirectory((Join-Path $DataRoot 'database'))|Out-Null
  $pgData=Join-Path $DataRoot 'database/cluster';$pgBin=Join-Path $InstallRoot 'postgres/bin';$passwordFile=Join-Path $DataRoot 'database/init-password'
  Write-Utf8 $passwordFile 'private-fixture'
  $events.Clear();$script:serviceState='Stopped';$failure=$null
  try{$sid=Initialize-PostgresDatabase $pgBin $pgData $passwordFile}catch{$failure=$_.Exception.Message}
  if($events[-1] -cne 'stop' -or $script:serviceState -cne 'Stopped'){throw 'Initializer must stop explicitly even on a bad/missing completion marker.'}
  if($mode -eq 'success'){
   if($failure -or $sid -cne 'S-1-5-80-123'){throw "Successful JSON result rejected: $failure"}
   if(@(Get-ChildItem (Join-Path $DataRoot 'database') -Filter 'init-*.json').Count -ne 0){throw 'Successful temporary initialization markers remained.'}
   $events.Clear()
   try{Initialize-PostgresDatabase $pgBin $pgData $passwordFile;throw 'Reinitialization accepted'}catch{if($_.Exception.Message -notlike 'Existing PostgreSQL cluster*'){throw}}
   if($events.Count){throw 'Existing cluster was touched before refusal.'}
  }elseif(-not $failure){throw "Invalid initializer result accepted: $mode"}
 }
 Write-Host 'PASS parent initialization: real JSON Int64 success, explicit stop, stale/failure/timeout rejection and existing-cluster preservation.'
}finally{$env:SystemRoot=$oldSystemRoot;if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
