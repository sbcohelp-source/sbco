#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'test-windows-server-upgrade.ps1')
$old='11111111-1111-4111-8111-111111111111';$new='22222222-2222-4222-8222-222222222222';$upgrade='126a311d-74cf-4427-9422-12b3182ea43e'
Assert-UpgradeIdentity $old $new '0.1.0' '0.1.0' $upgrade
foreach($case in @(@($old,$old,'0.1.0','0.1.0',$upgrade),@($old,$new,'0.1.0','0.2.0',$upgrade),@($old,$new,'0.1.0','0.1.0',$new))){
    try{Assert-UpgradeIdentity @case;throw 'Invalid fixture identity accepted.'}catch{if($_.Exception.Message -notlike 'Upgrade fixture requires*'){throw}}
}
[xml]$wix=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../deploy/windows/server/installer.wxs') -Raw
$ns=[Xml.XmlNamespaceManager]::new($wix.NameTable);$ns.AddNamespace('w','http://schemas.microsoft.com/wix/2006/wi')
$major=$wix.SelectSingleNode('//w:MajorUpgrade',$ns)
if($major.AllowSameVersionUpgrades -cne 'yes' -or $major.Schedule -cne 'afterInstallInitialize'){throw 'Fixture expects same-version transactional major upgrade.'}
$remove=$wix.SelectSingleNode('//w:InstallExecuteSequence/w:Custom[@Action="RemoveOwnedServices"]',$ns)
if($remove.InnerText -cne 'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE'){throw 'Upgrade must not unregister the preserved services/task.'}
foreach($file in @('test-windows-server-upgrade.ps1','test-windows-server-runtime.ps1')){
    $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$null,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
}
Write-Host 'PASS upgrade identity refusal cases, same-version transaction and service-preservation guards; both runtime scripts parse.'
