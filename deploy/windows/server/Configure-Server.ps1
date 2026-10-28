#requires -Version 5.1
# Guided setup: no administrator/database secrets are accepted as MSI properties.
. (Join-Path $PSScriptRoot 'Server-Common.ps1')
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit
}
Assert-Administrator
$setupLock = New-Object Threading.Mutex($false, 'Global\SBCOServerSetup')
if (-not $setupLock.WaitOne(0)) { throw 'Server setup is already running.' }
$createdServices = New-Object 'System.Collections.Generic.List[string]'
$createdFirewall = $false
$setupFailed = $false
try {
    if (Read-OwnedInstallation) {
        Resume-ServerServices
        Read-Host 'Press Enter to close' | Out-Null
        return
    }
    if (Test-Path -LiteralPath $DataRoot) { throw 'A server data directory already exists. It was not changed. Preserve it and ask the operator to review recovery.' }
    foreach ($name in $ServiceNames) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) { throw "Service $name already exists. Setup will not take ownership of it." }
    }
    foreach ($port in @(55439, 8091, 3091, 443)) {
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { throw "Required port $port is already in use." }
    }
    $hostnameValue = (Read-Host 'HTTPS server hostname (must resolve to this computer and match your certificate)').Trim()
    if ($hostnameValue -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -or [uri]::CheckHostName($hostnameValue) -eq [System.UriHostNameType]::Unknown) { throw 'Enter a valid DNS hostname without a scheme, port or path.' }
    $certificate = (Resolve-Path -LiteralPath (Read-Host 'Full path to the PEM certificate chain')).Path
    $privateKey = (Resolve-Path -LiteralPath (Read-Host 'Full path to its unencrypted PEM private key')).Path
    # Verify PEM/key, hostname, trust and actual local HTTPS before creating any database.
    $preflightRoot = Join-Path $env:ProgramData ('SBCO-TLS-Preflight-' + [guid]::NewGuid().ToString('N'))
    $preflightProcess = $null
    try {
        Set-PrivateDirectory $preflightRoot
        $token = [guid]::NewGuid().ToString('N')
        $certQuoted = $certificate.Replace('\','/') | ConvertTo-Json -Compress
        $keyQuoted = $privateKey.Replace('\','/') | ConvertTo-Json -Compress
        $preflightConfig = Join-Path $preflightRoot 'Caddyfile'
        Write-Utf8 $preflightConfig (@"
{
    admin off
    auto_https off
}
https://$hostnameValue {
    tls $certQuoted $keyQuoted
    respond /sbco-setup-check-$token "$token" 200
}
"@)
        $preflightProcess = Start-Process -FilePath (Join-Path $InstallRoot 'tools\caddy.exe') -ArgumentList ('run --config "' + $preflightConfig + '" --adapter caddyfile') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $preflightRoot 'stdout.log') -RedirectStandardError (Join-Path $preflightRoot 'stderr.log')
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Wait-Condition {
            if ($preflightProcess.HasExited) { throw 'HTTPS preflight failed. Check that the PEM certificate and key match and are readable.' }
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "https://$hostnameValue/sbco-setup-check-$token" -TimeoutSec 5
                $response.StatusCode -eq 200 -and $response.Content.Trim() -ceq $token
            } catch { $false }
        } 'trusted HTTPS certificate and local hostname resolution' 30
    } finally {
        if ($null -ne $preflightProcess) {
            if (-not $preflightProcess.HasExited) { $preflightProcess.Kill(); $preflightProcess.WaitForExit() }
            $preflightProcess.Dispose()
        }
        if (Test-Path -LiteralPath $preflightRoot) { Remove-Item -LiteralPath $preflightRoot -Recurse -Force }
    }
    $adminName = (Read-Host 'First SBCO administrator full name').Trim()
    $adminEmail = (Read-Host 'First SBCO administrator email').Trim()
    if (-not $adminName -or $adminEmail -notmatch '^[^\s@]+@[^\s@]+$') { throw 'Administrator name and email are required.' }
    $securePassword = Read-Host 'First administrator password (at least 12 characters)' -AsSecureString
    $confirmation = Read-Host 'Repeat administrator password' -AsSecureString
    function Reveal([Security.SecureString]$Value) {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    $adminPassword = Reveal $securePassword
    if ($adminPassword.Length -lt 12 -or $adminPassword -cne (Reveal $confirmation)) { throw 'Passwords must match and contain at least 12 characters.' }
    $allowFirewall = (Read-Host 'Allow office computers to reach HTTPS TCP 443 on Private/Domain networks? [Y/n]') -notmatch '^(n|no)$'
    Set-PrivateDirectory $DataRoot
    Write-Utf8 (Join-Path $DataRoot 'ownership.json') (@{format=1; install_root=$InstallRoot; created_at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json)
    foreach ($directory in @('services', 'logs', 'database', 'tls', 'https-state', 'backups')) { Set-PrivateDirectory (Join-Path $DataRoot $directory) }
    $randomBytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($randomBytes) } finally { $random.Dispose() }
    $databasePassword = -join ($randomBytes | ForEach-Object { $_.ToString('x2') })
    $databaseUrl = "postgresql://sbco:$databasePassword@127.0.0.1:55439/sbco"
    $pgBin = Join-Path $InstallRoot 'postgres\bin'
    $pgData = Join-Path $DataRoot 'database\cluster'
    $passwordFile = Join-Path $DataRoot 'database\init-password'
    Write-Utf8 $passwordFile $databasePassword
    Copy-Item -LiteralPath $certificate -Destination (Join-Path $DataRoot 'tls\certificate.pem')
    Copy-Item -LiteralPath $privateKey -Destination (Join-Path $DataRoot 'tls\private-key.pem')
    function New-ServiceConfig([string]$Name, [string]$Executable, [string]$Arguments, [hashtable]$Environment = @{}, [string[]]$Dependencies = @(), [bool]$Automatic = $true) {
        $directory = Join-Path $DataRoot "services\$Name"
        Set-PrivateDirectory $directory
        if (-not (Test-Path (Get-Wrapper $Name))) { Copy-Item -LiteralPath (Join-Path $InstallRoot 'tools\winsw.exe') -Destination (Get-Wrapper $Name) }
        $xml = New-Object Xml.XmlDocument
        $service = $xml.CreateElement('service'); $null = $xml.AppendChild($service)
        $values = @{id=$Name; name="SBCO Server - $Name"; description='SBCO Server, S K Singh, sbcohelp@gmail.com'; executable=$Executable; arguments=$Arguments; workingdirectory=$InstallRoot; startmode=$(if($Automatic){'Automatic'}else{'Manual'}); stoptimeout='60sec'; logpath=(Join-Path $DataRoot "logs\$Name")}
        foreach ($key in $values.Keys) { $element=$xml.CreateElement($key);$element.InnerText=$values[$key];$null=$service.AppendChild($element) }
        $account=$xml.CreateElement('serviceaccount');$null=$service.AppendChild($account)
        foreach($pair in @(@('domain','NT AUTHORITY'),@('user','LocalService'))) { $element=$xml.CreateElement($pair[0]);$element.InnerText=$pair[1];$null=$account.AppendChild($element) }
        foreach($key in $Environment.Keys) { $element=$xml.CreateElement('env');$element.SetAttribute('name',$key);$element.SetAttribute('value',$Environment[$key]);$null=$service.AppendChild($element) }
        foreach($dependency in $Dependencies) { $element=$xml.CreateElement('depend');$element.InnerText=$dependency;$null=$service.AppendChild($element) }
        $log=$xml.CreateElement('log');$log.SetAttribute('mode','roll');$null=$service.AppendChild($log)
        if($Automatic) { $failure=$xml.CreateElement('onfailure');$failure.SetAttribute('action','restart');$failure.SetAttribute('delay','10 sec');$null=$service.AppendChild($failure) }
        $xml.Save((Join-Path $directory "$Name.xml"))
    }
    function Install-NewService([string]$Name) {
        Invoke-Wrapper $Name 'install';$createdServices.Add($Name)
        & sc.exe sidtype $Name unrestricted | Out-Null
        if($LASTEXITCODE -ne 0){throw "Cannot configure service identity: $Name"}
        $sid=Get-ServiceSid $Name
        Grant-Traverse $DataRoot $sid;Grant-Traverse (Join-Path $DataRoot 'services') $sid;Grant-Traverse (Join-Path $DataRoot 'logs') $sid
        Set-PrivateDirectory (Join-Path $DataRoot "services\$Name") @($sid)
        Set-PrivateDirectory (Join-Path $DataRoot "logs\$Name") @($sid) 'Modify'
        return $sid
    }
    # Initialize and run PostgreSQL under the SAME restricted service identity.
    # Builtin C.UTF-8 avoids relying on a Windows libc locale name.
    New-ServiceConfig 'SBCOPostgres' (Join-Path $pgBin 'initdb.exe') ('-D "'+$pgData+'" -L "'+(Join-Path $InstallRoot 'postgres\share')+'" -U sbco --auth=scram-sha-256 --encoding=UTF8 --locale-provider=builtin --builtin-locale=C.UTF-8 --pwfile="'+$passwordFile+'"') @{} @() $false
    $pgSid=Install-NewService 'SBCOPostgres'
    Set-PrivateDirectory (Join-Path $DataRoot 'database') @($pgSid) 'Modify'
    Invoke-Wrapper 'SBCOPostgres' 'start'
    Wait-Condition { (Get-Service 'SBCOPostgres').Status -eq 'Stopped' } 'database initialization' 180
    if(-not (Test-Path (Join-Path $pgData 'global\pg_control')) -or (Get-Content (Join-Path $pgData 'PG_VERSION') -Raw).Trim() -ne '18'){throw 'Database initialization failed. Inspect the protected PostgreSQL logs.'}
    Remove-Item -LiteralPath $passwordFile -Force
    Add-Content -LiteralPath (Join-Path $pgData 'postgresql.conf') -Encoding ASCII -Value "`nlisten_addresses='127.0.0.1'`nport=55439`nmax_connections=50`nshared_buffers='128MB'`nunix_socket_directories=''"
    New-ServiceConfig 'SBCOPostgres' (Join-Path $pgBin 'postgres.exe') ('-D "'+$pgData+'"')
    Set-PrivateDirectory (Join-Path $DataRoot 'services\SBCOPostgres') @($pgSid)
    & sc.exe config SBCOPostgres start= auto | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Cannot enable automatic database startup.'}
    Invoke-Wrapper 'SBCOPostgres' 'start'
    Wait-Condition { & (Join-Path $pgBin 'pg_isready.exe') -h 127.0.0.1 -p 55439 -U sbco *> $null; $LASTEXITCODE -eq 0 } 'PostgreSQL readiness'
    function Invoke-PrivateProcess([string]$Executable,[string]$Arguments,[hashtable]$Environment,[string]$Label) {
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$Executable;$info.Arguments=$Arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach($key in $Environment.Keys){$info.EnvironmentVariables[$key]=$Environment[$key]}
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info;$null=$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(180000)){$process.Kill();throw "$Label timed out."}
        Write-Utf8 (Join-Path $DataRoot "logs\$Label.log") ($stdout.Result+"`n"+$stderr.Result)
        if($process.ExitCode -ne 0){throw "$Label failed. Inspect its protected log."}
        $process.Dispose()
    }
    New-ServiceConfig 'SBCOApi' (Join-Path $InstallRoot 'bin\sbco-api.exe') '' @{DATABASE_URL=$databaseUrl;SBCO_BIND='127.0.0.1:8091';SBCO_INSECURE_LOCAL_HTTP='0'} @('SBCOPostgres')
    $null=Install-NewService 'SBCOApi'
    New-ServiceConfig 'SBCOWorker' (Join-Path $InstallRoot 'bin\sbco-worker.exe') '' @{DATABASE_URL=$databaseUrl} @('SBCOApi')
    $null=Install-NewService 'SBCOWorker'
    New-ServiceConfig 'SBCOWeb' (Join-Path $InstallRoot 'node\node.exe') ('"'+(Join-Path $InstallRoot 'web\apps\web\server.js')+'"') @{NODE_ENV='production';HOSTNAME='127.0.0.1';PORT='3091';NEXT_TELEMETRY_DISABLED='1'} @('SBCOApi')
    $null=Install-NewService 'SBCOWeb'
    $certPath=(Join-Path $DataRoot 'tls\certificate.pem').Replace('\','/') | ConvertTo-Json -Compress
    $keyPath=(Join-Path $DataRoot 'tls\private-key.pem').Replace('\','/') | ConvertTo-Json -Compress
    $caddyConfig=@"
{
    admin off
    auto_https off
}
https://$hostnameValue {
    tls $certPath $keyPath
    handle /api/* {
        reverse_proxy 127.0.0.1:8091
    }
    handle {
        reverse_proxy 127.0.0.1:3091
    }
}
"@
    $caddyPath=Join-Path $DataRoot 'tls\Caddyfile'
    Write-Utf8 $caddyPath $caddyConfig
    Invoke-PrivateProcess (Join-Path $InstallRoot 'tools\caddy.exe') ('validate --config "'+$caddyPath+'" --adapter caddyfile') @{} 'validate-https'
    New-ServiceConfig 'SBCOHttps' (Join-Path $InstallRoot 'tools\caddy.exe') ('run --config "'+$caddyPath+'" --adapter caddyfile') @{XDG_DATA_HOME=(Join-Path $DataRoot 'https-state');XDG_CONFIG_HOME=(Join-Path $DataRoot 'https-state')} @('SBCOWeb','SBCOApi')
    $httpsSid=Install-NewService 'SBCOHttps'
    Set-PrivateDirectory (Join-Path $DataRoot 'tls') @($httpsSid)
    Set-PrivateDirectory (Join-Path $DataRoot 'https-state') @($httpsSid) 'Modify'
    # All service configurations are complete before bootstrap. Once bootstrap succeeds,
    # this checkpoint makes health/start failures resumable without touching the database.
    Invoke-PrivateProcess (Join-Path $pgBin 'createdb.exe') '-h 127.0.0.1 -p 55439 -U sbco sbco' @{PGPASSWORD=$databasePassword} 'create-database'
    Invoke-PrivateProcess (Join-Path $InstallRoot 'bin\sbco-api.exe') '--bootstrap' @{DATABASE_URL=$databaseUrl;SBCO_ADMIN_NAME=$adminName;SBCO_ADMIN_EMAIL=$adminEmail;SBCO_ADMIN_PASSWORD=$adminPassword} 'bootstrap'
    $adminPassword=$null;$securePassword.Dispose();$confirmation.Dispose()
    Write-Utf8 (Join-Path $DataRoot 'configured.json') (@{hostname=$hostnameValue;configured_at=[DateTime]::UtcNow.ToString('o');firewall=$allowFirewall;ready=$false} | ConvertTo-Json)
    foreach($name in @('SBCOApi','SBCOWorker','SBCOWeb','SBCOHttps')) {
        Invoke-Wrapper $name 'start'
        Wait-Condition { (Get-Service $name).Status -eq 'Running' } "start $name"
        if($name -eq 'SBCOApi'){Wait-Http 'http://127.0.0.1:8091/health'}
        if($name -eq 'SBCOWeb'){Wait-Http 'http://127.0.0.1:3091/'}
    }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Wait-Http "https://$hostnameValue/api/v1/server-info"
    if($allowFirewall) {
        if(Get-NetFirewallRule -Name 'SBCO-HTTPS-443' -ErrorAction SilentlyContinue){throw 'An existing firewall rule uses the reserved SBCO name.'}
        Set-OwnedFirewall $true
        $createdFirewall=$true
    }
    Write-Utf8 (Join-Path $DataRoot 'configured.json') (@{hostname=$hostnameValue;configured_at=[DateTime]::UtcNow.ToString('o');firewall=$allowFirewall;ready=$true} | ConvertTo-Json)
    Write-Host "SBCO Server is ready at https://$hostnameValue. Support: sbcohelp@gmail.com"
}
catch {
    foreach($name in @('SBCOHttps','SBCOWeb','SBCOWorker','SBCOApi','SBCOPostgres')) {
        if($createdServices.Contains($name)) {
            try { if((Get-Service $name).Status -ne 'Stopped'){Invoke-Wrapper $name 'stop'};Invoke-Wrapper $name 'uninstall' } catch { Write-Warning "Review service $name manually; cleanup could not finish." }
        }
    }
    if($createdFirewall){Set-OwnedFirewall $false}
    $temporaryPassword=Join-Path $DataRoot 'database\init-password'
    if(Test-Path -LiteralPath $temporaryPassword){Remove-Item -LiteralPath $temporaryPassword -Force}
    $setupFailed = $true
    Write-Host "Setup failed: $($_.Exception.Message) Existing/partial data is preserved in $DataRoot. No automatic reinitialization will occur." -ForegroundColor Red
}
finally {
    $adminPassword=$null
    $setupLock.ReleaseMutex();$setupLock.Dispose()
}
Read-Host 'Press Enter to close' | Out-Null

if ($setupFailed) { exit 1 }
