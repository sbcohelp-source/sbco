#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ArtifactDirectory,[Parameter(Mandatory=$true)][string]$LogDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $env:RUNNER_TEMP) { throw 'Server rehearsal requires an ephemeral GitHub-hosted Windows x64 runner.' }
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevated disposable runner required.' }
$LogDirectory=[IO.Path]::GetFullPath($LogDirectory)
[IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
$installPath=Join-Path $env:ProgramFiles 'SBCO Server'
$dataPath=Join-Path $env:ProgramData 'SBCO Server'
$token=[guid]::NewGuid().ToString('N')
$privateRoot=Join-Path $env:RUNNER_TEMP "sbco-server-$token"
$installer=New-Object -ComObject WindowsInstaller.Installer
$productCode=$null; $msiStarted=$false; $timedOut=$false; $fixtureCreated=$false; $trustedThumbprint=$null; $certificate=$null; $rsa=$null; $adminPassword=$null; $session=$null
$serviceNames=@('SBCOPostgres','SBCOApi','SBCOWorker','SBCOWeb','SBCOHttps')
function Read-MsiProperty($Database,[string]$Property) {
    $view=$Database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Property'")
    try { $null=$view.Execute();$record=$view.Fetch();if($null -eq $record){throw "Missing MSI property $Property"};try{return $record.StringData(1)}finally{[Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)|Out-Null} }
    finally{$null=$view.Close();[Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)|Out-Null}
}
function Invoke-RehearsalMsi([string]$Operation,[string]$Target,[string]$Label) {
    $log=Join-Path $LogDirectory "$Label.log"
    $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList "$Operation `"$Target`" /qn /norestart REBOOT=ReallySuppress /L*v `"$log`"" -PassThru
    try { if(-not $process.WaitForExit(300000)){$script:timedOut=$true;$process.Kill();throw "MSI $Label timed out; no further MSI operations permitted."};if($process.ExitCode -notin @(0,3010)){throw "MSI $Label failed: $($process.ExitCode)"} }
    finally{$process.Dispose()}
}
function Invoke-PrivatePowerShell([string]$Script,[string]$Label,[int]$Seconds=600) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Script)){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($Seconds*1000)){$process.Kill($true);$process.WaitForExit();throw "$Label exceeded its bounded deadline."}
        [IO.File]::WriteAllText((Join-Path $privateRoot "$Label.log"),($stdout.Result+"`n"+$stderr.Result))
        if($process.ExitCode -ne 0){throw "$Label failed with exit $($process.ExitCode); see sanitized diagnostics."}
    } finally{$process.Dispose()}
}
function Call-Server([string]$Path,$Body=$null,[hashtable]$ExtraHeaders=@{}) {
    $headers=@{'X-SBCO-Request'='1'};foreach($key in $ExtraHeaders.Keys){$headers[$key]=$ExtraHeaders[$key]}
    $options=@{Uri="https://localhost/api/v1/$Path";WebSession=$script:session;Headers=$headers;TimeoutSec=90;ErrorAction='Stop'}
    if($null -ne $Body){$options.Method='Post';$options.ContentType='application/json';$options.Body=($Body|ConvertTo-Json -Depth 15 -Compress)}
    try { Invoke-RestMethod @options } catch { throw "HTTPS application check failed: $Path" }
}
function Command-Server($Command) { Call-Server 'command' @{request_id=[guid]::NewGuid().ToString();command=$Command} }
function Assert-ServicesReady {
    foreach($name in $serviceNames){if((Get-Service -Name $name).Status -ne 'Running'){throw "Required service is not running: $name"}}
    if((Call-Server 'server-info').application -cne 'SBCO'){throw 'HTTPS compatibility endpoint failed.'}
    if((Invoke-WebRequest -Uri 'https://localhost/' -TimeoutSec 30).StatusCode -ne 200){throw 'Next.js HTTPS page failed.'}
}
function Save-SafeDiagnostics {
    $secrets=[Collections.Generic.List[string]]::new()
    if($adminPassword){$secrets.Add($adminPassword)}
    # Inspect credentials privately solely to redact them; never collect configuration XML.
    $apiXml=Join-Path $dataPath 'services\SBCOApi\SBCOApi.xml'
    if($fixtureCreated -and (Test-Path -LiteralPath $apiXml)){
        try{[xml]$xml=Get-Content -LiteralPath $apiXml -Raw;foreach($value in @($xml.service.env)){if($value.name -eq 'DATABASE_URL'){$uri=[uri]$value.value;if($uri.UserInfo.Contains(':')){$secrets.Add($uri.UserInfo.Split(':',2)[1])}}}}catch{}
    }
    $files=@()
    if(Test-Path -LiteralPath $privateRoot){$files+=@(Get-ChildItem -LiteralPath $privateRoot -Filter '*.log' -File)}
    if($fixtureCreated -and (Test-Path -LiteralPath (Join-Path $dataPath 'logs'))){$files+=@(Get-ChildItem -LiteralPath (Join-Path $dataPath 'logs') -Filter '*.log' -File -Recurse)}
    $index=0
    foreach($file in $files){
        $text=(Get-Content -LiteralPath $file.FullName -Tail 1000) -join "`n"
        foreach($secret in $secrets){$text=$text.Replace($secret,'[REDACTED]')}
        $text=[regex]::Replace($text,'postgresql://[^@\s]+@','postgresql://[REDACTED]@')
        $text=[regex]::Replace($text,'(?i)(sbco_session=)[^;\s]+','$1[REDACTED]')
        $text|Set-Content -LiteralPath (Join-Path $LogDirectory ("diagnostic-$index-"+$file.Name)) -Encoding utf8NoBOM
        $index++
    }
}
try {
    # All refusals occur before installation, certificate trust, or fixture creation.
    foreach($path in @($installPath,$dataPath,(Join-Path $env:ProgramFiles 'SBCO Client'))){if(Test-Path -LiteralPath $path){throw 'Existing SBCO installation or data refused.'}}
    if(Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue){throw 'Existing SBCO services refused.'}
    if(Get-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\' -ErrorAction SilentlyContinue){throw 'Existing SBCO backup task refused.'}
    if(Get-NetFirewallRule -Name 'SBCO-HTTPS-443' -ErrorAction SilentlyContinue){throw 'Existing SBCO firewall rule refused.'}
    foreach($port in @(55439,8091,3091,443)){if(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue){throw "Required fixture port $port is occupied."}}
    foreach($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')){if(Test-Path $root){foreach($entry in Get-ChildItem $root){if($entry.GetValue('DisplayName',$null) -like 'SBCO*'){throw 'Existing SBCO registered product refused.'}}}}
    $files=@(Get-ChildItem -LiteralPath $ArtifactDirectory -Filter '*.msi' -File);if($files.Count -ne 1){throw 'Exactly one server MSI required.'};$msi=$files[0]
    $checksum=(Get-Content -LiteralPath ($msi.FullName+'.sha256') -Raw).Trim()
    if($checksum -notmatch '^([a-fA-F0-9]{64})  (.+)$' -or $Matches[2] -cne $msi.Name){throw 'Invalid exact-filename checksum manifest.'};$expectedHash=$Matches[1]
    if((Get-FileHash -LiteralPath $msi.FullName -Algorithm SHA256).Hash -ine $expectedHash){throw 'Server MSI checksum mismatch.'}
    $database=$installer.OpenDatabase($msi.FullName,0)
    try{
        $productCode=Read-MsiProperty $database 'ProductCode'
        if((Read-MsiProperty $database 'ProductName') -cne 'SBCO Server' -or (Read-MsiProperty $database 'Manufacturer') -cne 'S K Singh' -or [guid](Read-MsiProperty $database 'UpgradeCode') -ne [guid]'126a311d-74cf-4427-9422-12b3182ea43e'){throw 'Unexpected server MSI identity.'}
        if($installer.ProductState($productCode) -ne -1){throw 'Server product already registered.'}
    }finally{[Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)|Out-Null}
    $msiStarted=$true;Invoke-RehearsalMsi '/i' $msi.FullName 'server-install'
    . (Join-Path $installPath 'server\Server-Common.ps1')
    Set-PrivateDirectory $privateRoot
    $adminPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $rsa=[Security.Cryptography.RSA]::Create(2048)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=localhost',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName('localhost');$request.CertificateExtensions.Add($san.Build())
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $eku=[Security.Cryptography.OidCollection]::new();$null=$eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'));$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$false))
    $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddHours(2))
    $certPath=Join-Path $privateRoot 'certificate.pem';$keyPath=Join-Path $privateRoot 'private-key.pem'
    Write-Utf8 $certPath ($certificate.ExportCertificatePem());Write-Utf8 $keyPath ($rsa.ExportPkcs8PrivateKeyPem())
    $certBytes=$certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine')
    try{$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);if($store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$certificate.Thumbprint,$false).Count){throw 'Generated certificate unexpectedly already trusted.'};$store.Add([Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes));$trustedThumbprint=$certificate.Thumbprint}finally{$store.Close()}
    Write-Utf8 (Join-Path $privateRoot 'answers.json') (@{install=$installPath;certificate=$certPath;key=$keyPath;password=$adminPassword}|ConvertTo-Json)
    $wrapper=Join-Path $privateRoot 'configure-fixture.ps1'
    Write-Utf8 $wrapper @'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fixtureAnswers=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'answers.json') -Raw|ConvertFrom-Json
