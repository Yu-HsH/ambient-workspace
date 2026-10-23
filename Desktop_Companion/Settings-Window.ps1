# WPF settings share the tray's localControl and Set-DesktopLocalControl save path.
# Each draft contains only edited fields. No config snapshot is written back.
$settingsHost = [pscustomobject]@{ session=$null; xamlPath=(Join-Path $PSScriptRoot 'Settings.xaml') }

function Select-ComboTag($Combo, [string]$Tag) {
    $Combo.SelectedIndex = -1
    foreach ($item in $Combo.Items) {
        if ([string]$item.Tag -ceq $Tag) { $Combo.SelectedItem = $item; return }
    }
}

function Get-DesktopSettingsValues {
    $c = $localControl.config
    $hotkey=Get-AmbientHotkeyPreferences $c
    return @{
        desktopEnabled=$c.desktopOutput.enabled; globalPaused=$c.control.globalPaused
        rgbEnabled=$c.desktopOutput.rgbEnabled; videoEnabled=$c.desktopOutput.videoEnabled
        intensity=$c.desktopOutput.intensity; coverage=$c.desktopVideo.coverage
        transitionStyle=$c.desktopVideo.transitionStyle; palette=$c.palette
        strength=$c.strength; motion=$c.motion; seconds=$c.animationSeconds
        spread=$(if ($null -ne $c.PSObject.Properties['spread']) { $c.spread } else { 'wide' })
        protection=$(if ($null -ne $c.PSObject.Properties['centerProtection']) { $c.centerProtection } else { 'balanced' })
        hotkeyEnabled=$hotkey.enabled; hotkeyCombination=$hotkey.combination
    }
}

function Update-DesktopSettingsNotice($Session) {
    $controls = $Session.controls
    $controls.ApplyButton.IsEnabled = ($Session.conflicts.Count -eq 0 -and -not $Session.validationError -and ($Session.dirty.Count -gt 0 -or $localControl.savePending))
    $controls.RetryHotkeyButton.IsEnabled = ($Session.dirty.Count -eq 0 -and (Get-AmbientHotkeyPreferences $localControl.config).enabled)
    $controls.SavedText.Text = if ($Session.conflicts.Count) {
        $names = @($Session.conflicts.Keys | ForEach-Object { [Windows.Automation.AutomationProperties]::GetName($Session.fields[$_].control) })
        '충돌: ' + ($names -join ', ') + ' · 현재 값 다시 불러오기 후 다시 조정해 주세요.'
    } elseif ($Session.validationError) {
        $Session.validationError
    } elseif ($Session.saveFailed) {
        if ($localControl.savePending) { '저장 실패 · 일시정지는 유지됩니다. 변경사항은 저장되지 않았습니다. 적용 및 저장으로 재시도하세요.' }
        else { '저장 실패 · 이전 설정을 유지합니다. 미적용 변경을 보관했으니 적용 및 저장으로 재시도하세요.' }
    } elseif ($Session.dirty.Count) {
        '미적용 변경 ' + $Session.dirty.Count + '개 · 적용 및 저장을 누르면 반영됩니다.'
    } elseif ($localControl.savePending) {
        '저장 안 됨 · 현재 일시정지 유지. 적용 및 저장으로 다시 저장해 주세요.'
    } elseif ($Session.applied) { '적용 및 저장 완료 · ' + $Session.appliedAt }
    else { '저장된 설정입니다. 트레이에서 바꾼 값도 함께 반영됩니다.' }
}

function Update-DesktopSettingsLabels($Session) {
    $v = Get-DesktopSettingsValues
    $strengthValue = if ($Session.dirty.ContainsKey('strength')) { $Session.dirty.strength } else { $v.strength }
    $secondsValue = if ($Session.dirty.ContainsKey('seconds')) { $Session.dirty.seconds } else { $v.seconds }
    $Session.controls.BrightnessValue.Text = ('{0:0.##}%' -f ([double]$strengthValue * 100))
    $Session.controls.SpeedValue.Text = ('{0:0.##}초' -f [double]$secondsValue)
    $Session.controls.SpeedSlider.IsEnabled = ($Session.controls.MotionCheck.IsChecked -eq $true)
    $notes = @()
    if ([double]$v.strength -lt 0.12 -or [double]$v.strength -gt 0.70) { $notes += ('기존 밝기 {0:0.##}%는 밝기 슬라이더 조작 전까지 보존합니다.' -f ([double]$v.strength*100)) }
    if ([double]$v.seconds -lt 30 -or [double]$v.seconds -gt 160) { $notes += ('기존 이동 시간 {0}초는 시간 슬라이더 조작 전까지 보존합니다.' -f $v.seconds) }
    foreach ($key in @('palette','spread','protection')) {
        if ($null -eq $Session.fields[$key].control.SelectedItem) { $notes += '선택 목록에 없는 기존 값도 해당 항목 조작 전까지 보존합니다.'; break }
    }
    $Session.controls.LegacyText.Text = if ($notes.Count) { $notes -join ' ' } else { '밝기 12–70% · 이동 시간 30–160초. 다른 항목을 수정해도 기존 값은 유지됩니다.' }
}

