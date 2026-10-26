# Isolated settings/command checks. Never reads production settings or starts a desktop/bridge.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$base=Split-Path $PSScriptRoot
. (Join-Path $base 'Desktop_Companion/Lifecycle.ps1')
. (Join-Path $base 'Desktop_Companion/Control-State.ps1')
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Assert-True $failed $Message
}
function New-TestControl([string]$Name) {
    $path=Join-Path $sandbox ($Name+'.json')
    $config=Get-Content (Join-Path $base 'Desktop_Companion/settings.defaults.json') -Raw | ConvertFrom-Json
    $config | Add-Member -MemberType NoteProperty -Name custom -Value ([pscustomobject]@{nested='preserved'})
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return (New-AmbientLocalControl $config $path)
}
$artifacts=Join-Path $base 'artifacts'
[void][IO.Directory]::CreateDirectory($artifacts)
$sandbox=Join-Path $artifacts ('control-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
try {
    . (Join-Path $PSScriptRoot 'orca-settings-cases.ps1')
    $model=New-TestControl 'legacy'
    $legacy=Get-Content -LiteralPath $model.configPath -Raw | ConvertFrom-Json
    $legacy.PSObject.Properties.Remove('schemaVersion')
    $legacy.PSObject.Properties.Remove('control')
    $legacy.PSObject.Properties.Remove('desktopOutput')
    $before=$legacy | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($model.configPath,$before)
    $model=New-AmbientLocalControl $legacy $model.configPath
    Assert-True ($model.config.schemaVersion -eq 1 -and -not $model.config.control.globalPaused) 'Legacy settings must gain an unpaused schema in memory'
    Assert-True ($model.config.desktopOutput.enabled -and $model.config.desktopOutput.rgbEnabled -and $model.config.desktopOutput.videoEnabled) 'Legacy defaults must preserve the RGB plus video combination'
    Assert-True ($before -ceq [IO.File]::ReadAllText($model.configPath)) 'Reading/migrating must not save settings'
    Assert-True ($legacy.PSObject.Properties.Name -notcontains 'schemaVersion') 'Migration must not mutate its input'
    $legacy.desktopVideo.PSObject.Properties.Remove('transitionStyle'); $legacy.desktopVideo.smooth=$false
    $migrated=ConvertTo-AmbientControlConfig $legacy
    Assert-True ($migrated.desktopVideo.transitionStyle -eq 'instant' -and -not $migrated.desktopVideo.smooth) 'Legacy smooth=false must retain instant'
    $legacy.desktopVideo.smooth=$true
    Assert-True ((ConvertTo-AmbientControlConfig $legacy).desktopVideo.transitionStyle -eq 'brief') 'Legacy smooth=true must retain brief'
    $sparse=ConvertTo-AmbientControlConfig ([pscustomobject]@{desktopVideo=$null})
    Assert-True ($sparse.desktopVideo.coverage -eq 'follow' -and $sparse.desktopVideo.transitionStyle -eq 'brief') 'Sparse settings must keep existing video defaults'
    Write-Output 'PASS legacy/sparse migration, input and file preservation, smooth compatibility'

    foreach ($rgb in @($false,$true)) {
        foreach ($video in @($false,$true)) {
            [void](Set-AmbientLocalControl $model @{rgbEnabled=$rgb;videoEnabled=$video})
            [void](Set-AmbientLocalControl $model @{globalPaused=$true})
            [void](Set-AmbientLocalControl $model @{globalPaused=$false})
            Assert-True ($model.config.desktopOutput.rgbEnabled -eq $rgb -and $model.config.desktopOutput.videoEnabled -eq $video) 'Resume must retain every independent output combination'
        }
    }
    [void](Set-AmbientLocalControl $model @{desktopEnabled=$false})
    [void](Set-AmbientLocalControl $model @{globalPaused=$true})
    [void](Set-AmbientLocalControl $model @{globalPaused=$false})
    Assert-True (-not $model.config.desktopOutput.enabled) 'Resume must not enable a disabled Desktop output'
    Write-Output 'PASS RGB/video combinations, pause/resume and Desktop output independence'

    [void](Set-AmbientLocalControl $model @{intensity='vivid';coverage='wide';transitionStyle='cinematic';palette='forest';strength=0.42;motion=$true;seconds=80})
    $saved=Get-Content -LiteralPath $model.configPath -Raw | ConvertFrom-Json
    $restored=New-AmbientLocalControl $saved $model.configPath
    Assert-True ($restored.config.desktopOutput.intensity -eq 'vivid' -and $restored.config.desktopVideo.coverage -eq 'wide' -and $restored.config.desktopVideo.transitionStyle -eq 'cinematic') 'Saved local choices must survive restart'
    Assert-True ($restored.config.custom.nested -eq 'preserved' -and $restored.config.youtubeBridge.port -eq 38941 -and $restored.config.appMultipliers.codex -eq 1.22) 'Migration and commands must preserve unrelated and unknown fields'
    Assert-True ($restored.config.palette -eq 'forest' -and $restored.config.strength -eq 0.42 -and $restored.config.animationSeconds -eq 80) 'Existing appearance fields must use the same save path'
    Write-Output 'PASS atomic persistence, restart and unknown/Bridge/appearance setting preservation'

    $revision=$model.revision
    $original=[IO.File]::ReadAllText($model.configPath)
    $held=[IO.File]::Open(($model.configPath+'.tmp'),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $result=Set-AmbientLocalControl $model @{intensity='vivid';globalPaused=$false}
        Assert-True ($result.persisted -and -not $result.changed -and $model.revision -eq $revision) 'An identical command must not write or advance revision even when temporary writes are locked'
    } finally { $held.Dispose(); [IO.File]::Delete($model.configPath+'.tmp') }
    Assert-True ([IO.File]::ReadAllText($model.configPath) -ceq $original) 'Duplicate commands must leave the saved bytes unchanged'
    Write-Output 'PASS duplicate explicit commands do not toggle, save or advance revision'

    $model=New-TestControl 'locked'
    $original=[IO.File]::ReadAllText($model.configPath)
    $held=[IO.File]::Open(($model.configPath+'.tmp'),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $result=Set-AmbientLocalControl $model @{videoEnabled=$false;intensity='soft'}
        Assert-True (-not $result.persisted -and -not $result.changed -and $model.revision -eq 0) 'A failed ordinary save must not commit state'
        Assert-True ($model.config.desktopOutput.videoEnabled -and $model.config.desktopOutput.intensity -eq 'balanced') 'A failed ordinary save must preserve all requested preferences'
        $result=Set-AmbientLocalControl $model @{globalPaused=$true;rgbEnabled=$false}
        Assert-True (-not $result.persisted -and $result.changed -and $model.config.control.globalPaused -and $model.savePending) 'Pause must apply immediately and remain explicitly unsaved'
        Assert-True ($model.config.desktopOutput.rgbEnabled -and $model.config.desktopOutput.videoEnabled) 'A failed mixed pause command may apply only pause'
        $revision=$model.revision
        $result=Set-AmbientLocalControl $model @{globalPaused=$true}
        Assert-True (-not $result.persisted -and -not $result.changed -and $model.revision -eq $revision) 'Failed duplicate pause must stay paused without another revision'
        $result=Set-AmbientLocalControl $model @{globalPaused=$false}
        Assert-True (-not $result.persisted -and $model.config.control.globalPaused) 'A failed resume save must leave the Desktop paused'
        Assert-True ([IO.File]::ReadAllText($model.configPath) -ceq $original) 'All failed saves must preserve the original file'
        $restart=New-AmbientLocalControl (Get-Content -LiteralPath $model.configPath -Raw | ConvertFrom-Json) $model.configPath
        Assert-True (-not $restart.config.control.globalPaused) 'Restart must restore the last saved state, not fabricate persistence for a failed pause'
    } finally { $held.Dispose() }
    $result=Set-AmbientLocalControl $model @{globalPaused=$true}
    Assert-True ($result.persisted -and -not $result.changed -and -not $model.savePending -and $model.revision -eq $revision) 'Retry must persist an unsaved pause without changing it again'
    $restart=New-AmbientLocalControl (Get-Content -LiteralPath $model.configPath -Raw | ConvertFrom-Json) $model.configPath
    Assert-True $restart.config.control.globalPaused 'A successful retry must survive restart'
    Assert-True ([IO.File]::ReadAllText($model.configPath+'.bak') -ceq $original) 'Atomic save must retain the previous valid file as its backup'
    Write-Output 'PASS locked-save rollback, immediate unsaved pause, duplicate retry and restart semantics'

    [IO.File]::SetAttributes($model.configPath,[IO.FileAttributes]::ReadOnly)
    try {
        $result=Set-AmbientLocalControl $model @{globalPaused=$false}
        Assert-True (-not $result.persisted -and $model.config.control.globalPaused) 'Read-only settings must not apply resume'
    } finally { [IO.File]::SetAttributes($model.configPath,[IO.FileAttributes]::Normal) }
    Assert-True (-not [IO.File]::Exists($model.configPath+'.tmp')) 'A failed atomic replacement must clean its temporary file'
    [void](Set-AmbientLocalControl $model @{globalPaused=$false})
    Assert-True (-not $model.config.control.globalPaused) 'Save must recover after the restriction is removed'
    Write-Output 'PASS read-only save failure and later recovery'

    $revision=$model.revision
    Assert-Rejected { Set-AmbientLocalControl $model @{globalPaused='false'} } 'String booleans must be rejected'
    Assert-Rejected { Set-AmbientLocalControl $model @{videoEnabled=$false;unsupported=$true} } 'Unknown keys must reject the complete command'
    Assert-Rejected { Set-AmbientLocalControl $model @{intensity='invalid'} } 'Unknown intensity must be rejected'
    Assert-Rejected { Set-AmbientLocalControl $model @{strength=[double]::NaN} } 'Nonfinite strength must be rejected'
    Assert-True ($model.revision -eq $revision -and $model.config.desktopOutput.videoEnabled) 'Invalid commands must not change state'
    Assert-Rejected { ConvertTo-AmbientControlConfig ([pscustomobject]@{schemaVersion=2}) } 'Future schemas must not be silently downgraded'
    Assert-Rejected { ConvertTo-AmbientControlConfig ([pscustomobject]@{control=[pscustomobject]@{globalPaused='false'}}) } 'Invalid persisted booleans must be rejected'
    Assert-Rejected { ConvertTo-AmbientControlConfig ([pscustomobject]@{desktopOutput=$false}) } 'Invalid output objects must be rejected'
    $corruptPath=Join-Path $sandbox 'corrupt.json'; [IO.File]::WriteAllText($corruptPath,'{invalid')
    Assert-Rejected { New-AmbientLocalControl (Get-Content -LiteralPath $corruptPath -Raw | ConvertFrom-Json) $corruptPath } 'Invalid JSON must fail without auto-reset'
    Assert-True ([IO.File]::ReadAllText($corruptPath) -ceq '{invalid') 'Corrupt settings must remain available for recovery'
    Write-Output 'PASS invalid commands, corrupt settings and future schema rejection without mutation'
} finally {
    $resolved=[IO.Path]::GetFullPath($sandbox)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($artifacts) -or [IO.Path]::GetFileName($resolved) -notlike 'control-test-*') { throw 'Unsafe control test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
