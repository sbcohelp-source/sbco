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