function Set-DesktopSettingsDraft($Session, [string]$Key) {
    if ($Session.syncing) { return }
    $field = $Session.fields[$Key]
    $value = switch ($field.kind) {
        'check' { [bool]$field.control.IsChecked }
        'combo' { if ($null -eq $field.control.SelectedItem) { return }; [string]$field.control.SelectedItem.Tag }
        'text' { [string]$field.control.Text }
        'strength' { [Math]::Round([double]$field.control.Value,2) }
        'seconds' { [int][Math]::Round($field.control.Value) }
    }
    $Session.applied = $false
    $Session.saveFailed = $false
    if ($value -ceq $Session.baseline[$Key]) { [void]$Session.dirty.Remove($Key) }
    else { $Session.dirty[$Key] = $value }
    Sync-DesktopSettings
}

function Sync-DesktopSettings {
    $s = $settingsHost.session
    if ($null -eq $s) { return }
    $current = Get-DesktopSettingsValues
    $s.syncing = $true
    try {
        foreach ($key in $s.fields.Keys) {
            if ($s.dirty.ContainsKey($key)) {
                # A tray change which already satisfies the draft is safe to adopt.
                if ($current[$key] -ceq $s.dirty[$key]) { [void]$s.dirty.Remove($key) }
                elseif ($current[$key] -cne $s.baseline[$key]) { $s.conflicts[$key]=$true; continue }
                else { [void]$s.conflicts.Remove($key); continue }
            }
            [void]$s.conflicts.Remove($key)
            $s.baseline[$key] = $current[$key]
            $field = $s.fields[$key]
            switch ($field.kind) {
                'check' { $field.control.IsChecked = [bool]$current[$key] }
                'combo' { Select-ComboTag $field.control ([string]$current[$key]) }
                'text' { $field.control.Text = [string]$current[$key] }
                default { $field.control.Value = [double]$current[$key] }
            }
        }
    } finally { $s.syncing = $false }
    $s.validationError=''
    if ($s.dirty.ContainsKey('hotkeyCombination')) {
        try { [void](ConvertFrom-AmbientHotkey $s.dirty.hotkeyCombination) }
        catch { $s.validationError=$_.Exception.Message }
    }
    Update-DesktopSettingsLabels $s
    Update-DesktopSettingsNotice $s
}

function Update-DesktopSettingsStatus {
    $s = $settingsHost.session
    if ($null -eq $s) { return }
    Update-DesktopTrayStatus
    $c = $localControl.config
    $s.controls.DisplayStatusText.Text = $desktopDisplayStatus.Text
    $s.controls.OutputStatusText.Text = '현재 적용된 선호: RGB ' + $(if($c.desktopOutput.rgbEnabled){'켜짐'}else{'꺼짐'}) + ' · 영상 ' + $(if($c.desktopOutput.videoEnabled){'켜짐'}else{'꺼짐'})
    $s.controls.ConnectionStatusText.Text = $bridgeMenuStatus.Text + "`n" + $rgbReceiveStatus.Text + "`n" + $videoReceiveStatus.Text
    $s.controls.StatusTimeText.Text = '상태 확인: ' + (Get-Date -Format 'HH:mm:ss') + ' · 새로 고침 또는 창 활성화 시 갱신'
    $fresh = @($videoState.frameTimes.ToArray() | Where-Object { ([DateTime]::UtcNow - $_).TotalSeconds -le 10 })
    $s.controls.PerformanceText.Text = ('최근 10초 Source 갱신률: {0} FPS ({1}회)' -f [Math]::Round($fresh.Count/10.0,2),$fresh.Count) + "`n" +
        $(if($ExperimentalVideoFps -gt 0){'실험 목표: '+$ExperimentalVideoFps+' FPS · 실행 옵션, 저장하지 않음'}else{'기본 영상 상한: Chrome 모드별 1 / 2 / 4 FPS · 실험 사용 안 함'}) + "`n계측: " + $(if($metricsRuntime.enabled){'사용 중'}else{'사용 안 함'}) + "`n확인 시점: " + (Get-Date -Format 'HH:mm:ss')
    $s.controls.AdvancedText.Text = '연결: Chrome Native Messaging · 색상 만료: ' + $bridgeStaleSeconds + '초' + "`n전경 확인 주기: " + $timer.Interval.TotalMilliseconds + 'ms · 영상 확인 주기: ' + $videoPoll.Interval.TotalMilliseconds + 'ms' + "`n테두리 디버그: " + $(if($debugBorderEnabled){'사용 중'}else{'사용 안 함'})
    $apps = @('대상 앱: ' + (@($c.targets) -join ', '))
    if ($null -ne $c.PSObject.Properties['appMultipliers']) {
        foreach ($entry in $c.appMultipliers.PSObject.Properties) {
            $effective = [Math]::Max(0.5,[Math]::Min(1.5,[double]$entry.Value))
            $apps += ($entry.Name + ': ' + $entry.Value + '배' + $(if($effective -ne $entry.Value){' (실제 '+$effective+'배)'}else{''}))
        }
    }
    $s.controls.AppSummaryText.Text = $apps -join "`n"
    $s.controls.CopyPairingButton.IsEnabled = $copyKey.Enabled
    $s.controls.HotkeyStatusText.Text = Get-DesktopHotkeyStatus
    $s.controls.RetryHotkeyButton.IsEnabled = ($s.dirty.Count -eq 0 -and (Get-AmbientHotkeyPreferences $c).enabled)
}