function Read-Host([string]$Prompt,[switch]$AsSecureString){
    switch -Exact ($Prompt){
        'HTTPS server hostname (must resolve to this computer and match your certificate)' {return 'localhost'}
        'Full path to the PEM certificate chain' {return $fixtureAnswers.certificate}
        'Full path to its unencrypted PEM private key' {return $fixtureAnswers.key}
        'First SBCO administrator full name' {return 'Disposable Windows Rehearsal'}
        'First SBCO administrator email' {return 'windows-rehearsal@example.test'}
        'First administrator password (at least 12 characters)' {if(-not $AsSecureString){throw 'Password prompt must remain secure.'};return (ConvertTo-SecureString $fixtureAnswers.password -AsPlainText -Force)}
        'Repeat administrator password' {if(-not $AsSecureString){throw 'Password confirmation must remain secure.'};return (ConvertTo-SecureString $fixtureAnswers.password -AsPlainText -Force)}
        'Allow office computers to reach HTTPS TCP 443 on Private/Domain networks? [Y/n]' {return 'n'}
        'Enable daily backups at 02:00 and retain the latest 14 successful backups? [y/N]' {return 'n'}
        'Press Enter to close' {return ''}
        default {throw 'Unexpected guided setup prompt; fixture must be reviewed.'}
    }
}
& (Join-Path $fixtureAnswers.install 'server\Configure-Server.ps1')
'@
    $setupStarted=[DateTime]::UtcNow
    try{Invoke-PrivatePowerShell $wrapper 'guided-setup' 600}
    finally{
        # The preflight proved no data existed. Mark only this setup's newly created owned root.
        $ownership=Join-Path $dataPath 'ownership.json'
        if(Test-Path -LiteralPath $ownership){$owned=Get-Content -LiteralPath $ownership -Raw|ConvertFrom-Json;if($owned.format -eq 1 -and $owned.install_root -ceq $installPath -and [DateTime]$owned.created_at -ge $setupStarted.AddSeconds(-2)){$owned|Add-Member -NotePropertyName test_token -NotePropertyValue $token -Force;Write-Utf8 $ownership ($owned|ConvertTo-Json);$fixtureCreated=$true}}
    }
    if(-not $fixtureCreated -or -not (Get-Content -LiteralPath (Join-Path $dataPath 'configured.json') -Raw|ConvertFrom-Json).ready){throw 'Guided setup did not reach a durable ready state.'}
    $script:session=[Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $null=Call-Server 'login' @{email='windows-rehearsal@example.test';password=$adminPassword}
    if((Call-Server 'me').role -cne 'Administrator'){throw 'HTTPS sign-in did not return the fixture administrator.'}
    $cookies=@($session.Cookies.GetCookies([uri]'https://localhost/')|Where-Object Name -eq 'sbco_session')
    if($cookies.Count -ne 1 -or -not $cookies[0].Secure -or -not $cookies[0].HttpOnly){throw 'HTTPS session cookie flags failed.'}
    Assert-ServicesReady
    $templatePath=Join-Path $privateRoot 'setup-template.xlsx'
    Invoke-WebRequest -Uri 'https://localhost/templates/SBCO_Setup_Template.xlsx' -WebSession $session -OutFile $templatePath -TimeoutSec 30
    $archive=[IO.Compression.ZipFile]::OpenRead($templatePath);try{if($null -eq $archive.GetEntry('xl/workbook.xml')){throw 'Downloaded setup template is not an XLSX workbook.'}}finally{$archive.Dispose()}
    $null=Command-Server @{kind='save_office';id='WIN-SMOKE';name='Disposable Windows SO';office_type='SO';parent_id=$null}
    # Reuse the existing workbook generator; no application passwords are passed to Python.
    $content=& python -c "import sys,base64;sys.path.insert(0,'tests');import integration;print(base64.b64encode(integration.workbook('WIN-SMOKE',count=2)).decode())"
    if($LASTEXITCODE -ne 0){throw 'Existing workbook fixture generator failed.'}
    $import=Command-Server @{kind='import';filename='windows-rehearsal.xlsx';content_base64=[string]$content}
    Wait-Condition {$script:batch=@(Call-Server 'query' @{kind='imports'}|Where-Object id -eq $import.id)[0];$script:batch.status -in @('Completed','Failed')} 'Windows worker import' 120
    if($batch.status -cne 'Completed' -or $batch.inserted -ne 2){throw 'Windows worker did not import both fixture transactions.'}
    $filter=@{office='WIN-SMOKE';status=$null;search=$null;from_date=$null;to_date=$null;queue='all'}
    $report=Call-Server 'query' @{kind='report';report='Transactions';filter=$filter}
    if($report.totals.total -ne 2){throw 'Live fixture report total mismatch.'}
    $pdfPath=Join-Path $privateRoot 'report.pdf'
    Invoke-WebRequest -Uri 'https://localhost/api/v1/export' -Method Post -ContentType 'application/json' -Headers @{'X-SBCO-Request'='1'} -WebSession $session -Body (@{report='Transactions';filter=$filter;letter_id=$null}|ConvertTo-Json) -OutFile $pdfPath -TimeoutSec 90
    if([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($pdfPath),0,5) -cne '%PDF-'){throw 'Windows PDF export failed.'}
    $training=Call-Server 'training/enable' @{}
    if(-not $training.available -or $training.counts.transactions -ne 24){throw 'Training workspace seeding failed.'}
    $trainingHeaders=@{'X-SBCO-Training'=(@{generation=$training.generation;role='Pa'}|ConvertTo-Json -Compress)}
    if((Call-Server 'me' $null $trainingHeaders).role -cne 'Pa'){throw 'Training role switching failed.'}
    $null=Call-Server 'training/reset' @{generation=$training.generation;confirmation='DELETE TRAINING'}
    if((Call-Server 'training').available -or (Call-Server 'query' @{kind='report';report='Transactions';filter=$filter}).totals.total -ne 2){throw 'Training reset affected live fixture records.'}
    # Exercise actual maintenance under Windows PowerShell5.1, then MSI repair.
    $maintenance=Join-Path $privateRoot 'maintenance.ps1'
    Write-Utf8 $maintenance ("`$ErrorActionPreference='Stop'`n& "+"'"+(Join-Path $installPath 'server\Manage-Services.ps1').Replace("'","''")+"' -Action Stop`n& '"+(Join-Path $installPath 'server\Manage-Services.ps1').Replace("'","''")+"' -Action Resume")
    Invoke-PrivatePowerShell $maintenance 'service-restart' 300
    Assert-ServicesReady
    Invoke-RehearsalMsi '/fa' $msi.FullName 'configured-server-repair'
    Assert-ServicesReady
    if((Call-Server 'query' @{kind='report';report='Transactions';filter=$filter}).totals.total -ne 2){throw 'Restart/repair lost fixture records.'}
    Invoke-RehearsalMsi '/x' $productCode 'configured-server-uninstall'
    if(Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue){throw 'Uninstall retained a server service.'}
    if(-not (Test-Path -LiteralPath (Join-Path $dataPath 'database\cluster\global\pg_control')) -or (Get-Content -LiteralPath (Join-Path $dataPath 'ownership.json') -Raw|ConvertFrom-Json).test_token -cne $token){throw 'Uninstall did not preserve fixture database ownership.'}
    @{result='passed';scope='disposable Windows2025 shared server';source_msi_sha256=$expectedHash;real_guided_setup=$true;services=5;trusted_https=$true;secure_login=$true;template=$true;worker_import_rows=2;pdf=$true;training_reset_isolated=$true;restart_and_repair=$true;uninstall_preserves_database=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $LogDirectory 'server-rehearsal.json')
}catch{
    $failure=$_.Exception.Message
    if($adminPassword){$failure=$failure.Replace($adminPassword,'[REDACTED]')}
    $failure=[regex]::Replace($failure,'postgresql://[^@\s]+@','postgresql://[REDACTED]@')
    $failure|Set-Content -LiteralPath (Join-Path $LogDirectory 'failure.txt')
    try{Save-SafeDiagnostics}catch{Write-Warning 'Some fixture diagnostics could not be collected.'}
    throw 'Shared server rehearsal failed; see retained sanitized diagnostics.'
}finally{
    if($msiStarted -and -not $timedOut -and $null -ne $productCode -and $installer.ProductState($productCode) -ne -1){try{Invoke-RehearsalMsi '/x' $productCode 'server-cleanup-uninstall'}catch{Write-Warning 'Installer cleanup failed; disposable runner logs retained.'}}
    if($trustedThumbprint){$store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine');try{$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);foreach($cert in $store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$trustedThumbprint,$false)){$store.Remove($cert)}}finally{$store.Close()}}
    if($fixtureCreated -and -not $timedOut -and -not (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue) -and -not (Get-ScheduledTask -TaskName 'SBCO Server Daily Backup' -TaskPath '\' -ErrorAction SilentlyContinue)){$owned=Get-Content -LiteralPath (Join-Path $dataPath 'ownership.json') -Raw|ConvertFrom-Json;if($owned.test_token -ceq $token){Remove-Item -LiteralPath $dataPath -Recurse -Force}}
    if(Test-Path -LiteralPath $privateRoot){Remove-Item -LiteralPath $privateRoot -Recurse -Force}
    if($null -ne $certificate){$certificate.Dispose()};if($null -ne $rsa){$rsa.Dispose()};$adminPassword=$null;$session=$null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)|Out-Null
}
