# Runs inside test-control-state.ps1; all settings and pairing are synthetic fixtures.
$fresh=Get-Content (Join-Path $base 'Desktop_Companion/settings.defaults.json') -Raw | ConvertFrom-Json
Assert-True (@($fresh.targets | Where-Object { $_ -ieq 'orca' }).Count -eq 1 -and $fresh.appMultipliers.orca -eq 1.0) 'New installs must include exactly one Orca target at 1.0'
$legacyOrca=Copy-AmbientControlConfig $fresh
$legacyOrca.PSObject.Properties.Remove('targetDefaultsVersion')
$legacyOrca.targets=@('Code','Codex','ChatGPT','MyCustomEditor')
$legacyOrca.appMultipliers.PSObject.Properties.Remove('orca')
$legacyOrca.appMultipliers.code=0.73; $legacyOrca.appMultipliers.codex=1.37
$legacyOrca.control.globalPaused=$true; $legacyOrca.desktopOutput.rgbEnabled=$false
$legacyOrca.desktopOutput.videoEnabled=$false
$legacyOrca | Add-Member -MemberType NoteProperty -Name custom -Value ([pscustomobject]@{keep='unchanged'})
$originalOrca=$legacyOrca | ConvertTo-Json -Depth 12 -Compress
$orcaConfigPath=Join-Path $sandbox 'orca-legacy.json'
[IO.File]::WriteAllText($orcaConfigPath,$originalOrca)
$pairingPath=Join-Path $sandbox 'bridge-pairing.txt'
[IO.File]::WriteAllText($pairingPath,('synthetic-test-key-'*4))
$pairingHash=(Get-FileHash -LiteralPath $pairingPath -Algorithm SHA256).Hash
$migratedOrca=New-AmbientLocalControl $legacyOrca $orcaConfigPath
Assert-True (($migratedOrca.config.targets -join '|') -ceq 'Code|Codex|ChatGPT|MyCustomEditor|orca') 'Migration must append only Orca, preserving the customized target list and its order'
Assert-True ($migratedOrca.config.appMultipliers.orca -eq 1.0 -and $migratedOrca.config.targetDefaultsVersion -eq 1) 'Legacy Orca must start at 1.0 and record the additive migration'
$withoutAddition=Copy-AmbientControlConfig $migratedOrca.config
$withoutAddition.PSObject.Properties.Remove('targetDefaultsVersion')
$withoutAddition.targets=@($withoutAddition.targets | Where-Object { $_ -ine 'orca' })
$withoutAddition.appMultipliers.PSObject.Properties.Remove('orca')
Assert-True (@($withoutAddition.PSObject.Properties).Count -eq @($legacyOrca.PSObject.Properties).Count) 'Migration must add no unrelated settings'
foreach ($property in $legacyOrca.PSObject.Properties) {
    $expected=ConvertTo-Json -InputObject $property.Value -Depth 12 -Compress
    $actual=ConvertTo-Json -InputObject $withoutAddition.($property.Name) -Depth 12 -Compress
    Assert-True ($actual -ceq $expected) ('Unrelated setting must remain identical: '+$property.Name)
}
Assert-True (($legacyOrca | ConvertTo-Json -Depth 12 -Compress) -ceq $originalOrca -and [IO.File]::ReadAllText($orcaConfigPath) -ceq $originalOrca) 'Loading must not mutate the input or saved bytes'
Assert-True (-not (Test-Path -LiteralPath ($orcaConfigPath+'.bak'))) 'Loading must not replace the existing backup'
Write-Output 'PASS Orca fresh install and additive legacy migration; all other settings and saved bytes preserved'

$caseConfig=Copy-AmbientControlConfig $legacyOrca
$caseConfig.targets=@('ORCA','Code')
$caseConfig.appMultipliers | Add-Member -MemberType NoteProperty -Name ORCA -Value 1.31
$caseResult=ConvertTo-AmbientControlConfig $caseConfig
Assert-True (($caseResult.targets -join '|') -ceq 'ORCA|Code' -and $caseResult.appMultipliers.ORCA -eq 1.31) 'Case-insensitive matching must preserve an existing Orca name and customized multiplier'
$caseRepeated=ConvertTo-AmbientControlConfig $caseResult
foreach ($property in $caseResult.PSObject.Properties) {
    Assert-True ((ConvertTo-Json -InputObject $property.Value -Depth 12 -Compress) -ceq (ConvertTo-Json -InputObject $caseRepeated.($property.Name) -Depth 12 -Compress)) 'Repeated migration must be idempotent regardless of JSON property order'
}
$caseConfig.targets=@(); $caseConfig.PSObject.Properties.Remove('appMultipliers')
$emptyResult=ConvertTo-AmbientControlConfig $caseConfig
Assert-True ($emptyResult.targets.Count -eq 1 -and $emptyResult.targets[0] -eq 'orca' -and $emptyResult.appMultipliers.orca -eq 1.0) 'Empty legacy targets and missing multipliers must gain only Orca'
Write-Output 'PASS Orca name casing, custom multiplier, empty legacy targets and repeat-load idempotence'

$saveResult=Set-AmbientLocalControl $migratedOrca @{intensity='soft'}
Assert-True $saveResult.persisted 'Normal settings edits must persist the additive migration'
$savedOrca=Get-Content -LiteralPath $orcaConfigPath -Raw | ConvertFrom-Json
$restartedOrca=New-AmbientLocalControl $savedOrca $orcaConfigPath
Assert-True ($restartedOrca.config.targets -contains 'orca' -and $restartedOrca.config.appMultipliers.orca -eq 1.0) 'Orca must survive save/restart'
Assert-True ([IO.File]::ReadAllText($orcaConfigPath+'.bak') -ceq $originalOrca) 'The prior settings bytes must remain in the normal atomic-save backup'
Assert-True ((Get-FileHash -LiteralPath $pairingPath -Algorithm SHA256).Hash -ceq $pairingHash) 'Loading and saving must preserve the pairing key'
$savedOrca.targets=@($savedOrca.targets | Where-Object { $_ -ine 'orca' })
Assert-True ((ConvertTo-AmbientControlConfig $savedOrca).targets -notcontains 'orca') 'A later explicit removal must be honored after the migration marker was saved'
$savedOrca.targetDefaultsVersion=2
Assert-True ((ConvertTo-AmbientControlConfig $savedOrca).targetDefaultsVersion -eq 2) 'Future target-default markers must not be downgraded'
$savedOrca.targetDefaultsVersion='invalid'
Assert-Rejected { ConvertTo-AmbientControlConfig $savedOrca } 'Invalid markers must fail without rewriting settings'
Write-Output 'PASS Orca normal save/restart, backup and pairing preservation, explicit removal and future marker preservation'