function Apply-DesktopSettings {
    $s = $settingsHost.session
    Sync-DesktopSettings
    if ($null -eq $s -or $s.conflicts.Count -or $s.validationError) { return }
    try {
        $patch = @{}
        foreach ($key in $s.dirty.Keys) { $patch[$key]=$s.dirty[$key] }
        # Keep normalized text in the draft so successful save clears it as usual.
        if ($patch.ContainsKey('hotkeyCombination')) {
            $patch.hotkeyCombination=(ConvertFrom-AmbientHotkey $patch.hotkeyCombination).combination
            $s.dirty.hotkeyCombination=$patch.hotkeyCombination
        }
        $result = Set-DesktopLocalControl $patch
        $s.saveFailed = -not $result.persisted
        $s.applied = $result.persisted
        if ($result.persisted) { $s.appliedAt = Get-Date -Format 'HH:mm:ss' }
        Sync-DesktopSettings
        Update-DesktopSettingsStatus
    } catch {
        $s.saveFailed = $true
        Update-DesktopSettingsNotice $s
        Write-AmbientDesktopLog $logPath ('SETTINGS SAVE ERROR: '+(Format-AmbientSafeError $_))
    }
}

function Confirm-DesktopSettingsDiscard($Dialog) {
    return ([Windows.MessageBox]::Show($Dialog,'미적용 변경을 버리고 설정창을 닫을까요?','Ambient Workspace',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question,[Windows.MessageBoxResult]::No) -eq [Windows.MessageBoxResult]::Yes)
}

function Set-DesktopSettingsWindowBounds($Dialog, $WorkArea=([Windows.SystemParameters]::WorkArea)) {
    # WPF uses device-independent units. Keep the footer inside a small/high-DPI work area.
    $availableWidth = [Math]::Max(320,$WorkArea.Width - 24)
    $availableHeight = [Math]::Max(320,$WorkArea.Height - 24)
    $Dialog.MinWidth = [Math]::Min($Dialog.MinWidth,$availableWidth)
    $Dialog.MinHeight = [Math]::Min($Dialog.MinHeight,$availableHeight)
    $Dialog.Width = [Math]::Min($Dialog.Width,$availableWidth)
    $Dialog.Height = [Math]::Min($Dialog.Height,$availableHeight)
}

