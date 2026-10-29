#requires -Version 7.2
# Portable initializer flow tests; no real cluster, Windows service or credentials.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Refuses([scriptblock]$Operation,[string]$Message){$rejected=$false;try{& $Operation | Out-Null}catch{$rejected=$true};Assert $rejected $Message}
$source=Join-Path $PSScriptRoot '../deploy/windows/server/Initialize-Postgres.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Initializer does not parse'
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $function.Extent.Text}
# Exercise the real native invocation adapter with a tiny child PowerShell process.
foreach($code in @(0,23)) {
    $nativeLog=Join-Path ([IO.Path]::GetTempPath()) ('sbco-init-native-'+[guid]::NewGuid().ToString('N')+'.log')
    try {
        $actual=Invoke-PackagedInitdb ([Environment]::ProcessPath) @('-NoProfile','-Command',('[Console]::Error.WriteLine("fixture diagnostic"); exit '+$code)) $nativeLog
        Assert ($actual -eq $code) 'Native stderr changed the actual exit code'
        Assert ((Get-Content -LiteralPath $nativeLog -Raw) -match 'fixture diagnostic') 'Native diagnostics were discarded'
    } finally {if(Test-Path -LiteralPath $nativeLog){Remove-Item -LiteralPath $nativeLog}}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sbco-init-test-'+[guid]::NewGuid().ToString('N'))
try{
    $script:InstallRoot=Join-Path $root 'install';$script:DataRoot=Join-Path $root 'data'
    $databaseRoot=Join-Path $DataRoot 'database';$cluster=Join-Path $databaseRoot 'cluster'
    foreach($path in @($databaseRoot,(Join-Path $InstallRoot 'postgres/bin'),(Join-Path $InstallRoot 'postgres/share'))){[IO.Directory]::CreateDirectory($path)|Out-Null}
    $password=Join-Path $databaseRoot 'init-password';Set-Content -LiteralPath $password -Value 'private-fixture-file'
    $ConfigurationPath=Join-Path $databaseRoot 'init-config.json'
    $script:mode='success';$script:calls=0
    function New-Configuration {
        $nonce=[guid]::NewGuid().ToString('N')
        $script:config=@{format=1;nonce=$nonce;executable=(Join-Path $InstallRoot 'postgres\bin\initdb.exe');result_path=(Join-Path $databaseRoot "init-result-$nonce.json");arguments=@('-D',$cluster,'-L',(Join-Path $InstallRoot 'postgres\share'),'-U','sbco','--auth=scram-sha-256','--encoding=UTF8','--locale-provider=builtin','--builtin-locale=C.UTF-8',('--pwfile='+$password))}
        Save-Configuration
    }
    function Save-Configuration {$config|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $ConfigurationPath}
    function Invoke-PackagedInitdb([string]$Executable,[string[]]$Arguments,[string]$LogPath){
        $script:calls++
        Assert (-not (Test-Path -LiteralPath $config.result_path)) 'Result published before initdb completed'
        Assert ($Executable -ceq $config.executable) 'Unexpected executable'
        Assert ($Arguments -contains ('--pwfile='+$password)) 'Private password file argument lost'
        Assert ($LogPath -ceq (Join-Path $databaseRoot ('initdb-'+$config.nonce+'.log'))) 'Diagnostics path is not the nonce-specific protected file'
        if($script:mode -eq 'exception'){throw 'private native failure text'}
        if($script:mode -eq 'collision'){Set-Content -LiteralPath $config.result_path -Value 'preserve concurrent result'}
        if($script:mode -eq 'failure'){return 23}
        return 0
    }
    New-Configuration;Invoke-PostgresInitialization $ConfigurationPath
    $result=Get-Content -LiteralPath $config.result_path -Raw|ConvertFrom-Json
    Assert ($result.format -eq 1 -and $result.nonce -ceq $config.nonce -and $result.exit_code -eq 0) 'Success result mismatch'
    Assert (@(Get-ChildItem -LiteralPath $databaseRoot -Filter '*.partial-*').Count -eq 0) 'Partial publication remains'
    $before=$calls;Refuses {Invoke-PostgresInitialization $ConfigurationPath} 'Existing result was overwritten'
    Assert ($calls -eq $before) 'Existing result still executed initdb'
    foreach($failure in @('failure','exception')){
        New-Configuration;$script:mode=$failure;Invoke-PostgresInitialization $ConfigurationPath
        $text=Get-Content -LiteralPath $config.result_path -Raw;$result=$text|ConvertFrom-Json
        $expected=if($failure -eq 'failure'){23}else{1}
        Assert ($result.exit_code -eq $expected -and $result.nonce -ceq $config.nonce) 'Failure exit status/nonce not retained'
        Assert ($text -notmatch 'private|password|postgresql') 'Result leaked diagnostic or credential data'
    }
    foreach($sentinel in @('PG_VERSION','global/pg_control')){
        New-Configuration;$script:mode='success'
        $path=Join-Path $cluster $sentinel;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null;Set-Content -LiteralPath $path -Value 'preserved existing database'
        $before=$calls;Refuses {Invoke-PostgresInitialization $ConfigurationPath} 'Existing database initialization allowed'
        Assert ($calls -eq $before -and -not (Test-Path -LiteralPath $config.result_path)) 'Existing database protection invoked native process'
        Assert ((Get-Content -LiteralPath $path -Raw).Trim() -ceq 'preserved existing database') 'Existing database marker changed'
        Remove-Item -LiteralPath $path
    }
    New-Configuration;$config.nonce='invalid';Save-Configuration
    Refuses {Invoke-PostgresInitialization $ConfigurationPath} 'Invalid nonce accepted'
    New-Configuration;$config.result_path=Join-Path $databaseRoot 'init-result-foreign.json';Save-Configuration
    Refuses {Invoke-PostgresInitialization $ConfigurationPath} 'Foreign result accepted'
    New-Configuration;$config.arguments[1]=Join-Path $root 'other-cluster';Save-Configuration
    Refuses {Invoke-PostgresInitialization $ConfigurationPath} 'Foreign cluster accepted'
    New-Configuration;$config.arguments+=@('--pwfile=inline-secret');Save-Configuration
    Refuses {Invoke-PostgresInitialization $ConfigurationPath} 'Unsupported secret argument accepted'
    New-Configuration
    $foreignConfig=Join-Path $root 'foreign-config.json';Copy-Item -LiteralPath $ConfigurationPath -Destination $foreignConfig
    Refuses {Invoke-PostgresInitialization $foreignConfig} 'Foreign configuration directory accepted'
    New-Configuration;$script:mode='collision'
    Refuses {Invoke-PostgresInitialization $ConfigurationPath} 'Concurrent result overwrite allowed'
    Assert ((Get-Content -LiteralPath $config.result_path -Raw).Trim() -ceq 'preserve concurrent result') 'Concurrent result overwritten'
    Assert (@(Get-ChildItem -LiteralPath $databaseRoot -Filter '*.partial-*').Count -eq 0) 'Failed publication left partial file'
    # Execute the actual production try+wait statements with only sleep replaced.
    $entry=$ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}
    $wait=$ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.WhileStatementAst]}
    Assert (@($entry).Count -eq 1 -and @($wait).Count -eq 1) 'Expected production initialization and hold loop'
    $entryScript=[scriptblock]::Create($entry.Extent.Text+"`n"+$wait.Extent.Text)
    $script:held=$false
    function Start-Sleep([int]$Seconds){$script:held=$true;throw 'test-ended-hold-loop'}
    foreach($outcome in @('success','failure','exception')){
        New-Configuration;$script:mode=$outcome;$script:held=$false
        Refuses {& $entryScript} 'Production entry did not reach bounded test sleep'
        Assert ($held -and (Test-Path -LiteralPath $config.result_path)) 'Production entry exited instead of waiting for administrator stop'
    }
    Write-Host 'PASS initializer exit codes, fresh nonce, atomic publication, existing/foreign database refusal, private output, collision protection and service hold after success/failure.'
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
