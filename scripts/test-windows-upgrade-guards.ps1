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

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sbco-upgrade-json-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $before='{"ready":true,"hostname":"localhost","configured_at":"2026-10-29T12:00:00.1234567Z","firewall":false}'
    [IO.File]::WriteAllText($fixture,$before)
    $snapshot=Read-ConfiguredState $fixture
    $rewritten=$before|ConvertFrom-Json
    $rewritten|Add-Member -NotePropertyName ready -NotePropertyValue $true -Force
    [IO.File]::WriteAllText($fixture,($rewritten|ConvertTo-Json))
    if((Read-ConfiguredState $fixture) -cne $snapshot){throw 'Normal Resume JSON property reordering was treated as data loss.'}
    foreach($key in @('hostname','ready','configured_at','firewall')){
        $modified=$before|ConvertFrom-Json
        $modified.$key=if($key -in @('ready','firewall')){-not $modified.$key}else{'changed-fixture-value'}
        [IO.File]::WriteAllText($fixture,($modified|ConvertTo-Json))
        if((Read-ConfiguredState $fixture) -ceq $snapshot){throw "Changed configured state field escaped detection: $key"}
    }
    $modified=$before|ConvertFrom-Json;$modified|Add-Member -NotePropertyName extra -NotePropertyValue 'new'
    [IO.File]::WriteAllText($fixture,($modified|ConvertTo-Json))
    if((Read-ConfiguredState $fixture) -ceq $snapshot){throw 'Added configured state field escaped detection.'}
    Write-Host 'PASS actual Resume property reorder preserves JSON values; changed/added fields are rejected.'
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture}}
