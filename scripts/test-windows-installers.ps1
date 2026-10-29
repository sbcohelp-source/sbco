#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$LogDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not $env:RUNNER_TEMP) {
    throw 'This destructive packaging smoke test is restricted to an ephemeral GitHub-hosted Windows x64 runner.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The runner must be elevated.' }
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
$LogDirectory = [IO.Path]::GetFullPath($LogDirectory)
[IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
$installer = New-Object -ComObject WindowsInstaller.Installer
$products = @()
$installedByTest = [Collections.Generic.List[string]]::new()
$timedOut = $false
$dataRoot = Join-Path $env:ProgramData 'SBCO Server'
$marker = Join-Path $dataRoot 'installer-smoke-test-only.txt'
$markerValue = 'EPHEMERAL PACKAGING TEST ' + [guid]::NewGuid().ToString('N')
$fixtureCreated = $false
function Read-MsiRows($Database, [string]$Sql, [int]$Columns) {
    $view = $Database.OpenView($Sql)
    try {
        $null = $view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            try {
                $values = @(); for ($index = 1; $index -le $Columns; $index++) { $values += $record.StringData($index) }
                Write-Output -NoEnumerate $values
            } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) | Out-Null }
        }
    } finally { $null = $view.Close(); [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null }
}
function Invoke-Msi([string]$Operation, [string]$Target, [string]$Label) {
    $log = Join-Path $LogDirectory "$Label.log"
    $arguments = "$Operation `"$Target`" /qn /norestart REBOOT=ReallySuppress /L*v `"$log`""
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList $arguments -PassThru
    try {
        if (-not $process.WaitForExit(300000)) {
            $script:timedOut = $true
            $process.Kill()
            throw "MSI $Label exceeded five minutes; stop further MSI operations and retain the disposable runner logs."
        }
        if ($process.ExitCode -notin @(0, 3010)) { throw "MSI $Label failed with exit code $($process.ExitCode). See $log" }
        Add-Content -LiteralPath (Join-Path $LogDirectory 'operations.txt') -Value "$Label exit=$($process.ExitCode)"
    } finally { $process.Dispose() }
}
try {
    # Refuse pre-existing products/data before creating even a test marker.
    foreach ($path in @($dataRoot, (Join-Path $env:ProgramFiles 'SBCO Server'), (Join-Path $env:ProgramFiles 'SBCO Client'), (Join-Path $env:LOCALAPPDATA 'in.sbco.client'), (Join-Path $env:APPDATA 'in.sbco.client'), (Join-Path $env:APPDATA 'in.sbco.vouchercheck'), (Join-Path $env:LOCALAPPDATA 'in.sbco.vouchercheck'))) {
        if (Test-Path -LiteralPath $path) { throw "Existing SBCO data or installation found; refusing smoke test: $path" }
    }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path $root) {
            foreach ($entry in Get-ChildItem $root) {
                $name = $entry.GetValue('DisplayName', $null)
                if ($name -like 'SBCO*') { throw "An existing SBCO product is registered: $name" }
            }
        }
    }
    if (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue) { throw 'Existing SBCO services found; refusing smoke test.' }
    foreach ($edition in @('server', 'client')) {
        $directory = Join-Path $ArtifactDirectory "sbco-$edition-windows-x64-unsigned"
        $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.msi' -File)
        if ($files.Count -ne 1) { throw "Expected exactly one $edition MSI." }
        $file = $files[0]
        $checksum = (Get-Content -LiteralPath ($file.FullName + '.sha256') -Raw).Trim()
        if ($checksum -notmatch '^([a-fA-F0-9]{64})  (.+)$' -or $Matches[2] -cne $file.Name) { throw "Invalid checksum manifest for $edition." }
        $expected = $Matches[1]
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $expected) { throw "Checksum mismatch for $edition; MSI will not be opened or installed." }
        $database = $installer.OpenDatabase($file.FullName, 0)
        try {
            $properties = @{}
            foreach ($row in Read-MsiRows $database 'SELECT `Property`, `Value` FROM `Property`' 2) { $properties[$row[0]] = $row[1] }
            $expectedName = if ($edition -eq 'server') { 'SBCO Server' } else { 'SBCO Client' }
            $upgrade = if ($edition -eq 'server') { '126a311d-74cf-4427-9422-12b3182ea43e' } else { 'd599863f-574d-46f4-bebf-3609e933a7e1' }
            if ($properties.ProductName -cne $expectedName -or $properties.Manufacturer -cne 'S K Singh' -or ([guid]$properties.UpgradeCode) -ne ([guid]$upgrade)) { throw "Unexpected $edition MSI identity." }
            if ([guid]$properties.ProductCode -eq [guid]::Empty) { throw 'Empty MSI ProductCode.' }
            if ($installer.ProductState($properties.ProductCode) -ne -1) { throw "Product already registered: $expectedName" }
            $summary = $database.SummaryInformation(0)
            try { $template = $summary.Property(7) } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) | Out-Null }
            if ($template -notmatch '^x64;') { throw "$edition MSI is not an x64 package." }
            $names = @(Read-MsiRows $database 'SELECT `FileName` FROM `File`' 1 | ForEach-Object { $_[0].Split('|')[-1] })
            $directories = @(Read-MsiRows $database 'SELECT `DefaultDir` FROM `Directory`' 1 | ForEach-Object { $_[0] })
            if ($edition -eq 'client') {
                if ($names | Where-Object { $_ -match '^(postgres|initdb|pg_ctl|pg_dump|pg_restore|createdb|dropdb)\.exe$|^libpq.*\.dll$' }) { throw 'Connected-client MSI contains PostgreSQL executable resources.' }
                if ($directories | Where-Object { $_ -match '(?i)postgres|pgsql' }) { throw 'Connected-client MSI contains PostgreSQL directories.' }
            } else {
                foreach ($required in @('sbco-api.exe', 'sbco-worker.exe', 'node.exe', 'postgres.exe', 'winsw.exe', 'caddy.exe', 'Configure-Server.ps1')) { if ($names -notcontains $required) { throw "Server payload missing $required" } }
                $actions = @(Read-MsiRows $database 'SELECT `Action`, `Target` FROM `CustomAction`' 2 | Where-Object { $_[1] -match 'powershell\.exe' })
                if ($actions.Count -ne 5) { throw 'Expected five server PowerShell custom actions.' }
                foreach ($action in $actions) { if ($action[1] -notlike '*[[]System64Folder[]]*') { throw "Server action $($action[0]) must launch 64-bit PowerShell through System64Folder." } }
                $shortcuts = @(Read-MsiRows $database 'SELECT `Shortcut`, `Target` FROM `Shortcut`' 2 | Where-Object { $_[0] -eq 'ConfigureShortcut' })
                if ($shortcuts.Count -ne 1 -or $shortcuts[0][1] -notlike '*[[]System64Folder[]]*') { throw 'Configure shortcut must use System64Folder.' }
            }
            $products += [pscustomobject]@{edition=$edition;name=$properties.ProductName;product_code=$properties.ProductCode;upgrade_code=$properties.UpgradeCode;version=$properties.ProductVersion;template=$template;path=$file.FullName;sha256=$expected;file_count=$names.Count}
        } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) | Out-Null }
    }
    $products | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $LogDirectory 'verified-msi-identities.json') -Encoding utf8NoBOM
    if ($products[0].product_code -eq $products[1].product_code) { throw 'Server/client ProductCodes must be distinct.' }
    foreach ($product in $products) {
        # Track before install so failed installs can still be removed if registered.
        $installedByTest.Add($product.product_code)
        Invoke-Msi '/i' $product.path "$($product.edition)-install"
        if ($installer.ProductState($product.product_code) -ne 5) { throw "$($product.edition) is not registered as installed." }
        if ($product.edition -eq 'server') {
            if (-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'SBCO Server\server\Configure-Server.ps1'))) { throw 'Installed server setup entry point is missing.' }
            if (Test-Path -LiteralPath $dataRoot) { throw 'Fresh MSI unexpectedly created server data before guided setup.' }
            [IO.Directory]::CreateDirectory($dataRoot) | Out-Null
            [IO.File]::WriteAllText($marker, $markerValue)
            $fixtureCreated = $true
        }
        Invoke-Msi '/fa' $product.path "$($product.edition)-repair"
        Invoke-Msi '/x' $product.product_code "$($product.edition)-uninstall"
        if ($installer.ProductState($product.product_code) -ne -1) { throw "$($product.edition) remains registered after uninstall." }
        if ($product.edition -eq 'server' -and ([IO.File]::ReadAllText($marker) -cne $markerValue)) { throw 'Server uninstall changed the preserved ProgramData fixture.' }
    }
    if (Get-Service -Name 'SBCO*' -ErrorAction SilentlyContinue) { throw 'Packaging smoke unexpectedly created SBCO services.' }
    'PASS: checksums, MSI identities/x64 launchers, client without PostgreSQL, fresh install/repair/uninstall and server marker retention. No office setup, login or service configuration performed.' | Set-Content -LiteralPath (Join-Path $LogDirectory 'result.txt')
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $LogDirectory 'failure.txt')
    throw
} finally {
    if (-not $timedOut) {
        foreach ($code in $installedByTest) {
            if ($timedOut) { break }
            if ($installer.ProductState($code) -ne -1) {
                try { Invoke-Msi '/x' $code ('cleanup-' + $code.Trim('{}')) } catch { Write-Warning $_ }
            }
        }
    }
    if ($fixtureCreated -and (Test-Path -LiteralPath $marker) -and ([IO.File]::ReadAllText($marker) -ceq $markerValue)) {
        Remove-Item -LiteralPath $marker
        if (@(Get-ChildItem -LiteralPath $dataRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $dataRoot }
    }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
}