function New-DesktopSettingsSession {
    [xml]$xml = Get-Content -LiteralPath $settingsHost.xamlPath -Raw -Encoding UTF8
    $reader = [Xml.XmlNodeReader]::new($xml)
    try { $dialog = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    Set-DesktopSettingsWindowBounds $dialog
    $s = [pscustomobject]@{window=$dialog;controls=@{};fields=@{};baseline=@{};dirty=@{};conflicts=@{};syncing=$false;saveFailed=$false;applied=$false;appliedAt='';discardOnClose=$false;validationError=''}
    foreach ($node in $xml.SelectNodes('//*[@*[local-name()="Name"] and not(ancestor::*[local-name()="ControlTemplate"])]')) {
        $name = $node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        $s.controls[$name] = $dialog.FindName($name)
    }
    foreach ($entry in @(
        @('desktopEnabled','DesktopEnabledCheck','check'), @('globalPaused','PauseCheck','check'),
        @('rgbEnabled','RgbEnabledCheck','check'), @('videoEnabled','VideoEnabledCheck','check'),
        @('palette','PaletteCombo','combo'), @('strength','BrightnessSlider','strength'),
        @('intensity','IntensityCombo','combo'), @('spread','SpreadCombo','combo'),
        @('protection','ProtectCombo','combo'), @('motion','MotionCheck','check'),
        @('seconds','SpeedSlider','seconds'), @('coverage','CoverageCombo','combo'),
        @('transitionStyle','TransitionCombo','combo'), @('hotkeyEnabled','HotkeyEnabledCheck','check'),
        @('hotkeyCombination','HotkeyCombinationBox','text'))) {
        $key=$entry[0]; $control=$s.controls[$entry[1]]; $kind=$entry[2]
        $s.fields[$key]=@{control=$control;kind=$kind}
        $handler = { Set-DesktopSettingsDraft $s $key }.GetNewClosure()
        switch ($kind) {
            'check' { $control.Add_Checked($handler); $control.Add_Unchecked($handler) }
            'combo' { $control.Add_SelectionChanged($handler) }
            'text' { $control.Add_TextChanged($handler) }
            default {
                $control.Add_ValueChanged($handler)
                # A legacy value can put the thumb at a bound without a ValueChanged event.
                # An explicit gesture at that bound is still an edit, unlike initialization.
                $control.Add_PreviewMouseLeftButtonUp($handler)
                $control.Add_PreviewKeyUp({
                    if ($args[1].Key -in @('Left','Right','Up','Down','Home','End','PageUp','PageDown')) { Set-DesktopSettingsDraft $s $key }
                }.GetNewClosure())
            }
        }
    }
    $s.controls.ApplyButton.Add_Click({ Apply-DesktopSettings })
    $s.controls.RetryHotkeyButton.Add_Click({ Sync-DesktopGlobalHotkey -Retry; Update-DesktopSettingsStatus })
    $s.controls.ReloadButton.Add_Click({
        $s.dirty.Clear(); $s.conflicts.Clear(); $s.applied=$false; $s.saveFailed=$false
        Sync-DesktopSettings; Update-DesktopSettingsStatus
    }.GetNewClosure())
    $s.controls.CloseButton.Add_Click({ $dialog.Close() }.GetNewClosure())
    $s.controls.RefreshStatusButton.Add_Click({ Update-DesktopSettingsStatus })
    $s.controls.RefreshConnectionButton.Add_Click({ Update-DesktopSettingsStatus })
    $nativeSetupScript=Join-Path $PSScriptRoot 'Register-NativeHost.ps1'
    $nativePowerShell=Join-Path $PSHOME 'powershell.exe'
    $s.controls.NativeSetupButton.Add_Click({
        try {Start-Process -FilePath $nativePowerShell -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$nativeSetupScript+'" -Gui') -WindowStyle Hidden|Out-Null}
        catch {[void][Windows.MessageBox]::Show('Chrome 연결 등록 창을 열지 못했습니다. Setup-Chrome.bat 또는 설치 안내를 확인하세요.','Ambient Workspace')}
    }.GetNewClosure())
    $s.controls.RefreshAdvancedButton.Add_Click({ Update-DesktopSettingsStatus })
    foreach ($pair in @(@('CopyPairingButton',$copyKey),@('BorderDiagnosticButton',$test),@('BrightDiagnosticButton',$brightTest),@('FrameStatisticsButton',$statsItem))) {
        $item=$pair[1]
        $s.controls[$pair[0]].Add_Click({ $item.PerformClick() }.GetNewClosure())
    }
    $dialog.Add_Activated({ Sync-DesktopSettings; Update-DesktopSettingsStatus })
    $dialog.Add_Closing({
        if ($s.dirty.Count -and -not $s.discardOnClose) {
            if (-not (Confirm-DesktopSettingsDiscard $dialog)) { $args[1].Cancel=$true }
        }
    }.GetNewClosure())
    $hostState=$settingsHost
    $dialog.Add_Closed({ if ($hostState.session -eq $s) { $hostState.session=$null } }.GetNewClosure())
    return $s
}

function Show-SettingsWindow {
    if ($null -ne $settingsHost.session) {
        $dialog=$settingsHost.session.window
        if ($dialog.WindowState -eq [Windows.WindowState]::Minimized) { $dialog.WindowState=[Windows.WindowState]::Normal }
        [void]$dialog.Activate()
        return
    }
    try {
        $settingsHost.session = New-DesktopSettingsSession
        Sync-DesktopSettings
        Update-DesktopSettingsStatus
        # Modeless: the tray remains usable and a second request activates this window.
        $settingsHost.session.window.Show()
    } catch {
        if ($null -ne $settingsHost.session) { $settingsHost.session.discardOnClose=$true; $settingsHost.session.window.Close(); $settingsHost.session=$null }
        Write-AmbientDesktopLog $logPath ('SETTINGS ERROR: '+(Format-AmbientSafeError $_))
        [void][Windows.MessageBox]::Show('설정창을 열지 못했습니다. 진단 로그를 확인한 뒤 다시 시도해 주세요.','Ambient Workspace')
    }
}
