#requires -Version 7.2
# Uses real pg_dump and a deliberately closed loopback port; never opens an office database.
param([Parameter(Mandatory=$true)][string]$PgDumpPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../deploy/windows/server/Backup-Common.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw($errors|Out-String)}
foreach($name in @('Get-BackupConnectionEnvironment','Set-BackupProcessEnvironment')){
    $helper=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if($null -eq $helper){throw 'Production connection environment helper missing.'}
    Invoke-Expression $helper.Extent.Text
}
$pgDump=(Resolve-Path -LiteralPath $PgDumpPath).Path
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('sbco-libpq-'+[guid]::NewGuid().ToString('N')+'.dump')
$keys=@('PGHOST','PGHOSTADDR','PGPORT','PGUSER','PGPASSWORD','PGDATABASE','PGSERVICE','PGCONNECT_TIMEOUT')
$previous=@{};foreach($key in $keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key)}
try{
    $env:PGHOST='invalid.example';$env:PGHOSTADDR='192.0.2.1';$env:PGPORT='5432';$env:PGSERVICE='must-not-be-used'
    $connection=Get-BackupConnectionEnvironment ([uri]'postgresql://probe:fixture%3A%40%25@127.0.0.1:1/probe')
    Set-BackupProcessEnvironment $connection
    $env:PGCONNECT_TIMEOUT='2'
    if($env:PGPASSWORD -cne 'fixture:@%'){throw 'Encoded password was not decoded.'}
    $ErrorActionPreference='Continue'
    $output=(& $pgDump --no-password --format=custom --file=$temporary 2>&1 | Out-String)
    $code=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if($code -eq 0){throw 'Expected closed-port connection failure.'}
    if($output -notmatch '127\.0\.0\.1' -or $output -notmatch 'port 1\b' -or $output -match '5432|192\.0\.2\.1|must-not-be-used'){
        throw 'Native pg_dump did not use the intended isolated endpoint.'
    }
    Write-Host 'PASS real pg_dump uses URI-derived loopback port1, decoded environment credentials, and ignores poisoned ambient hostaddr/service without credentials in argv.'
}finally{
    Set-BackupProcessEnvironment $previous
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
}
