# Included by test-desktop-controls.ps1 inside its isolated product/WPF fixture.
# No user settings, pairing token, listener or running application is accessed.
. (Join-Path $base 'Desktop_Companion/Settings-Window.ps1')
$bridgePort=38941
$timer=[Windows.Threading.DispatcherTimer]::new()
$timer.Interval=[TimeSpan]::FromMilliseconds(450)
$videoPoll.Interval=[TimeSpan]::FromMilliseconds(120)
$s=$null
function Click-SettingsButton($Button) { $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
function Export-SettingsPreview($Session,[string]$Name,[int]$Tab,[double]$Width=920,[double]$Height=760,[double]$Scale=1) {
    $Session.window.Width=$Width; $Session.window.Height=$Height
    $Session.controls.SettingsTabs.SelectedIndex=$Tab
    $Session.window.UpdateLayout()
    $clientWidth=$Session.window.Content.ActualWidth+$Session.window.Content.Margin.Left+$Session.window.Content.Margin.Right
    $clientHeight=$Session.window.Content.ActualHeight+$Session.window.Content.Margin.Top+$Session.window.Content.Margin.Bottom
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($clientWidth*$Scale),[int]($clientHeight*$Scale),96*$Scale,96*$Scale,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Session.window)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $previewDirectory ($Name+'.png')))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}
try {
    # Values allowed by the loader but outside the old slider ranges, and unknown fields.
    $localControl.config.strength=0.81; $localControl.config.animationSeconds=175
    $localControl.config.palette='legacy-palette'
    $localControl.config.PSObject.Properties.Remove('spread')
    $localControl.config.PSObject.Properties.Remove('centerProtection')
    $localControl.config | Add-Member -NotePropertyName futureField -NotePropertyValue ([pscustomobject]@{nested=@('keep',42)}) -Force
    $localControl.config.desktopVideo | Add-Member -NotePropertyName futureVideo -NotePropertyValue 'keep' -Force
    [void](Set-DesktopLocalControl @{globalPaused=$false;desktopEnabled=$true;rgbEnabled=$true;videoEnabled=$true;intensity='balanced';transitionStyle='brief';coverage='balanced'})
    $before=[IO.File]::ReadAllText($configPath)
    $s=New-DesktopSettingsSession; $settingsHost.session=$s
    Sync-DesktopSettings; Update-DesktopSettingsStatus
    Assert-True ($s.controls.SettingsTabs.Items.Count -eq 6) 'All six settings areas must load through the real WPF XAML reader'
    Assert-True ($s.dirty.Count -eq 0 -and -not $s.controls.ApplyButton.IsEnabled) 'Initialization and slider coercion must never create edits'
    Assert-True ($s.controls.BrightnessValue.Text -eq '81%' -and $s.controls.SpeedValue.Text -eq '175초' -and $s.controls.LegacyText.Text -like '*81%*') 'Raw legacy values must remain visible even when the sliders clamp their thumbs'
    Assert-True ($null -eq $s.controls.PaletteCombo.SelectedItem -and [IO.File]::ReadAllText($configPath) -ceq $before) 'Opening settings must preserve an unknown palette and leave the file untouched'
    Click-SettingsButton $s.controls.ApplyButton
    Assert-True ([IO.File]::ReadAllText($configPath) -ceq $before) 'Applying without edits must not normalize legacy slider values'
    $gesture=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
    $gesture.RoutedEvent=[Windows.UIElement]::PreviewMouseLeftButtonUpEvent
    $s.controls.BrightnessSlider.RaiseEvent($gesture)
    Assert-True ($s.dirty.strength -eq 0.70 -and $localControl.config.strength -eq 0.81) 'An explicit gesture on an already-clamped slider must create an intentional draft'
    Click-SettingsButton $s.controls.ReloadButton
    Write-Output 'PASS UI-4 real six-area WPF load, clean initialization, legacy numeric/palette preservation and no-op save'

    Select-ComboTag $s.controls.CoverageCombo 'wide'
    Assert-True ($s.dirty.Count -eq 1 -and $s.controls.SavedText.Text -like '*미적용 변경*' -and $localControl.config.desktopVideo.coverage -ne 'wide') 'Editing must remain a draft before Apply'
    $rgbToggle.PerformClick()
    Assert-True ($s.controls.RgbEnabledCheck.IsChecked -eq $false -and $s.dirty.Count -eq 1 -and $s.dirty.coverage -eq 'wide') 'An unrelated tray change must refresh clean fields without dropping the draft'
    Click-SettingsButton $s.controls.ApplyButton
    $saved=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-True ($saved.desktopVideo.coverage -eq 'wide' -and -not $saved.desktopOutput.rgbEnabled -and $coverageItems.wide.Checked) 'Apply must patch the latest tray config and refresh its video check'
    Assert-True ($saved.strength -eq 0.81 -and $saved.animationSeconds -eq 175 -and $saved.palette -eq 'legacy-palette' -and $saved.futureField.nested[1] -eq 42 -and $saved.desktopVideo.futureVideo -eq 'keep') 'Editing coverage must preserve legacy values and unknown nested fields'
    Assert-True ($null -eq $saved.PSObject.Properties['spread'] -and $null -eq $saved.PSObject.Properties['centerProtection']) 'Unedited optional legacy appearance fields must remain absent on disk'
    Assert-True ($s.dirty.Count -eq 0 -and $s.controls.SavedText.Text -like '*적용 및 저장 완료*') 'Successful persistence must clear drafts and report success'
    Write-Output 'PASS UI-4 dirty-field patch, unrelated tray merge, common menu refresh and unknown field retention'

    Select-ComboTag $s.controls.TransitionCombo 'cinematic'
    $transitionItems.instant.PerformClick()
    Assert-True ($s.conflicts.ContainsKey('transitionStyle') -and -not $s.controls.ApplyButton.IsEnabled -and $s.controls.SavedText.Text -like '*충돌*') 'A same-field tray change must block Apply rather than overwrite either side'
    Apply-DesktopSettings
    Assert-True ($localControl.config.desktopVideo.transitionStyle -eq 'instant' -and $s.dirty.transitionStyle -eq 'cinematic') 'Even a direct apply command must respect a conflict'
    Click-SettingsButton $s.controls.ReloadButton
    Assert-True ($s.dirty.Count -eq 0 -and $s.conflicts.Count -eq 0 -and $s.controls.TransitionCombo.SelectedItem.Tag -eq 'instant') 'Explicit reload must adopt the current tray value'
    Select-ComboTag $s.controls.CoverageCombo 'narrow'
    $coverageItems.narrow.PerformClick()
    Assert-True ($s.dirty.Count -eq 0 -and $s.conflicts.Count -eq 0) 'A matching tray change must satisfy the draft without a false conflict'
    Write-Output 'PASS UI-4 same-field conflict prevention, explicit reload and matching external value adoption'

    Select-ComboTag $s.controls.PaletteCombo 'ocean'
    $lock=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        Click-SettingsButton $s.controls.ApplyButton
        Assert-True ($s.saveFailed -and $s.dirty.palette -eq 'ocean' -and $localControl.config.palette -eq 'legacy-palette' -and $s.controls.SavedText.Text -like '*저장 실패*') 'Real locked-file failure must keep old active settings and the editable draft'
        $s.controls.PauseCheck.IsChecked=$true
        Click-SettingsButton $s.controls.ApplyButton
        Assert-True ($localControl.savePending -and $localControl.config.control.globalPaused -and $s.saveFailed -and $s.dirty.palette -eq 'ocean') 'Failed mixed pause save must pause immediately while retaining unapplied edits'
    } finally { $lock.Dispose() }
    Click-SettingsButton $s.controls.ApplyButton
    Assert-True (-not $localControl.savePending -and -not $s.saveFailed -and $s.dirty.Count -eq 0 -and $localControl.config.palette -eq 'ocean') 'Retry must save the retained patch and the pending pause through the same writer'
    Write-Output 'PASS UI-4 actual locked-file failure, draft retention, immediate unsaved pause and retry'

    foreach ($rgb in @($true,$false)) {
        foreach ($video in @($true,$false)) {
            $s.controls.RgbEnabledCheck.IsChecked=$rgb; $s.controls.VideoEnabledCheck.IsChecked=$video
            $s.controls.PauseCheck.IsChecked=$false
            Click-SettingsButton $s.controls.ApplyButton
            Assert-True ($localControl.config.desktopOutput.rgbEnabled -eq $rgb -and $localControl.config.desktopOutput.videoEnabled -eq $video -and $rgbToggle.Checked -eq $rgb -and $videoToggle.Checked -eq $video) 'Settings must support all four independent output combinations'
            $s.controls.PauseCheck.IsChecked=$true; Click-SettingsButton $s.controls.ApplyButton
            Assert-True ($localControl.config.control.globalPaused -and $localControl.config.desktopOutput.rgbEnabled -eq $rgb -and $localControl.config.desktopOutput.videoEnabled -eq $video) 'Settings pause must retain the chosen combination'
            $toggle.PerformClick()
            Assert-True (-not $s.controls.PauseCheck.IsChecked) 'Tray resume must update the open settings window'
        }
    }
    foreach ($style in @('instant','brief','cinematic')) {
        Select-ComboTag $s.controls.TransitionCombo $style; Click-SettingsButton $s.controls.ApplyButton
        Assert-True ($videoState.transitionStyle -eq $style -and $localControl.config.desktopVideo.smooth -eq ($style -ne 'instant') -and $transitionItems[$style].Checked) 'All video transitions must use the existing runtime and legacy smooth rule'
    }
    foreach ($coverage in @('follow','narrow','balanced','wide')) {
        Select-ComboTag $s.controls.CoverageCombo $coverage; Click-SettingsButton $s.controls.ApplyButton
        Assert-True ($videoState.coverage -eq $coverage -and $coverageItems[$coverage].Checked) 'All video coverage choices must remain reachable in settings and tray'
    }
    $restored=New-AmbientLocalControl (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json) $configPath
    Assert-True ($restored.config.desktopVideo.coverage -eq 'wide' -and $restored.config.strength -eq 0.81 -and $restored.config.animationSeconds -eq 175 -and $restored.config.futureField.nested[0] -eq 'keep') 'Reload must retain saved choices, legacy values and unknown fields'
    $s.controls.BrightnessSlider.Value=0.42; $s.controls.MotionCheck.IsChecked=$true; $s.controls.SpeedSlider.Value=90
    Select-ComboTag $s.controls.SpreadCombo 'compact'; Select-ComboTag $s.controls.ProtectCombo 'strong'
    Select-ComboTag $s.controls.IntensityCombo 'soft'; Select-ComboTag $s.controls.CoverageCombo 'follow'
    Click-SettingsButton $s.controls.ApplyButton
    Assert-True ($runtime.strength -eq 0.42 -and $runtime.seconds -eq 90 -and $runtime.motion) 'Explicit slider and motion changes must still reach the existing RGB runtime'
    Assert-True ($runtime.spread -eq 'compact' -and $runtime.protection -eq 'strong' -and $intensityItems.soft.Checked -and $videoWash.OpacityMask.GradientStops[1].Offset -eq 0.40) 'RGB spread/protection/intensity must remain editable and follow coverage must use the existing protection mask'
    Write-Output 'PASS UI-4 all output combinations, settings pause/tray resume, coverage/transitions, RGB edits and restart config restoration'

    # Render only synthetic defaults. Never export the user's configuration or pairing token.
    $localControl=New-AmbientLocalControl (Get-Content (Join-Path $base 'Desktop_Companion/settings.defaults.json') -Raw | ConvertFrom-Json) $configPath
    $metricsRuntime.enabled=$false
    $s.applied=$false; Sync-DesktopSettings; Apply-DesktopLocalControl; Update-DesktopSettingsStatus
    $previewDirectory=Join-Path $artifacts 'ui4'; [void][IO.Directory]::CreateDirectory($previewDirectory)
    $s.window.WindowStartupLocation='Manual'; $s.window.Left=-20000; $s.window.Top=-20000; $s.window.ShowActivated=$false
    $s.window.Show(); $s.window.UpdateLayout()
    Show-SettingsWindow
    Assert-True ([object]::ReferenceEquals($settingsHost.session,$s)) 'A second open request must reuse the same modeless window'
    $s.window.WindowState='Minimized'; Show-SettingsWindow
    Assert-True ($s.window.WindowState -eq 'Normal') 'Reopen must restore an existing minimized settings window'
    foreach ($i in 0..5) { Export-SettingsPreview $s ('settings-'+$i) $i }
    $s.controls.SettingsTabs.SelectedContent.ScrollToEnd(); $s.window.UpdateLayout()
    Export-SettingsPreview $s 'settings-advanced-bottom' 5
    Export-SettingsPreview $s 'settings-minimum' 1 760 540
    $scroll=$s.controls.SettingsTabs.SelectedContent
    Assert-True ($scroll.ScrollableHeight -gt 0 -and $scroll.HorizontalScrollBarVisibility -eq 'Disabled') 'The minimum window must scroll vertically without a horizontal scrollbar'
    $scroll.ScrollToEnd(); $s.window.UpdateLayout()
    Export-SettingsPreview $s 'settings-minimum-bottom' 1 760 540
    Assert-True ($scroll.VerticalOffset -gt 0) 'Lower RGB controls must remain reachable by scrolling'
    $lastTab=$s.controls.SettingsTabs.Items[5]
    $navBottom=$lastTab.TranslatePoint([Windows.Point]::new(0,$lastTab.ActualHeight),$s.controls.SettingsTabs).Y
    Assert-True ($navBottom -le $s.controls.SettingsTabs.ActualHeight) 'All six navigation items must fit the minimum window'
    Export-SettingsPreview $s 'settings-render-200pct' 2 920 760 2
    Set-DesktopSettingsWindowBounds $s.window ([Windows.Rect]::new(0,0,744,504))
    Export-SettingsPreview $s 'settings-small-workarea' 5 720 480
    Assert-True ($s.window.MinWidth -eq 720 -and $s.window.MinHeight -eq 480 -and $s.window.ActualHeight -eq 480) 'Small/high-DPI work areas must reduce the initial size and minimum size in WPF units'
    $headerScroll=$s.controls.SettingsTabs.Template.FindName('HeaderScroll',$s.controls.SettingsTabs)
    Assert-True ($headerScroll.ScrollableHeight -gt 0) 'Navigation must scroll when the available work area is smaller than the normal minimum'
    $footerBottom=$s.controls.CloseButton.TranslatePoint([Windows.Point]::new(0,$s.controls.CloseButton.ActualHeight),$s.window).Y
    Assert-True ($footerBottom -le ($s.window.Content.ActualHeight+$s.window.Content.Margin.Top+$s.window.Content.Margin.Bottom)) 'Footer actions must remain inside the visible client area'
    $s.window.MinWidth=760; $s.window.MinHeight=540
    Select-ComboTag $s.controls.CoverageCombo 'wide'
    Export-SettingsPreview $s 'settings-dirty' 2
    $coverageItems.narrow.PerformClick()
    Export-SettingsPreview $s 'settings-conflict' 2
    Click-SettingsButton $s.controls.ReloadButton
    Select-ComboTag $s.controls.CoverageCombo 'follow'; Click-SettingsButton $s.controls.ApplyButton
    Export-SettingsPreview $s 'settings-saved' 2
    Select-ComboTag $s.controls.PaletteCombo 'ocean'
    $lock=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Click-SettingsButton $s.controls.ApplyButton; Export-SettingsPreview $s 'settings-save-failure' 1 } finally { $lock.Dispose() }
    Click-SettingsButton $s.controls.ReloadButton
    $s.controls.SettingsTabs.SelectedIndex=0; $s.window.UpdateLayout()
    [void]$s.controls.DesktopEnabledCheck.Focus()
    Assert-True ($s.controls.DesktopEnabledCheck.IsKeyboardFocused) 'The general checkbox must accept keyboard focus'
    [void]$s.controls.DesktopEnabledCheck.MoveFocus([Windows.Input.TraversalRequest]::new([Windows.Input.FocusNavigationDirection]::Next))
    Assert-True ($s.controls.PauseCheck.IsKeyboardFocused) 'Tab traversal must reach the pause checkbox'
    $closeDecision=[pscustomobject]@{allow=$false;count=0}
    function Confirm-DesktopSettingsDiscard($Dialog) { $closeDecision.count++; return $closeDecision.allow }
    Select-ComboTag $s.controls.CoverageCombo 'narrow'
    Click-SettingsButton $s.controls.CloseButton
    Assert-True ($closeDecision.count -eq 1 -and $null -ne $settingsHost.session -and $s.window.IsVisible -and $s.dirty.Count -eq 1) 'Declining discard must keep the window and unsaved draft open'
    $closeDecision.allow=$true
    Click-SettingsButton $s.controls.CloseButton
    Assert-True ($null -eq $settingsHost.session) 'Closing must release the singleton reference'
    $routes=[pscustomobject]@{count=0}
    $originalCommands=@($copyKey,$test,$brightTest,$statsItem)
    $copyKey=[Windows.Forms.ToolStripMenuItem]::new('pairing'); $test=[Windows.Forms.ToolStripMenuItem]::new('border')
    $brightTest=[Windows.Forms.ToolStripMenuItem]::new('bright'); $statsItem=[Windows.Forms.ToolStripMenuItem]::new('statistics')
    foreach ($item in @($copyKey,$test,$brightTest,$statsItem)) { $item.Add_Click({ $routes.count++ }.GetNewClosure()) }
    $s=New-DesktopSettingsSession; $settingsHost.session=$s; Sync-DesktopSettings
    Assert-True ($s.dirty.Count -eq 0 -and $s.controls.BrightnessValue.Text -eq '36%') 'A reopened session must initialize from the latest config without stale edits'
    $s.controls.HotkeyCombinationBox.Text='Alt+F4'
    Assert-True ($s.validationError -and -not $s.controls.ApplyButton.IsEnabled) 'Reserved hotkey must block Apply and display validation'
    $s.controls.HotkeyCombinationBox.Text='shift + ctrl + alt + p'
    Click-SettingsButton $s.controls.ApplyButton
    Assert-True (-not $s.validationError -and $s.dirty.Count -eq 0 -and $s.controls.HotkeyCombinationBox.Text -ceq 'Ctrl+Alt+Shift+P' -and -not $localControl.config.globalHotkey.enabled) 'Valid chord must normalize and persist without implicit activation'
    $s.controls.HotkeyCombinationBox.Text='Ctrl+Alt+Shift+F9'
    [void](Set-DesktopLocalControl @{hotkeyCombination='Ctrl+Alt+Shift+F10'})
    Assert-True ($s.conflicts.ContainsKey('hotkeyCombination') -and -not $s.controls.ApplyButton.IsEnabled) 'Hotkey draft must share same-field conflict protection'
    Click-SettingsButton $s.controls.ReloadButton
    Assert-True ($s.controls.HotkeyCombinationBox.Text -ceq 'Ctrl+Alt+Shift+F10' -and $s.dirty.Count -eq 0) 'Reload must adopt saved chord'
    $s.controls.HotkeyCombinationBox.Text='Ctrl+Alt+Shift+P'; Click-SettingsButton $s.controls.ApplyButton
    Update-DesktopSettingsStatus
    Assert-True ($s.controls.HotkeyStatusText.Text -like '비활성*') 'Disabled preference must not claim native registration'
    $s.window.ShowActivated=$false; $s.window.Left=-20000; $s.window.Top=-20000; $s.window.Show()
    Export-SettingsPreview $s 'settings-hotkey' 3
    Write-Output 'PASS hotkey WPF validation, canonical save, opt-in, draft conflict/reload and status preview'
    foreach ($name in @('CopyPairingButton','BorderDiagnosticButton','BrightDiagnosticButton','FrameStatisticsButton')) { Click-SettingsButton $s.controls[$name] }
    Assert-True ($routes.count -eq 4) 'Settings connection/diagnostics must forward to all four existing tray commands'
    foreach ($item in @($copyKey,$test,$brightTest,$statsItem)) { $item.Dispose() }
    $copyKey=$originalCommands[0]; $test=$originalCommands[1]; $brightTest=$originalCommands[2]; $statsItem=$originalCommands[3]
    Write-Output 'PASS UI-4 singleton/minimize/close/recreate lifecycle, discard accept/cancel, diagnostic routes, minimum-size scroll, focus traversal and synthetic screenshots'
} finally {
    if ($null -ne $s) { $s.discardOnClose=$true; $s.window.Close() }
    $settingsHost.session=$null
}
