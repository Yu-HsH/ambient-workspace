# Desktop-local state only. No UI, browser control, pairing, processes or network work.
. (Join-Path $PSScriptRoot 'Hotkey-Config.ps1')
function Copy-AmbientControlConfig($Config) {
    if ($null -eq $Config -or $Config -isnot [pscustomobject]) { throw 'Settings must be a JSON object.' }
    return ($Config | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function Add-AmbientControlDefault($Object, [string]$Name, $Value) {
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function ConvertTo-AmbientControlConfig($Config) {
    $next = Copy-AmbientControlConfig $Config
    if ($null -ne $next.PSObject.Properties['schemaVersion']) {
        if (($next.schemaVersion -isnot [int] -and $next.schemaVersion -isnot [long]) -or $next.schemaVersion -notin @(0,1)) {
            throw 'Unsupported settings schemaVersion; the settings file was not changed.'
        }
    }
    $next | Add-Member -MemberType NoteProperty -Name schemaVersion -Value 1 -Force
    Add-AmbientControlDefault $next 'control' ([pscustomobject]@{})
    Add-AmbientControlDefault $next 'desktopOutput' ([pscustomobject]@{})
    foreach ($name in @('control','desktopOutput')) {
        if ($null -eq $next.$name -or $next.$name -isnot [pscustomobject]) { throw ('Invalid settings object: '+$name) }
    }
    Add-AmbientControlDefault $next.control 'globalPaused' $false
    # Opt-in migration: loading an old config never claims an existing user's key.
    # Invalid optional hotkey settings are reported by the runtime, not a startup failure.
    Add-AmbientControlDefault $next 'globalHotkey' ([pscustomobject]@{enabled=$false;combination='Ctrl+Alt+Shift+P'})
    foreach ($name in @('enabled','rgbEnabled','videoEnabled')) { Add-AmbientControlDefault $next.desktopOutput $name $true }
    Add-AmbientControlDefault $next.desktopOutput 'intensity' 'balanced'
    if ($next.control.globalPaused -isnot [bool]) { throw 'Invalid boolean: control.globalPaused' }
    foreach ($name in @('enabled','rgbEnabled','videoEnabled')) {
        if ($next.desktopOutput.$name -isnot [bool]) { throw ('Invalid boolean: desktopOutput.'+$name) }
    }
    if ($next.desktopOutput.intensity -cnotin @('soft','balanced','vivid')) { throw 'Invalid desktopOutput.intensity' }

    Add-AmbientControlDefault $next 'desktopVideo' ([pscustomobject]@{})
    if ($null -eq $next.desktopVideo) { $next.desktopVideo = [pscustomobject]@{} }
    if ($next.desktopVideo -isnot [pscustomobject]) { throw 'Invalid settings object: desktopVideo' }
    Add-AmbientControlDefault $next.desktopVideo 'coverage' 'follow'
    Add-AmbientControlDefault $next.desktopVideo 'smooth' $true
    if ($next.desktopVideo.smooth -isnot [bool]) { throw 'Invalid boolean: desktopVideo.smooth' }
    $style = if ($next.desktopVideo.smooth) { 'brief' } else { 'instant' }
    Add-AmbientControlDefault $next.desktopVideo 'transitionStyle' $style
    if ($next.desktopVideo.coverage -cnotin @('follow','narrow','balanced','wide')) { throw 'Invalid desktopVideo.coverage' }
    if ($next.desktopVideo.transitionStyle -cnotin @('instant','brief','cinematic')) { throw 'Invalid desktopVideo.transitionStyle' }
    # Matches the existing loader: an explicit transitionStyle takes precedence over smooth.
    $next.desktopVideo.smooth = ($next.desktopVideo.transitionStyle -ne 'instant')
    # rc.2 target additions are independent of the settings schema/product version.
    # Normalize the copy in memory; loading never writes settings or pairing files.
    # Once saved, this marker also preserves an intentional later removal of Orca.
    Add-AmbientControlDefault $next 'targetDefaultsVersion' 0
    if ($next.targetDefaultsVersion -isnot [int] -and $next.targetDefaultsVersion -isnot [long]) {
        throw 'Invalid targetDefaultsVersion; the settings file was not changed.'
    }
    if ($next.targetDefaultsVersion -lt 0) { throw 'Invalid targetDefaultsVersion.' }
    if ($next.targetDefaultsVersion -lt 1) {
        Add-AmbientControlDefault $next 'targets' @()
        if (@($next.targets) -notcontains 'orca') { $next.targets = @($next.targets) + @('orca') }
        Add-AmbientControlDefault $next 'appMultipliers' ([pscustomobject]@{})
        if ($null -eq $next.appMultipliers -or $next.appMultipliers -isnot [pscustomobject]) {
            throw 'Invalid settings object: appMultipliers'
        }
        Add-AmbientControlDefault $next.appMultipliers 'orca' 1.0
        $next.targetDefaultsVersion = 1
    }
    return $next
}

function New-AmbientLocalControl($Config, [string]$ConfigPath) {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { throw 'A settings path is required.' }
    return [pscustomobject]@{
        config = (ConvertTo-AmbientControlConfig $Config)
        configPath = $ConfigPath
        revision = [long]0
        savePending = $false
        lastSaveError = ''
    }
}

function Set-AmbientLocalControl($Control, [hashtable]$Changes) {
    # Explicit values make duplicate commands idempotent; toggling belongs only to the UI.
    $rules = @{
        globalPaused = @('control','globalPaused','bool')
        desktopEnabled = @('desktopOutput','enabled','bool')
        rgbEnabled = @('desktopOutput','rgbEnabled','bool')
        videoEnabled = @('desktopOutput','videoEnabled','bool')
        intensity = @('desktopOutput','intensity',@('soft','balanced','vivid'))
        coverage = @('desktopVideo','coverage',@('follow','narrow','balanced','wide'))
        transitionStyle = @('desktopVideo','transitionStyle',@('instant','brief','cinematic'))
        palette = @('','palette',@('dawn','forest','sunset','ocean','aurora'))
        strength = @('','strength','strength')
        spread = @('','spread',@('wide','compact'))
        protection = @('','centerProtection',@('strong','balanced','light'))
        motion = @('','motion','bool')
        seconds = @('','animationSeconds','seconds')
        hotkeyEnabled = @('globalHotkey','enabled','bool')
        hotkeyCombination = @('globalHotkey','combination','hotkey')
    }
    $candidate = Copy-AmbientControlConfig $Control.config
    foreach ($name in $Changes.Keys) {
        if (-not $rules.ContainsKey($name)) { throw 'Unsupported local setting.' }
        $rule = $rules[$name]; $value = $Changes[$name]; $kind = $rule[2]
        if ($kind -is [array]) {
            if ($value -isnot [string] -or $value -cnotin $kind) { throw ('Invalid local setting: '+$name) }
        } elseif ($kind -eq 'bool') {
            if ($value -isnot [bool]) { throw ('Invalid local boolean: '+$name) }
        } elseif ($kind -eq 'hotkey') {
            if ($value -isnot [string]) { throw 'Invalid hotkey combination.' }
            $value=(ConvertFrom-AmbientHotkey $value).combination
        } else {
            if ($value -isnot [byte] -and $value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) {
                throw ('Invalid local number: '+$name)
            }
            $number = [double]$value
            $minimum = if ($kind -eq 'strength') { 0.08 } else { 15 }
            $maximum = if ($kind -eq 'strength') { 0.85 } else { 180 }
            if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $minimum -or $number -gt $maximum) {
                throw ('Local number out of range: '+$name)
            }
        }
        if ($rule[0] -eq 'globalHotkey' -and $candidate.globalHotkey -isnot [pscustomobject]) {
            $candidate.globalHotkey=[pscustomobject]@{enabled=$false;combination='Ctrl+Alt+Shift+P'}
        }
        $target = if ($rule[0]) { $candidate.($rule[0]) } else { $candidate }
        $target | Add-Member -MemberType NoteProperty -Name $rule[1] -Value $value -Force
    }
    if ($Changes.ContainsKey('transitionStyle')) { $candidate.desktopVideo.smooth = ($candidate.desktopVideo.transitionStyle -ne 'instant') }
    if ($Changes.ContainsKey('hotkeyEnabled') -or $Changes.ContainsKey('hotkeyCombination')) {
        $preference=Get-AmbientHotkeyPreferences $candidate
        if ($preference.error) { throw $preference.error }
    }
    $changed = ($candidate | ConvertTo-Json -Depth 12 -Compress) -cne ($Control.config | ConvertTo-Json -Depth 12 -Compress)
    if (-not $changed -and -not $Control.savePending) {
        return [pscustomobject]@{changed=$false;persisted=$true;revision=$Control.revision}
    }
    try {
        Save-AmbientSettings $candidate $Control.configPath
    } catch {
        $Control.lastSaveError = Format-AmbientSafeError $_
        $pauseChanged = $false
        # A failed save must not prevent an immediate pause. Other candidate changes stay unapplied.
        if ($Changes.ContainsKey('globalPaused') -and $Changes.globalPaused -eq $true) {
            $pauseChanged = -not $Control.config.control.globalPaused
            $Control.config.control.globalPaused = $true
            $Control.savePending = $true
            if ($pauseChanged) { $Control.revision++ }
        }
        return [pscustomobject]@{changed=$pauseChanged;persisted=$false;revision=$Control.revision}
    }
    $Control.config = $candidate
    if ($changed) { $Control.revision++ }
    $Control.savePending = $false
    $Control.lastSaveError = ''
    return [pscustomobject]@{changed=$changed;persisted=$true;revision=$Control.revision}
}
