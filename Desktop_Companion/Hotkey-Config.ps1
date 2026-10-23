# Pure validation; no native registration and no settings writes on load.
function ConvertFrom-AmbientHotkey([string]$Combination) {
    $invalid='Ctrl 또는 Alt와 A-Z, 0-9, F1-F11 키 하나를 조합하세요. Windows 키·F12·시스템 예약 조합은 사용할 수 없습니다.'
    if ([string]::IsNullOrWhiteSpace($Combination)) { throw $invalid }
    $parts=@($Combination.Split('+') | ForEach-Object { $_.Trim().ToUpperInvariant() })
    $modifiers=0; $key=''
    foreach ($part in $parts) {
        $flag=switch ($part) { 'CTRL' {2}; 'ALT' {1}; 'SHIFT' {4}; default {0} }
        if ($flag) {
            if ($modifiers -band $flag) { throw $invalid }
            $modifiers=$modifiers -bor $flag
        } elseif (-not $key -and ($part -cmatch '^[A-Z0-9]$' -or $part -cmatch '^F([1-9]|10|11)$')) { $key=$part }
        else { throw $invalid }
    }
    if (-not $key -or -not ($modifiers -band 3)) { throw $invalid }
    # Includes Alt+F4, Ctrl+F4 and Ctrl+Alt+F4; never take over a close command.
    if ($key -eq 'F4') { throw $invalid }
    $vk=if ($key.Length -eq 1) { [int][char]$key } else { 111+[int]$key.Substring(1) }
    $names=@(); if ($modifiers -band 2) { $names+='Ctrl' }; if ($modifiers -band 1) { $names+='Alt' }; if ($modifiers -band 4) { $names+='Shift' }
    return [pscustomobject]@{combination=(($names+@($key)) -join '+');modifiers=[uint32]$modifiers;virtualKey=[uint32]$vk}
}

function Get-AmbientHotkeyPreferences($Config) {
    $enabled=$false; $combination='Ctrl+Alt+Shift+P'; $errorText=''
    $property=$Config.PSObject.Properties['globalHotkey']
    if ($null -ne $property) {
        $value=$property.Value
        if ($value -isnot [pscustomobject]) { $errorText='저장된 단축키 설정 형식이 올바르지 않습니다.' }
        else {
            if ($null -ne $value.PSObject.Properties['enabled']) {
                if ($value.enabled -is [bool]) { $enabled=$value.enabled } else { $errorText='단축키 사용 설정이 올바르지 않습니다.' }
            }
            if ($null -ne $value.PSObject.Properties['combination']) {
                if ($value.combination -is [string]) { $combination=$value.combination } else { $errorText='단축키 조합 형식이 올바르지 않습니다.' }
            }
        }
    }
    $parsed=$null
    try { $parsed=ConvertFrom-AmbientHotkey $combination } catch { $errorText=$_.Exception.Message }
    return [pscustomobject]@{enabled=$enabled;combination=$combination;parsed=$parsed;error=$errorText}
}
